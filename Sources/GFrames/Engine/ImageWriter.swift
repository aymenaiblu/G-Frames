import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Owned BGRA8 pixel buffer that can be wrapped as a CGImage without copying.
final class BGRAImage {
    let w: Int
    let h: Int
    let rowBytes: Int
    let data: UnsafeMutableRawPointer

    init(w: Int, h: Int) {
        self.w = w
        self.h = h
        self.rowBytes = w * 4
        self.data = UnsafeMutableRawPointer.allocate(byteCount: max(1, w * h * 4), alignment: 64)
    }
    deinit { data.deallocate() }

    func makeCGImage() -> CGImage? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        // Copy into CFData so the CGImage owns its pixels independently of this buffer's lifetime.
        guard let cfData = CFDataCreate(nil, data.assumingMemoryBound(to: UInt8.self), rowBytes * h),
              let provider = CGDataProvider(data: cfData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: cs, bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}

struct ImageMeta {
    var make: String?
    var model: String?
    var focal35mm: Double?
    var focalMM: Double?
    var description: String?
}

enum ImageWriter {
    @discardableResult
    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double, meta: ImageMeta) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return false
        }
        var exif: [CFString: Any] = [:]
        if let f = meta.focal35mm, f > 0 {
            exif[kCGImagePropertyExifFocalLenIn35mmFilm] = Int(f.rounded())
        }
        if let f = meta.focalMM, f > 0 {
            exif[kCGImagePropertyExifFocalLength] = f
        }
        var tiff: [CFString: Any] = [kCGImagePropertyTIFFSoftware: "G-Frames"]
        if let m = meta.make, !m.isEmpty { tiff[kCGImagePropertyTIFFMake] = m }
        if let m = meta.model, !m.isEmpty { tiff[kCGImagePropertyTIFFModel] = m }
        if let d = meta.description { tiff[kCGImagePropertyTIFFImageDescription] = d }

        var props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyTIFFDictionary: tiff
        ]
        if !exif.isEmpty { props[kCGImagePropertyExifDictionary] = exif }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
