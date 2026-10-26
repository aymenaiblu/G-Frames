import Foundation

struct SelectionParams: Equatable {
    /// Target overlap between consecutive selected frames (0.6 ... 0.9).
    var overlap: Double = 0.8
    /// Frames whose sharpness falls below this fraction of the local reference are treated as blurry.
    var blurThreshold: Double = 0.5
    /// Prefer frames where people block less of the scene (needs people detection during analysis).
    var avoidPeople: Bool = false
    /// Frames with more than this share covered by people count as unusable unless nothing better exists.
    var maxPeople: Double = 0.5
}

struct Pick {
    let sample: Int       // index into AnalysisResult.samples
    let qualityOK: Bool   // false = best available but still blurry, badly exposed or crowded
}

struct Selection {
    var picks: [Pick]
    /// Sharpness relative to the local (±2 s) 80th percentile.
    var relSharpness: [Double]
    /// Cumulative camera travel within each segment, in "frame widths".
    var cumulative: [Double]
    /// Sample indices where tracking was lost and a new segment begins.
    var segmentStarts: [Int]
    var totalTravel: Double
    var flaggedCount: Int { picks.filter { !$0.qualityOK }.count }
}

/// Overlap-driven keyframe selection with sharpness-aware candidate windows.
/// Mirrors the reference implementation validated on synthetic footage
/// (measured consecutive overlap stays within ~0.04 of target; blurry bursts are skipped or flagged).
enum FrameSelector {
    static let windowLow = 0.5      // candidates start after half a step of motion
    static let windowExtend = 1.5   // how far to look for a sharp frame before accepting a blurry one

    static func relativeSharpness(_ samples: [Sample], rate: Double) -> [Double] {
        let n = samples.count
        guard n > 0 else { return [] }
        let sharp = samples.map { $0.sharpness }
        let r = max(2, Int(2.0 * rate))
        var rel = [Double](repeating: 1, count: n)
        var window: [Double] = []
        window.reserveCapacity(2 * r + 1)
        for i in 0..<n {
            let lo = max(0, i - r), hi = min(n - 1, i + r)
            window.removeAll(keepingCapacity: true)
            for j in lo...hi { window.append(sharp[j]) }
            window.sort()
            // numpy-style linear-interpolated 80th percentile
            let pos = 0.8 * Double(window.count - 1)
            let a = Int(pos.rounded(.down))
            let b = min(window.count - 1, a + 1)
            let ref = window[a] + (window[b] - window[a]) * (pos - Double(a))
            rel[i] = sharp[i] / max(ref, 1e-9)
        }
        return rel
    }

    static func select(_ result: AnalysisResult, params: SelectionParams, rel precomputed: [Double]? = nil) -> Selection {
        let S = result.samples
        let n = S.count
        let rel = precomputed ?? relativeSharpness(S, rate: result.analysisRate)
        guard n > 0 else {
            return Selection(picks: [], relSharpness: [], cumulative: [], segmentStarts: [], totalTravel: 0)
        }
        let step = max(0.02, 1.0 - params.overlap)

        // Segments split where tracking was lost.
        var starts: [Int] = [0]
        if n > 1 {
            for i in 1..<n where !S[i].valid { starts.append(i) }
        }

        // Cumulative travel, reset per segment.
        var cum = [Double](repeating: 0, count: n)
        var total = 0.0
        for si in 0..<starts.count {
            let a = starts[si]
            let b = si + 1 < starts.count ? starts[si + 1] : n
            if b - a > 1 {
                for i in (a + 1)..<b {
                    cum[i] = cum[i - 1] + S[i].motion
                }
            }
            total += cum[b - 1]
        }

        func ok(_ i: Int) -> Bool {
            rel[i] >= params.blurThreshold && S[i].brightness > 18 && S[i].brightness < 242
                && (!params.avoidPeople || S[i].people <= params.maxPeople)
        }
        // Sharpness, discounted by the share of the frame people cover: (1 - p)^3.
        // With no people (or detection off) this is plain relative sharpness, as validated originally.
        func score(_ i: Int) -> Double {
            guard params.avoidPeople else { return rel[i] }
            let free = 1 - min(1, max(0, S[i].people))
            return rel[i] * free * free * free
        }
        func best(_ cands: [Int]) -> (Int, Bool)? {
            let good = cands.filter(ok)
            let pool = good.isEmpty ? cands : good
            guard let i = pool.max(by: { score($0) < score($1) }) else { return nil }
            return (i, !good.isEmpty)
        }

        var picks: [Pick] = []
        for si in 0..<starts.count {
            let a = starts[si]
            let b = si + 1 < starts.count ? starts[si + 1] : n

            // First frame of the segment: sharpest within the first half step.
            var first: [Int] = []
            var i = a
            while i < b && cum[i] <= cum[a] + windowLow * step { first.append(i); i += 1 }
            if first.isEmpty { first = [a] }
            guard let firstPick = best(first) else { continue }
            var k = firstPick.0
            picks.append(Pick(sample: k, qualityOK: firstPick.1))

            while true {
                let ck = cum[k]
                var win: [Int] = []
                var ext: [Int] = []
                var j = k + 1
                while j < b && cum[j] <= ck + windowExtend * step {
                    if cum[j] >= ck + windowLow * step {
                        if cum[j] <= ck + step { win.append(j) }
                        ext.append(j)
                    }
                    j += 1
                }
                var chosen = best(win)
                if chosen == nil || chosen!.1 == false {
                    if let e = best(ext), e.1 { chosen = e }
                }
                if chosen == nil, let e = best(ext) { chosen = e }
                if chosen == nil {
                    // Fast motion: nothing inside the window, take the next frame past half a step.
                    var nx = k + 1
                    while nx < b && cum[nx] <= ck + windowLow * step { nx += 1 }
                    if nx >= b { break }
                    chosen = (nx, ok(nx))
                }
                guard let c = chosen else { break }
                picks.append(Pick(sample: c.0, qualityOK: c.1))
                k = c.0
            }
        }
        return Selection(picks: picks, relSharpness: rel, cumulative: cum,
                         segmentStarts: starts, totalTravel: total)
    }
}
