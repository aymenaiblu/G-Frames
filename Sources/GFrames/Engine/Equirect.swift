import Foundation

/// A virtual pinhole camera looking out of an equirectangular panorama.
struct ViewSpec: Hashable, Codable {
    var yaw: Double     // degrees, 0 = panorama centre, positive = right
    var pitch: Double   // degrees, positive = up
}

enum ViewRig {
    /// Default rig: 8 horizontal views (45° apart, 90° FOV => 50% overlap between neighbours),
    /// optionally 4 tilted up and/or 4 tilted down.
    static func views(up: Bool, down: Bool) -> [ViewSpec] {
        var v: [ViewSpec] = []
        for i in 0..<8 { v.append(ViewSpec(yaw: Double(i) * 45, pitch: 0)) }
        if up { for i in 0..<4 { v.append(ViewSpec(yaw: Double(i) * 90 + 45, pitch: 40)) } }
        if down { for i in 0..<4 { v.append(ViewSpec(yaw: Double(i) * 90, pitch: -40)) } }
        return v
    }

    /// Focal length in pixels for a square view of `size` px and horizontal FOV `fovDeg`.
    static func focalPixels(size: Int, fovDeg: Double) -> Double {
        (Double(size) / 2) / tan(fovDeg * Double.pi / 360)
    }
}

enum Equirect {
    /// Render one perspective view from a BGRA8 equirectangular image (bilinear, horizontal wrap).
    static func render(view: ViewSpec, fovDeg: Double, size: Int,
                       src: UnsafeRawPointer, sw: Int, sh: Int, srcRowBytes: Int,
                       dst: BGRAImage) {
        let f = ViewRig.focalPixels(size: size, fovDeg: fovDeg)
        let half = Double(size) / 2
        let pitch = view.pitch * Double.pi / 180
        let yaw = view.yaw * Double.pi / 180
        let cp = cos(pitch), sp = sin(pitch)
        let cy = cos(yaw), sy = sin(yaw)
        let swD = Double(sw), shD = Double(sh)
        let twoPi = 2 * Double.pi
        let s = src.assumingMemoryBound(to: UInt8.self)
        let d = dst.data.assumingMemoryBound(to: UInt8.self)
        let dRow = dst.rowBytes

        DispatchQueue.concurrentPerform(iterations: size) { v in
            let y = (Double(v) + 0.5 - half) / f
            let row = d + v * dRow
            for u in 0..<size {
                let x = (Double(u) + 0.5 - half) / f
                // camera: x right, y down, z forward. Pitch about x, then yaw about y.
                let y1 = y * cp - sp
                let z1 = y * sp + cp
                let x2 = x * cy + z1 * sy
                let z2 = -x * sy + z1 * cy
                let lon = atan2(x2, z2)
                let lat = atan2(y1, (x2 * x2 + z2 * z2).squareRoot())
                var fx = (lon / twoPi + 0.5) * swD - 0.5
                var fy = (lat / Double.pi + 0.5) * shD - 0.5
                if fy < 0 { fy = 0 }
                if fy > shD - 1 { fy = shD - 1 }
                if fx < 0 { fx += swD }
                let x0f = fx.rounded(.down), y0f = fy.rounded(.down)
                let ax = fx - x0f, ay = fy - y0f
                var x0 = Int(x0f) % sw
                if x0 < 0 { x0 += sw }
                let x1 = (x0 + 1) % sw
                let y0 = Int(y0f)
                let y1i = min(y0 + 1, sh - 1)
                let r0 = s + y0 * srcRowBytes
                let r1 = s + y1i * srcRowBytes
                let o = row + u * 4
                let w00 = (1 - ax) * (1 - ay), w01 = ax * (1 - ay)
                let w10 = (1 - ax) * ay, w11 = ax * ay
                for c in 0..<3 {
                    let val = Double(r0[x0 * 4 + c]) * w00 + Double(r0[x1 * 4 + c]) * w01
                        + Double(r1[x0 * 4 + c]) * w10 + Double(r1[x1 * 4 + c]) * w11
                    o[c] = UInt8(max(0, min(255, val + 0.5)))
                }
                o[3] = 255
            }
        }
    }
}
