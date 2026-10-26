import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false

    private var busy: Bool { model.phase == .analyzing || model.phase == .extracting || model.phase == .probing }

    var body: some View {
        Group {
            if model.info == nil {
                DropZone(targeted: dropTargeted)
            } else {
                MainPanel()
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !busy, let url = urls.first else { return false }
            model.load(url)
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}

// MARK: - Empty state

struct DropZone: View {
    @EnvironmentObject var model: AppModel
    let targeted: Bool

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundStyle(targeted ? Theme.accent : Color.secondary.opacity(0.5))
                    .background(RoundedRectangle(cornerRadius: 22).fill(targeted ? Theme.accent.opacity(0.08) : Color.clear))
                VStack(spacing: 14) {
                    if model.phase == .probing {
                        ProgressView().controlSize(.large)
                        Text("Reading video…").foregroundStyle(.secondary)
                    } else {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 96, height: 96)
                        Text("Drop a video here")
                            .font(.title2.weight(.semibold))
                        Text("Any length or size — phone, drone, 360° or downloaded footage.\nG-Frames measures camera motion and sharpness, then picks the frames a point cloud needs.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 460)
                        Button("Choose Video…") { model.chooseVideo() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .padding(.top, 4)
                        Text(Credit.line)
                            .font(.callout.weight(.medium))
                            .padding(.top, 2)
                    }
                }
                .padding(30)
            }
            .frame(maxWidth: 620, maxHeight: 380)
            if let err = model.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: 620)
            }
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Main panel

struct MainPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let err = model.errorMessage {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
                }
                VideoCard()
                AnalyseCard()
                if let a = model.analysis, let s = model.selection {
                    ResultsCard(analysis: a, selection: s)
                    ExportCard()
                }
            }
            .padding(20)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
    }
}

struct VideoCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let info = model.info {
            GroupBox {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: model.mode360 ? "pano" : "film")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                        .frame(width: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(info.url.lastPathComponent)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(specs(info))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Change…") { model.chooseVideo() }
                        .disabled(model.phase == .analyzing || model.phase == .extracting)
                }
                .padding(6)
            }
        }
    }

    private func specs(_ i: VideoInfo) -> String {
        var parts = ["\(i.displayWidth)×\(i.displayHeight)",
                     String(format: "%.2f fps", i.fps),
                     AppModel.duration(i.duration),
                     i.codec,
                     AppModel.bytes(i.fileSize)]
        let cam = [i.make, i.model].compactMap { $0 }.joined(separator: " ")
        if !cam.isEmpty { parts.append(cam) }
        return parts.joined(separator: " · ")
    }
}

struct CardTitle: View {
    let number: String
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.accent))
            Label(title, systemImage: symbol).font(.headline)
        }
    }
}

struct ProgressRow: View {
    let value: Double
    let detail: String
    let eta: String
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: min(1, max(0, value)))
            HStack {
                Text(detail).monospacedDigit()
                Spacer()
                Text(eta)
                Button("Cancel", action: onCancel)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}

struct AnalyseCard: View {
    @EnvironmentObject var model: AppModel

    private var locked: Bool { model.phase == .analyzing || model.phase == .extracting }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("360° equirectangular video", isOn: $model.mode360)
                        Text(model.info?.isLikely360 == true
                             ? "Detected from the 2:1 frame shape. Frames will be split into perspective views."
                             : "Turn on for 360° footage to export perspective views COLMAP can use.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Density", selection: $model.denseAnalysis) {
                            Text("Standard · 10/s").tag(false)
                            Text("Fine · up to 30/s").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 320)
                        Text("Fine examines more candidates per step: sharper picks, slower analysis.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(locked)

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Detect people", isOn: $model.detectPeople)
                    Text("Finds people in every analysed frame (on-device, Apple Vision) and prefers frames where they block less of the building.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(locked)

                if model.phase == .analyzing {
                    ProgressRow(value: model.progress, detail: model.progressDetail, eta: model.eta) { model.cancel() }
                } else if let a = model.analysis {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Analysed \(a.samples.count.formatted()) of \(a.totalFrames.formatted()) frames in \(AppModel.duration(a.processingSeconds)).")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Re-analyse") { model.analyze() }.disabled(locked)
                    }
                    .font(.callout)
                } else {
                    Button {
                        model.analyze()
                    } label: {
                        Label("Analyse Video", systemImage: "sparkle.magnifyingglass")
                            .frame(minWidth: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(locked || model.info == nil)
                }
            }
            .padding(8)
        } label: {
            CardTitle(number: "1", title: "Analyse", symbol: "waveform.path.ecg")
        }
    }
}

