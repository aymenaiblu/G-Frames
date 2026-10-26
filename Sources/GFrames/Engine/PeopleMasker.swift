import Foundation
import Vision
import CoreVideo
import CoreGraphics
import Accelerate
import ImageIO
import UniformTypeIdentifiers

/// Share (0...1) of pixels at or above 128 in a one-component 8-bit buffer.
func coverageFraction(_ pb: CVPixelBuffer) -> Double {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return 0 }
    let w = CVPixelBufferGetWidth(pb)
    let h = CVPixelBufferGetHeight(pb)
    let rb = CVPixelBufferGetBytesPerRow(pb)
    guard w > 0, h > 0 else { return 0 }
    let p = base.assumingMemoryBound(to: UInt8.self)
    var n = 0
    for y in 0..<h {
        let r = p + y * rb
        for x in 0..<w where r[x] >= 128 { n += 1 }
    }
    return Double(n) / Double(w * h)
}

/// Fast estimate of how much of a frame people cover. Used during analysis on every sampled frame.
/// Runs Apple's on-device person segmentation (Vision), so nothing leaves the Mac.
final class PeopleProbe {
    private let request: VNGeneratePersonSegmentationRequest

    init() {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .fast
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        request = r
    }

    func coverage(_ pb: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> Double {
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return 0
        }
        guard let obs = request.results?.first else { return 0 }
        return coverageFraction(obs.pixelBuffer)
    }
}

/// Exported photogrammetry mask: white = use these pixels, black = ignore (COLMAP and Metashape convention).
struct PersonMask {
    let image: CGImage
    /// Share of the frame that is masked out.
    let coverage: Double
}

/// Full-quality person masks for exported images.
/// Nothing is painted over or invented: the mask only tells the reconstruction which pixels to ignore,
/// so the surfaces behind people are recovered from other views where they are actually visible.
enum PeopleMasker {
    /// Safety margin added around every person, as a fraction of the image's long edge
    /// (covers hair, motion blur and segmentation edges).
    static let dilation = 0.012
    /// Distant people are often too small for segmentation; boxes smaller than this share
    /// of the frame are masked as rectangles. Larger people rely on the segmentation outline.
    static let smallPersonArea = 0.02

    /// - Parameters:
    ///   - people: run person detection.
    ///   - overlay: static-overlay mask (white = overlay) in display orientation, scaled to the image here.
    static func mask(for image: CGImage, people: Bool, overlay: CGImage?) -> PersonMask? {
        let W = image.width, H = image.height
        guard W > 8, H > 8 else { return nil }

        let seg = VNGeneratePersonSegmentationRequest()
        seg.qualityLevel = .accurate
        seg.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let boxes = VNDetectHumanRectanglesRequest()
        boxes.upperBodyOnly = false

        if people {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([seg, boxes])
            } catch {
                return nil
            }
        }

        // Plane `a` holds 255 where a person is, 0 elsewhere.
        let a = Plane8(w: W, h: H)
        memset(a.data, 0, a.rowBytes * H)
        let pa = a.data.assumingMemoryBound(to: UInt8.self)

        if people, let obs = seg.results?.first {
            let pb = obs.pixelBuffer
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(pb) {
                var src = vImage_Buffer(data: base,
                                        height: vImagePixelCount(CVPixelBufferGetHeight(pb)),
                                        width: vImagePixelCount(CVPixelBufferGetWidth(pb)),
                                        rowBytes: CVPixelBufferGetBytesPerRow(pb))
                var dst = a.vbuf()
                _ = vImageScale_Planar8(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
            }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            for y in 0..<H {
                let r = pa + y * a.rowBytes
                for x in 0..<W { r[x] = r[x] >= 128 ? 255 : 0 }
            }
        }

        if people, let found = boxes.results {
            for person in found {
                let bb = person.boundingBox   // normalised, origin bottom-left
                guard bb.width * bb.height < smallPersonArea else { continue }
                let ex = bb.insetBy(dx: -bb.width * 0.15, dy: -bb.height * 0.08)
                let x0 = max(0, Int(ex.minX * CGFloat(W)))
                let x1 = min(W, Int((ex.maxX * CGFloat(W)).rounded(.up)))
                let y0 = max(0, Int((1 - ex.maxY) * CGFloat(H)))
                let y1 = min(H, Int(((1 - ex.minY) * CGFloat(H)).rounded(.up)))
                guard x1 > x0, y1 > y0 else { continue }
                for y in y0..<y1 {
                    memset(pa + y * a.rowBytes + x0, 255, x1 - x0)
                }
            }
        }

        // Add the static overlay (logo, caption) scaled to this image.
        if let ov = overlay {
            let o = Plane8(w: W, h: H)
            memset(o.data, 0, o.rowBytes * H)
            if let ctx = CGContext(data: o.data, width: W, height: H, bitsPerComponent: 8, bytesPerRow: o.rowBytes,
                                   space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(ov, in: CGRect(x: 0, y: 0, width: W, height: H))
                let po = o.data.assumingMemoryBound(to: UInt8.self)
                for y in 0..<H {
                    let ro = po + y * o.rowBytes
                    let ra = pa + y * a.rowBytes
                    for x in 0..<W where ro[x] >= 128 { ra[x] = 255 }
                }
            }
        }

        // Grow every masked region by the safety margin (morphological max filter).
        var k = max(3, Int(Double(max(W, H)) * dilation))
        if k % 2 == 0 { k += 1 }
        let b = Plane8(w: W, h: H)
        var sa = a.vbuf()
        var sb = b.vbuf()
        let err = vImageMax_Planar8(&sa, &sb, nil, 0, 0,
                                    vImagePixelCount(k), vImagePixelCount(k),
                                    vImage_Flags(kvImageNoFlags))
        let grown = err == kvImageNoError ? b : a

        // Invert to the photogrammetry convention and count masked pixels.
        let pg = grown.data.assumingMemoryBound(to: UInt8.self)
        var masked = 0
        for y in 0..<H {
            let r = pg + y * grown.rowBytes
            for x in 0..<W {
                if r[x] != 0 {
                    masked += 1
                    r[x] = 0
                } else {
                    r[x] = 255
                }
            }
        }

        guard let cfData = CFDataCreate(nil, pg, grown.rowBytes * H),
              let provider = CGDataProvider(data: cfData),
              let cg = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 8,
                               bytesPerRow: grown.rowBytes, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else { return nil }
        return PersonMask(image: cg, coverage: Double(masked) / Double(W * H))
    }

    /// All-white mask (keep every pixel).
    static func blankMask(width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let bytes = [UInt8](repeating: 255, count: width * height)
        guard let cfData = CFDataCreate(nil, bytes, bytes.count),
              let provider = CGDataProvider(data: cfData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    @discardableResult
    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}
