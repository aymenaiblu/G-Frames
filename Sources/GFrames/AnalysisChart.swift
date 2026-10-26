import SwiftUI

/// Sharpness (top) and camera motion (bottom) over time, with selected frames as ticks.
struct AnalysisChart: View {
    let analysis: AnalysisResult
    let selection: Selection
    let threshold: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { ctx, size in
                draw(&ctx, size)
            }
            .frame(height: 160)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 14) {
                legend(color: Theme.accent, text: "Selected frame")
                legend(color: .orange, text: "Selected, still soft")
                legend(color: .primary, text: "Tracking lost / cut")
                if analysis.peopleDetected {
                    legend(color: .purple, text: "People in view")
                }
                Spacer()
                Text(timeLabel).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private var timeLabel: String {
        guard let last = analysis.samples.last else { return "" }
        return AppModel.duration(last.time)
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 3, height: 11)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let S = analysis.samples
        guard S.count > 1, size.width > 10 else { return }
        let rel = selection.relSharpness
        let t0 = S[0].time
        let span = max(1e-6, S[S.count - 1].time - t0)
        let W = size.width, H = size.height
        let topH = H * 0.52
        let botY = H * 0.60
        let botH = H - botY - 4
        func x(_ t: Double) -> CGFloat { CGFloat((t - t0) / span) * (W - 8) + 4 }

        // Bucket into pixel columns so very long videos stay cheap to draw.
        let cols = max(2, Int(W / 2))
        var relSum = [Double](repeating: 0, count: cols)
        var relN = [Int](repeating: 0, count: cols)
        var motMax = [Double](repeating: 0, count: cols)
        var pplSum = [Double](repeating: 0, count: cols)
        for i in 0..<S.count {
            let c = min(cols - 1, max(0, Int((S[i].time - t0) / span * Double(cols - 1))))
            relSum[c] += min(1.5, rel.count == S.count ? rel[i] : 1)
            relN[c] += 1
            motMax[c] = max(motMax[c], S[i].motion * analysis.analysisRate)
            pplSum[c] += S[i].people
        }
        let sortedMot = motMax.sorted()
        let motRef = max(1e-6, sortedMot[min(sortedMot.count - 1, Int(Double(sortedMot.count) * 0.98))])

        // Selected-frame ticks and cuts (behind the curves).
        for p in selection.picks {
            let xx = x(S[p.sample].time)
            var path = Path()
            path.move(to: CGPoint(x: xx, y: 0))
            path.addLine(to: CGPoint(x: xx, y: H))
            ctx.stroke(path, with: .color((p.qualityOK ? Theme.accent : Color.orange).opacity(0.35)), lineWidth: 1)
        }
        for s in selection.segmentStarts where s > 0 {
            let xx = x(S[s].time)
            var path = Path()
            path.move(to: CGPoint(x: xx, y: 0))
            path.addLine(to: CGPoint(x: xx, y: H))
            ctx.stroke(path, with: .color(.primary.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
        }

        // Sharpness curve.
        func yRel(_ v: Double) -> CGFloat { CGFloat(6 + (1 - v / 1.5) * Double(topH - 12)) }
        var curve = Path()
        var started = false
        for c in 0..<cols where relN[c] > 0 {
            let v = relSum[c] / Double(relN[c])
            let pt = CGPoint(x: CGFloat(c) / CGFloat(cols - 1) * (W - 8) + 4, y: yRel(v))
            if started { curve.addLine(to: pt) } else { curve.move(to: pt); started = true }
        }
        ctx.stroke(curve, with: .color(.primary.opacity(0.75)), lineWidth: 1.2)
        var thr = Path()
        thr.move(to: CGPoint(x: 4, y: yRel(threshold)))
        thr.addLine(to: CGPoint(x: W - 4, y: yRel(threshold)))
        ctx.stroke(thr, with: .color(.orange.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

        // Motion area.
        var area = Path()
        area.move(to: CGPoint(x: 4, y: botY + botH))
        for c in 0..<cols {
            let v = min(1, motMax[c] / motRef)
            area.addLine(to: CGPoint(x: CGFloat(c) / CGFloat(cols - 1) * (W - 8) + 4, y: botY + botH - CGFloat(v) * botH))
        }
        area.addLine(to: CGPoint(x: W - 4, y: botY + botH))
        area.closeSubpath()
        ctx.fill(area, with: .color(.teal.opacity(0.45)))

        // People coverage (0-100% of the frame) as a line over the motion band.
        if analysis.peopleDetected {
            var ppl = Path()
            var first = true
            for c in 0..<cols where relN[c] > 0 {
                let v = min(1, pplSum[c] / Double(relN[c]))
                let pt = CGPoint(x: CGFloat(c) / CGFloat(cols - 1) * (W - 8) + 4, y: botY + botH - CGFloat(v) * botH)
                if first { ppl.move(to: pt); first = false } else { ppl.addLine(to: pt) }
            }
            ctx.stroke(ppl, with: .color(.purple.opacity(0.85)), lineWidth: 1.2)
        }

        ctx.draw(Text("Sharpness").font(.caption2).foregroundColor(.secondary),
                 at: CGPoint(x: 8, y: 4), anchor: .topLeading)
        ctx.draw(Text("Camera motion").font(.caption2).foregroundColor(.secondary),
                 at: CGPoint(x: 8, y: botY), anchor: .topLeading)
    }
}
