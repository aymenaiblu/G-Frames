import Foundation

/// Image pyramid with cached gradients for pyramidal Lucas–Kanade.
final class Pyramid {
    struct Level {
        let img: GrayF
        let gx: GrayF
        let gy: GrayF
    }
    let levels: [Level]
    var base: Level { levels[0] }

    init(base: GrayF, count: Int) {
        var lv: [Level] = []
        var cur = base
        for i in 0..<count {
            let (gx, gy) = cur.gradients()
            lv.append(Level(img: cur, gx: gx, gy: gy))
            if i < count - 1 {
                let next = cur.down2()
                if next.w < 16 || next.h < 16 { break }
                cur = next
            }
        }
        levels = lv
    }
}

/// Result of a frame-to-frame motion estimate.
struct MotionEstimate {
    /// Median normalised image displacement (fraction of the frame extent per axis, combined).
    var displacement: Double
    /// Fraction of candidate points that tracked forward and back consistently.
    var inlierFraction: Double
    /// Number of candidate points with enough texture.
    var candidates: Int
    var valid: Bool
}

/// Sparse pyramidal Lucas–Kanade with forward–backward consistency.
/// A 1:1 port of the reference implementation validated on synthetic footage with known camera paths.
final class LKTracker {
    let win: Int = 5
    let maxIterations: Int = 20
    let gridX: Int
    let gridY: Int
    let maxPoints: Int = 160
    /// Vertical band used for point seeding (equirectangular footage avoids the distorted poles).
    let bandTop: Double
    let bandBottom: Double
    /// Per-axis weights for normalising displacement (1,1 for perspective; 4,2 for 360° = fraction of a 90° view).
    let axisWeightX: Double
    let axisWeightY: Double

    private var bufI: [Float]
    private var bufIx: [Float]
    private var bufIy: [Float]

    init(equirectangular: Bool) {
        if equirectangular {
            gridX = 24; gridY = 8
            bandTop = 0.18; bandBottom = 0.82
            axisWeightX = 4; axisWeightY = 2
        } else {
            gridX = 16; gridY = 9
            bandTop = 0; bandBottom = 1
            axisWeightX = 1; axisWeightY = 1
        }
        let n = 11 * 11   // (2 * win + 1)^2 with win = 5
        bufI = [Float](repeating: 0, count: n)
        bufIx = [Float](repeating: 0, count: n)
        bufIy = [Float](repeating: 0, count: n)
    }

    // MARK: Point selection (Shi–Tomasi minimum eigenvalue, best per grid cell)

    func goodPoints(_ P: Pyramid) -> [(Float, Float)] {
        let lv = P.base
        let w = lv.img.w, h = lv.img.h
        let k = 2 * win + 1
        guard w > 6 * win + 2, h > 6 * win + 2 else { return [] }

        // Integral images of the structure-tensor terms.
        let iw = w + 1
        var Sxx = [Double](repeating: 0, count: iw * (h + 1))
        var Syy = Sxx
        var Sxy = Sxx
        lv.gx.px.withUnsafeBufferPointer { gx in
            lv.gy.px.withUnsafeBufferPointer { gy in
                for y in 0..<h {
                    var rxx = 0.0, ryy = 0.0, rxy = 0.0
                    for x in 0..<w {
                        let a = Double(gx[y * w + x]), b = Double(gy[y * w + x])
                        rxx += a * a; ryy += b * b; rxy += a * b
                        let o = (y + 1) * iw + (x + 1)
                        Sxx[o] = Sxx[o - iw] + rxx
                        Syy[o] = Syy[o - iw] + ryy
                        Sxy[o] = Sxy[o - iw] + rxy
                    }
                }
            }
        }
        func box(_ S: [Double], _ x0: Int, _ y0: Int) -> Double {
            // sum over [x0, x0+k) x [y0, y0+k)
            let x1 = x0 + k, y1 = y0 + k
            return S[y1 * iw + x1] - S[y0 * iw + x1] - S[y1 * iw + x0] + S[y0 * iw + x0]
        }

        let m = 3 * win
        let yLo = max(m, Int(Double(h) * bandTop))
        let yHi = min(h - m, Int(Double(h) * bandBottom))
        guard yHi - yLo > gridY * 2 else { return [] }
        let cw = Double(w - 2 * m) / Double(gridX)
        let ch = Double(yHi - yLo) / Double(gridY)
        var cands: [(Double, Int, Int)] = []
        cands.reserveCapacity(gridX * gridY)
        for gyI in 0..<gridY {
            for gxI in 0..<gridX {
                let x0 = m + Int(Double(gxI) * cw)
                let y0 = yLo + Int(Double(gyI) * ch)
                let x1 = min(w - m, m + Int(Double(gxI + 1) * cw))
                let y1 = min(yHi, yLo + Int(Double(gyI + 1) * ch))
                var best = -1.0, bx = x0, by = y0
                var yy = y0
                while yy < y1 {
                    var xx = x0
                    while xx < x1 {
                        // window centred on (xx, yy)
                        let a = box(Sxx, xx - win, yy - win)
                        let c = box(Syy, xx - win, yy - win)
                        let b = box(Sxy, xx - win, yy - win)
                        let tr = a + c
                        let e = 0.5 * (tr - ((a - c) * (a - c) + 4 * b * b).squareRoot())
                        if e > best { best = e; bx = xx; by = yy }
                        xx += 1
                    }
                    yy += 1
                }
                if best > 0 { cands.append((best, bx, by)) }
            }
        }
        guard let top = cands.map({ $0.0 }).max() else { return [] }
        let thr = max(top * 0.02, 1e-3 * Double(k * k))
        return cands.filter { $0.0 >= thr }
            .sorted { $0.0 > $1.0 }
            .prefix(maxPoints)
            .map { (Float($0.1), Float($0.2)) }
    }