struct ResultsCard: View {
    @EnvironmentObject var model: AppModel
    let analysis: AnalysisResult
    let selection: Selection

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(selection.picks.count)")
                        .font(.system(size: 46, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.mode360
                             ? "frames × \(model.views.count) views = \(model.imageCount.formatted()) images"
                             : "frames needed for this video")
                            .font(.title3)
                        Text("Each frame overlaps the previous by about \(Int((model.overlap * 100).rounded()))%; the sharpest candidate is taken at every step.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text("Overlap").frame(width: 92, alignment: .leading)
                        Slider(value: $model.overlap, in: 0.6...0.9, step: 0.01)
                        Text("\(Int((model.overlap * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    Text("70–85% suits video. Go higher for close-range detail or if COLMAP drops frames; lower for long, slow walks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 102)
                }
                HStack(spacing: 10) {
                    Text("Blur rejection").frame(width: 92, alignment: .leading)
                    Picker("", selection: $model.strictness) {
                        ForEach(AppModel.Strictness.allCases) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)
                }

                AnalysisChart(analysis: analysis, selection: selection, threshold: model.strictness.threshold)

                HStack(spacing: 22) {
                    stat(String(format: "%.1f", selection.totalTravel), "frame-widths of camera travel")
                    stat("\(selection.segmentStarts.count)", selection.segmentStarts.count == 1 ? "continuous segment" : "segments")
                    stat("\(selection.flaggedCount)", "frames kept for continuity despite blur or crowding")
                    if let ps = model.peopleStats {
                        stat("\(Int((ps.picked * 100).rounded()))%", "of chosen frames covered by people (video average \(Int((ps.all * 100).rounded()))%)")
                    }
                }

                if !model.thumbnails.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, img in
                                Image(nsImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 78)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }

                ForEach(model.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
        } label: {
            CardTitle(number: "2", title: "Frames", symbol: "square.stack.3d.up")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ExportCard: View {
    @EnvironmentObject var model: AppModel

    private var locked: Bool { model.phase == .analyzing || model.phase == .extracting }

    private var folderNote: String {
        let name = Extractor.asciiSlug(model.info?.name ?? "video")
        let masks = (model.maskPeople && model.analysis?.peopleDetected == true)
            || (model.maskOverlay && model.analysis?.overlay != nil)
        let parts = masks ? "images/, masks/" : "images/"
        return "Creates “\(name)_frames” with \(parts), frames.csv, report.txt, analysis.json and colmap.sh."
    }

    private func doneText(_ r: ExportResult) -> String {
        var t = "\(r.imageCount.formatted()) images written in \(AppModel.duration(r.seconds))"
        if r.failedWrites > 0 { t += " (\(r.failedWrites) failed)" }
        return t + "."
    }

    private var sizeOptions: [Int] {
        Array(Set([1024, 1280, 1440, 1600, 1920, 2048, model.viewSize])).sorted()
    }

    var body: some View {
        GroupBox {
          VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if model.mode360 {
                    HStack(spacing: 24) {
                        Toggle("4 upward views (+40°)", isOn: $model.includeUpViews)
                        Toggle("4 downward views (−40°)", isOn: $model.includeDownViews)
                    }
                    HStack(spacing: 10) {
                        Text("View size").frame(width: 92, alignment: .leading)
                        Picker("", selection: $model.viewSize) {
                            ForEach(sizeOptions, id: \.self) { s in Text("\(s) × \(s) px").tag(s) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 200)
                        Text("8 horizontal views, 90° FOV, 45° apart.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 10) {
                        Text("Resolution").frame(width: 92, alignment: .leading)
                        Picker("", selection: $model.resolutionCap) {
                            Text("Full · \(model.info?.displayWidth ?? 0)×\(model.info?.displayHeight ?? 0)").tag(0)
                            Text("Max 3840 px").tag(3840)
                            Text("Max 3200 px").tag(3200)
                            Text("Max 2048 px").tag(2048)
                        }
                        .labelsHidden()
                        .frame(maxWidth: 240)
                    }
                }
                if let ov = model.analysis?.overlay {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Mask burned-in overlay (\(String(format: "%.1f", ov.coverage * 100))% of frame)", isOn: $model.maskOverlay)
                        Text("A logo, caption or bar stays fixed on screen while the camera moves. Fixed features mislead camera-pose estimation, so they are masked in every image.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if model.analysis?.peopleDetected == true {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Export person masks", isOn: $model.maskPeople)
                        Text("Writes masks/ beside images/. COLMAP and Metashape ignore masked pixels and rebuild those surfaces from views where they are actually visible. The images themselves are never altered.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 10) {
                    Text("JPEG quality").frame(width: 92, alignment: .leading)
                    Slider(value: $model.jpegQuality, in: 0.8...1.0, step: 0.01)
                        .frame(maxWidth: 260)
                    Text("\(Int((model.jpegQuality * 100).rounded()))")
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)
                }
                HStack(spacing: 10) {
                    Text("Save to").frame(width: 92, alignment: .leading)
                    Text(model.outputParent?.path ?? "—")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Change…") { model.chooseOutputFolder() }
                }
                Text(folderNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(locked)
            .padding(8)

            VStack(alignment: .leading, spacing: 10) {
                if model.phase == .extracting {
                    ProgressRow(value: model.progress, detail: model.progressDetail, eta: model.eta) { model.cancel() }
                } else {
                    Button {
                        model.extract()
                    } label: {
                        Label("Extract \(model.imageCount.formatted()) Images", systemImage: "photo.stack")
                            .frame(minWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(locked || model.imageCount == 0)
                }
                if model.phase == .done, let r = model.exportResult {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text(doneText(r))
                        Spacer()
                        Button("Show in Finder") { model.revealOutput() }
                    }
                    .font(.callout)
                    Text(r.folder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
          }
        } label: {
            CardTitle(number: "3", title: "Export", symbol: "square.and.arrow.down")
        }
    }
}
