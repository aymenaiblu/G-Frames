import Foundation

/// Single-channel float image, row-major, no padding.
struct GrayF {
    let w: Int
    let h: Int
    var px: [Float]

    init(w: Int, h: Int) {
        self.w = w
        self.h = h
        self.px = [Float](repeating: 0, count: max(0, w * h))
    }

    init(w: Int, h: Int, px: [Float]) {
        self.w = w
        self.h = h
        self.px = px
    }

    /// Build from an 8-bit plane with arbitrary row stride.
    init(bytes: UnsafePointer<UInt8>, w: Int, h: Int, rowBytes: Int) {
        self.w = w
        self.h = h
        var out = [Float](repeating: 0, count: w * h)
        out.withUnsafeMutableBufferPointer { dst in
            for y in 0..<h {
                let row = bytes + y * rowBytes
                let o = y * w
                for x in 0..<w { dst[o + x] = Float(row[x]) }
            }
        }
        self.px = out
    }

    /// 2x2 box downsample (floor of odd sizes), matches the reference implementation.
    func down2() -> GrayF {
        let nw = w / 2, nh = h / 2
        var out = GrayF(w: nw, h: nh)
        guard nw > 0, nh > 0 else { return out }
        px.withUnsafeBufferPointer { s in
            out.px.withUnsafeMutableBufferPointer { d in
                for y in 0..<nh {
                    let r0 = (2 * y) * w, r1 = (2 * y + 1) * w
                    for x in 0..<nw {
                        let a = s[r0 + 2 * x] + s[r0 + 2 * x + 1]
                        let b = s[r1 + 2 * x] + s[r1 + 2 * x + 1]
                        d[y * nw + x] = 0.25 * (a + b)
                    }
                }
            }
        }
        return out
    }

    /// Central-difference gradients (zero on the border), matches the reference implementation.
    func gradients() -> (GrayF, GrayF) {
        var gx = GrayF(w: w, h: h)
        var gy = GrayF(w: w, h: h)
        guard w > 2, h > 2 else { return (gx, gy) }
        px.withUnsafeBufferPointer { s in
            gx.px.withUnsafeMutableBufferPointer { dx in
                gy.px.withUnsafeMutableBufferPointer { dy in
                    for y in 0..<h {
                        let o = y * w
                        for x in 1..<(w - 1) {
                            dx[o + x] = 0.5 * (s[o + x + 1] - s[o + x - 1])
                        }
                    }
                    for y in 1..<(h - 1) {
                        let o = y * w
                        for x in 0..<w {
                            dy[o + x] = 0.5 * (s[o + w + x] - s[o - w + x])
                        }
                    }
                }
            }
        }
        return (gx, gy)
    }
}

/// Bilinear sample. Caller guarantees 0 <= x < w-1 and 0 <= y < h-1.
@inline(__always)
func bilinear(_ p: UnsafeBufferPointer<Float>, _ w: Int, _ x: Float, _ y: Float) -> Float {
    let fx0 = x.rounded(.down), fy0 = y.rounded(.down)
    let x0 = Int(fx0), y0 = Int(fy0)
    let fx = x - fx0, fy = y - fy0
    let i = y0 * w + x0
    let a00 = p[i], a01 = p[i + 1], a10 = p[i + w], a11 = p[i + w + 1]
    return (a00 * (1 - fx) + a01 * fx) * (1 - fy) + (a10 * (1 - fx) + a11 * fx) * fy
}

/// Variance of the 4-neighbour Laplacian on an 8-bit plane. Used as the sharpness score.
func laplacianVariance(bytes: UnsafePointer<UInt8>, w: Int, h: Int, rowBytes: Int) -> Double {
    guard w > 2, h > 2 else { return 0 }
    var sum: Double = 0
    var sum2: Double = 0
    for y in 1..<(h - 1) {
        let r = bytes + y * rowBytes
        let up = r - rowBytes
        let dn = r + rowBytes
        var s: Int = 0
        var s2: Int = 0
        for x in 1..<(w - 1) {
            let v = Int(r[x - 1]) + Int(r[x + 1]) + Int(up[x]) + Int(dn[x]) - 4 * Int(r[x])
            s += v
            s2 += v * v
        }
        sum += Double(s)
        sum2 += Double(s2)
    }
    let n = Double((w - 2) * (h - 2))
    let mean = sum / n
    return max(0, sum2 / n - mean * mean)
}

/// Mean of an 8-bit plane, sub-sampled every 4th pixel.
func planeMean(bytes: UnsafePointer<UInt8>, w: Int, h: Int, rowBytes: Int) -> Double {
    guard w > 0, h > 0 else { return 0 }
    var total: Int = 0
    var n: Int = 0
    var y = 0
    while y < h {
        let r = bytes + y * rowBytes
        var x = 0
        while x < w {
            total += Int(r[x])
            n += 1
            x += 4
        }
        y += 4
    }
    return n > 0 ? Double(total) / Double(n) : 0
}
