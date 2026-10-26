import Foundation
import CoreGraphics
import CoreImage

/// Detects burned-in static overlays (TV channel logos, captions, timestamps, letterbox bars)
/// that stay fixed on screen while the camera moves. Such pixels look like features with zero
/// motion and corrupt camera-pose estimation, so they are masked out of every exported image.
///
/// Rule (validated on synthetic footage with a burned-in logo and caption, and on clean footage):
/// a pixel is overlay when it is textured (mean L1 central-difference gradient > 12)
/// but barely changes between moving frames (mean |I_t − I_t−1| < 3). Candidates are dilated,
/// each compact component is filled to its bounding box, and the result is dilated again.
final class OverlayAccumulator {
    static let spatialThreshold: Float = 12
    static let temporalThreshold: Float = 3
    static let minMovingPairs = 20
    static let maxComponentShare = 0.03   // components larger than 3% of the frame are not overlays
    static let maxTotalShare = 0.25       // more than 25% static means a static camera, not an overlay

    private(set) var w = 0
    private(set) var h = 0
    private var spatial: [Float] = []
    private var temporal: [Float] = []
    private var prev: [Float]?
    private(set) var nSpatial = 0
    private(set) var nTemporal = 0

    func add(_ g: GrayF, moving: Bool) {
        if g.w != w || g.h != h {
            w = g.w; h = g.h
            spatial = [Float](repeating: 0, count: w * h)
            temporal = [Float](repeating: 0, count: w * h)
            prev = nil; nSpatial = 0; nTemporal = 0
        }
        guard w > 2, h > 2 else { return }
        let W = w, H = h
        g.px.withUnsafeBufferPointer { p in
            spatial.withUnsafeMutableBufferPointer { s in
                for y in 1..<(H - 1) {
                    for x in 1..<(W - 1) {
                        let i = y * W + x
                        s[i] += abs(p[i + 1] - p[i - 1]) + abs(p[i + W] - p[i - W])
                    }
                }
            }
            if moving, let q = prev {
                temporal.withUnsafeMutableBufferPointer { t in
                    for i in 0..<(W * H) { t[i] += abs(p[i] - q[i]) }
                }
                nTemporal += 1
            }
        }
        nSpatial += 1
        prev = g.px
    }

    /// Returns the overlay mask (255 = overlay) at analysis resolution, in the video's encoded orientation.
    func result() -> OverlayMask? {
        guard nSpatial > 0, nTemporal >= Self.minMovingPairs, w > 4, h > 4 else { return nil }
        let W = w, H = h, n = W * H
        let ns = Float(nSpatial), nt = Float(nTemporal)
        var cand = [UInt8](repeating: 0, count: n)
        for y in 1..<(H - 1) {
            for x in 1..<(W - 1) {
                let i = y * W + x
                if spatial[i] / ns > Self.spatialThreshold && temporal[i] / nt < Self.temporalThreshold {
                    cand[i] = 1
                }
            }
        }
        var m = Self.dilate(cand, W, H, radius: 2)
        // Fill each compact connected component to its bounding box.
        var label = [Int32](repeating: 0, count: n)
        var out = [UInt8](repeating: 0, count: n)
        var stack: [Int] = []
        var next: Int32 = 0
        for start in 0..<n where m[start] != 0 && label[start] == 0 {
            next += 1
            label[start] = next
            stack.append(start)
            var minX = W, minY = H, maxX = 0, maxY = 0, count = 0
            while let i = stack.popLast() {
                let x = i % W, y = i / W
                count += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                if x > 0, m[i - 1] != 0, label[i - 1] == 0 { label[i - 1] = next; stack.append(i - 1) }
                if x < W - 1, m[i + 1] != 0, label[i + 1] == 0 { label[i + 1] = next; stack.append(i + 1) }
                if y > 0, m[i - W] != 0, label[i - W] == 0 { label[i - W] = next; stack.append(i - W) }
                if y < H - 1, m[i + W] != 0, label[i + W] == 0 { label[i + W] = next; stack.append(i + W) }
            }
            let bw = maxX - minX + 1, bh = maxY - minY + 1
            if count < 6 || Double(bw * bh) > Self.maxComponentShare * Double(n) { continue }
            for y in minY...maxY {
                for x in minX...maxX { out[y * W + x] = 1 }
            }
        }
        m = Self.dilate(out, W, H, radius: 2)
        let covered = m.reduce(0) { $0 + Int($1) }
        let share = Double(covered) / Double(n)
        guard covered > 0, share <= Self.maxTotalShare else { return nil }
        return OverlayMask(w: W, h: H, bits: m.map { $0 != 0 ? 255 : 0 }, coverage: share)
    }

    static func dilate(_ a: [UInt8], _ W: Int, _ H: Int, radius r: Int) -> [UInt8] {
        // separable square max filter
        var tmp = [UInt8](repeating: 0, count: a.count)
        for y in 0..<H {
            for x in 0..<W {
                var v: UInt8 = 0
                for dx in max(0, x - r)...min(W - 1, x + r) where a[y * W + dx] != 0 { v = 1; break }
                tmp[y * W + x] = v
            }
        }
        var out = [UInt8](repeating: 0, count: a.count)
        for y in 0..<H {
            for x in 0..<W {
                var v: UInt8 = 0
                for dy in max(0, y - r)...min(H - 1, y + r) where tmp[dy * W + x] != 0 { v = 1; break }
                out[y * W + x] = v
            }
        }
        return out
    }
}

struct OverlayMask: Codable {
    let w: Int
    let h: Int
    let bits: [UInt8]      // 255 = overlay
    let coverage: Double   // share of the frame

    /// Grayscale image of the overlay (white = overlay) rotated to display orientation.
    func displayImage(orientation: CGImagePropertyOrientation) -> CGImage? {
        guard let cfData = CFDataCreate(nil, bits, bits.count),
              let provider = CGDataProvider(data: cfData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                               space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true,
                               intent: .defaultIntent) else { return nil }
        if orientation == .up { return cg }
        let ci = CIImage(cgImage: cg).oriented(orientation)
        return CIContext().createCGImage(ci, from: ci.extent)
    }
}