    // MARK: Tracking

    /// Track one point from pyramid P to pyramid Q. Returns displacement at base resolution.
    func track(_ P: Pyramid, _ Q: Pyramid, _ px: Float, _ py: Float) -> (Float, Float, Bool) {
        let levels = min(P.levels.count, Q.levels.count)
        var gx: Float = 0, gy: Float = 0
        let W = win
        let fw = Float(W)
        for L in stride(from: levels - 1, through: 0, by: -1) {
            let s = Float(1 << L)
            let x = px / s, y = py / s
            let lp = P.levels[L], lq = Q.levels[L]
            let w = lp.img.w, h = lp.img.h
            let inside = x >= fw + 1 && x < Float(w) - fw - 2 && y >= fw + 1 && y < Float(h) - fw - 2
            if !inside {
                if L == 0 { return (0, 0, false) }
                gx *= 2; gy *= 2
                continue
            }
            // Sample template, gradients.
            var a: Float = 0, b: Float = 0, c: Float = 0
            lp.img.px.withUnsafeBufferPointer { I in
                lp.gx.px.withUnsafeBufferPointer { IX in
                    lp.gy.px.withUnsafeBufferPointer { IY in
                        var n = 0
                        for oy in -W...W {
                            for ox in -W...W {
                                let sx = x + Float(ox), sy = y + Float(oy)
                                let iv = bilinear(I, w, sx, sy)
                                let ix = bilinear(IX, w, sx, sy)
                                let iy = bilinear(IY, w, sx, sy)
                                bufI[n] = iv; bufIx[n] = ix; bufIy[n] = iy
                                a += ix * ix; b += ix * iy; c += iy * iy
                                n += 1
                            }
                        }
                    }
                }
            }
            let det = a * c - b * b
            if det < 1e-6 * (a + c) * (a + c) || (a + c) < 1e-3 {
                return (0, 0, false)
            }
            var dx: Float = 0, dy: Float = 0
            var lost = false
            lq.img.px.withUnsafeBufferPointer { J in
                for _ in 0..<maxIterations {
                    let qx = x + gx + dx, qy = y + gy + dy
                    if !(qx >= fw + 1 && qx < Float(w) - fw - 2 && qy >= fw + 1 && qy < Float(h) - fw - 2) {
                        lost = true
                        return
                    }
                    var bx: Float = 0, by: Float = 0
                    var n = 0
                    for oy in -W...W {
                        for ox in -W...W {
                            let jv = bilinear(J, w, qx + Float(ox), qy + Float(oy))
                            let e = bufI[n] - jv
                            bx += e * bufIx[n]
                            by += e * bufIy[n]
                            n += 1
                        }
                    }
                    let ux = (c * bx - b * by) / det
                    let uy = (a * by - b * bx) / det
                    dx += ux; dy += uy
                    if ux * ux + uy * uy < 1e-4 { break }
                }
            }
            if lost { return (0, 0, false) }
            if L > 0 {
                gx = 2 * (gx + dx); gy = 2 * (gy + dy)
            } else {
                gx += dx; gy += dy
            }
        }
        return (gx, gy, true)
    }

    /// Robust global image motion between two frames.
    func motion(from P: Pyramid, to Q: Pyramid) -> MotionEstimate {
        let w = Double(P.base.img.w), h = Double(P.base.img.h)
        let pts = goodPoints(P)
        if pts.count < 12 {
            return MotionEstimate(displacement: 0, inlierFraction: 0, candidates: pts.count, valid: false)
        }
        var mags: [Double] = []
        mags.reserveCapacity(pts.count)
        for (x, y) in pts {
            let (dx, dy, ok) = track(P, Q, x, y)
            if !ok { continue }
            let (bx, by, ok2) = track(Q, P, x + dx, y + dy)
            if !ok2 { continue }
            let ex = dx + bx, ey = dy + by
            if ex * ex + ey * ey > 0.25 { continue }
            let nx = axisWeightX * Double(dx) / w
            let ny = axisWeightY * Double(dy) / h
            mags.append((nx * nx + ny * ny).squareRoot())
        }
        let frac = Double(mags.count) / Double(pts.count)
        if mags.count < 8 {
            return MotionEstimate(displacement: 0, inlierFraction: frac, candidates: pts.count, valid: false)
        }
        mags.sort()
        let n = mags.count
        let med = n % 2 == 1 ? mags[n / 2] : 0.5 * (mags[n / 2 - 1] + mags[n / 2])
        return MotionEstimate(displacement: med, inlierFraction: frac, candidates: pts.count, valid: frac >= 0.3)
    }
}
