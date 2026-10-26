import Foundation
import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case empty, probing, ready, analyzing, analyzed, extracting, done
    }

    enum Strictness: String, CaseIterable, Identifiable {
        case lenient = "Lenient", normal = "Normal", strict = "Strict"
        var id: String { rawValue }
        var threshold: Double {
            switch self {
            case .lenient: return 0.35
            case .normal: return 0.5
            case .strict: return 0.65
            }
        }
    }

    // State
    @Published var phase: Phase = .empty
    @Published var info: VideoInfo?
    @Published var errorMessage: String?
    @Published var progress: Double = 0
    @Published var progressDetail: String = ""
    @Published var eta: String = ""
    @Published var analysis: AnalysisResult?
    @Published var selection: Selection?
    @Published var exportResult: ExportResult?
    @Published var thumbnails: [NSImage] = []

    // Analysis options
    @Published var mode360: Bool = false { didSet { if oldValue != mode360 { invalidateAnalysis() } } }
    @Published var denseAnalysis: Bool = false { didSet { if oldValue != denseAnalysis { invalidateAnalysis() } } }
    @Published var detectPeople: Bool = true { didSet { if oldValue != detectPeople { invalidateAnalysis() } } }

    // Selection options (instant re-selection, no re-analysis)
    @Published var overlap: Double = 0.8 { didSet { reselect() } }
    @Published var strictness: Strictness = .normal { didSet { reselect() } }

    // Output options
    @Published var includeUpViews: Bool = false
    @Published var includeDownViews: Bool = false
    @Published var viewSize: Int = 1440
    @Published var jpegQuality: Double = 0.95
    @Published var resolutionCap: Int = 0   // 0 = full resolution
    @Published var maskPeople: Bool = true
    @Published var maskOverlay: Bool = true
    @Published var outputParent: URL?

    private var relCache: [Double]?
    private var cancelFlag: CancelFlag?
    private var startedAt = Date()
    private var thumbTask: Task<Void, Never>?

    var params: SelectionParams {
        SelectionParams(overlap: overlap, blurThreshold: strictness.threshold,
                        avoidPeople: analysis?.peopleDetected ?? false, maxPeople: 0.5)
    }

    /// Mean share of the frame covered by people: in the selected frames, and across the whole video.
    var peopleStats: (picked: Double, all: Double)? {
        guard let a = analysis, a.peopleDetected, let s = selection, !s.picks.isEmpty, !a.samples.isEmpty else { return nil }
        let picked = s.picks.map { a.samples[$0.sample].people }.reduce(0, +) / Double(s.picks.count)
        let all = a.samples.map { $0.people }.reduce(0, +) / Double(a.samples.count)
        return (picked, all)
    }

    var views: [ViewSpec] { ViewRig.views(up: includeUpViews, down: includeDownViews) }

    var selectedCount: Int { selection?.picks.count ?? 0 }

    var imageCount: Int { selectedCount * (mode360 ? views.count : 1) }

    var analysisRate: Double {
        let fps = info?.fps ?? 30
        return min(denseAnalysis ? 30 : 10, fps)
    }

    // MARK: Loading

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .audiovisualContent]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a video to turn into photogrammetry frames"
        if panel.runModal() == .OK, let url = panel.url {
            load(url)
        }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Where should the frames folder be created?"
        if let p = outputParent { panel.directoryURL = p }
        if panel.runModal() == .OK, let url = panel.url {
            outputParent = url
        }
    }

    func load(_ url: URL) {
        cancel()
        errorMessage = nil
        analysis = nil
        selection = nil
        exportResult = nil
        thumbnails = []
        relCache = nil
        phase = .probing
        Task {
            do {
                let i = try await VideoProbe.probe(url)
                self.info = i
                self.mode360 = i.isLikely360
                let suggested = Int((Double(i.displayWidth) / 4.0 / 16.0).rounded()) * 16
                self.viewSize = min(2048, max(512, suggested))
                self.outputParent = url.deletingLastPathComponent()
                self.phase = .ready
            } catch {
                self.info = nil
                self.phase = .empty
                var msg = error.localizedDescription
                let ext = url.pathExtension.lowercased()
                if ["mkv", "webm", "avi", "flv", "wmv"].contains(ext) {
                    msg += " macOS can't read .\(ext) containers. Remux first, e.g.  ffmpeg -i \"\(url.lastPathComponent)\" -c copy out.mp4  (or re-encode with -c:v libx264 -crf 16 if the codec is VP9)."
                }
                self.errorMessage = msg
            }
        }
    }

    // MARK: Analysis

    func analyze() {
        guard let info else { return }
        let flag = CancelFlag()
        cancelFlag = flag
        errorMessage = nil
        exportResult = nil
        progress = 0
        progressDetail = "Starting…"
        eta = ""
        startedAt = Date()
        phase = .analyzing
        let rate = analysisRate
        let eq = mode360
        let dp = detectPeople
        let model = self
        Task.detached(priority: .userInitiated) {
            do {
                let res = try await Analyzer.run(info: info, rate: rate, equirect: eq, detectPeople: dp, detectOverlays: true, cancel: flag) { p, frames, samples in
                    Task { @MainActor in
                        model.updateProgress(p, detail: "\(frames.formatted()) frames decoded · \(samples.formatted()) analysed")
                    }
                }
                await MainActor.run { model.finishAnalysis(res) }
            } catch {
                await MainActor.run { model.handle(error, fallback: .ready) }
            }
        }
    }

    private func finishAnalysis(_ res: AnalysisResult) {
        analysis = res
        relCache = FrameSelector.relativeSharpness(res.samples, rate: res.analysisRate)
        phase = .analyzed
        reselect()
    }

    private func reselect() {
        guard let a = analysis else { return }
        selection = FrameSelector.select(a, params: params, rel: relCache)
        refreshThumbnails()
    }

    private func invalidateAnalysis() {
        guard analysis != nil else { return }
        analysis = nil
        selection = nil
        thumbnails = []
        relCache = nil
        if phase == .analyzed || phase == .done { phase = .ready }
    }

    // MARK: Extraction

    func extract() {
        guard let info, let analysis, let selection else { return }
        guard let parent = outputParent else { chooseOutputFolder(); return }
        let flag = CancelFlag()
        cancelFlag = flag
        errorMessage = nil
        progress = 0
        progressDetail = "Starting…"
        eta = ""
        startedAt = Date()
        phase = .extracting
        var settings = ExportSettings(outputParent: parent)
        settings.jpegQuality = jpegQuality
        settings.maxLongEdge = resolutionCap > 0 ? resolutionCap : nil
        settings.equirect = mode360
        settings.views = views
        settings.viewSize = viewSize
        settings.maskPeople = maskPeople && analysis.peopleDetected
        if maskOverlay, let ov = analysis.overlay {
            settings.overlay = ov.displayImage(orientation: info.orientation)
        }
        let params = self.params
        let model = self
        Task.detached(priority: .userInitiated) {
            do {
                let res = try await Extractor.run(info: info, analysis: analysis, selection: selection,
                                                  params: params, settings: settings, cancel: flag) { p, done, total in
                    Task { @MainActor in
                        model.updateProgress(p, detail: "\(done.formatted()) of \(total.formatted()) images written")
                    }
                }
                await MainActor.run {
                    model.exportResult = res
                    model.phase = .done
                }
            } catch {
                await MainActor.run { model.handle(error, fallback: .analyzed) }
            }
        }
    }

    func cancel() {
        cancelFlag?.cancel()
        cancelFlag = nil
    }

    func revealOutput() {
        guard let r = exportResult else { return }
        NSWorkspace.shared.activateFileViewerSelecting([r.imagesFolder])
    }

    func reset() {
        cancel()
        info = nil
        analysis = nil
        selection = nil
        exportResult = nil
        thumbnails = []
        errorMessage = nil
        phase = .empty
    }

    // MARK: Helpers

    private func updateProgress(_ p: Double, detail: String) {
        guard phase == .analyzing || phase == .extracting else { return }
        progress = p
        progressDetail = detail
        let elapsed = Date().timeIntervalSince(startedAt)
        if p > 0.02 && elapsed > 2 {
            let remaining = elapsed * (1 - p) / p
            eta = "about \(Self.duration(remaining)) left"
        }
    }

    private func handle(_ error: Error, fallback: Phase) {
        if let fe = error as? GFramesError, case .cancelled = fe {
            errorMessage = nil
        } else {
            errorMessage = error.localizedDescription
        }
        phase = fallback
    }

    nonisolated static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        if t < 60 { return "\(t) s" }
        if t < 3600 { return "\(t / 60) min \(t % 60) s" }
        return "\(t / 3600) h \((t % 3600) / 60) min"
    }

    nonisolated static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    // MARK: Advice

    var warnings: [String] {
        guard let s = selection else { return [] }
        var w: [String] = []
        if s.totalTravel < 1.0 {
            w.append("The camera barely moves (about \(String(format: "%.1f", s.totalTravel)) frame-widths in total). Photogrammetry needs viewpoint change — walk around or along the subject.")
        } else if s.picks.count < 20 {
            w.append("Only \(s.picks.count) frames. Reconstructions are usually more reliable with 20+ overlapping views; raise the overlap if the model has holes.")
        }
        if s.segmentStarts.count > 1 {
            w.append("Tracking was lost \(s.segmentStarts.count - 1) time(s) (cuts, extreme blur or textureless views). Segments may need exhaustive matching to connect — colmap.sh switches automatically.")
        }
        if s.picks.count > 0 && Double(s.flaggedCount) / Double(s.picks.count) > 0.1 {
            w.append("\(s.flaggedCount) frames are still blurry or badly exposed even after choosing the best candidates. Footage with slower movement or more light will reconstruct better.")
        }
        if let ps = peopleStats, ps.picked > 0.25 {
            w.append("People still cover about \(Int((ps.picked * 100).rounded()))% of the chosen frames. Masks will exclude them, but a surface hidden behind people in every view cannot be reconstructed: film at a quieter time or from more angles.")
        }
        if let ov = analysis?.overlay {
            w.append("A burned-in overlay (logo or caption) covers \(String(format: "%.1f", ov.coverage * 100))% of the frame. It will be masked in every image so it cannot mislead camera-pose estimation.")
        }
        if imageCount > 2500 {
            w.append("\(imageCount.formatted()) images: matching will be slow. Consider a lower overlap or splitting the reconstruction.")
        }
        return w
    }

    // MARK: Thumbnails

    private func refreshThumbnails() {
        thumbTask?.cancel()
        guard let info, let analysis, let selection, !selection.picks.isEmpty else {
            thumbnails = []
            return
        }
        let sorted = selection.picks.map { $0.sample }.sorted()
        let k = min(8, sorted.count)
        var chosen: [Int] = []
        for i in 0..<k {
            let idx = k == 1 ? 0 : Int((Double(i) * Double(sorted.count - 1) / Double(k - 1)).rounded())
            chosen.append(sorted[idx])
        }
        let times = chosen.map { CMTime(seconds: analysis.samples[$0].time, preferredTimescale: 600) }
        let url = info.url
        thumbTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 360, height: 360)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
            var imgs: [NSImage] = []
            for t in times {
                if Task.isCancelled { return }
                if let r = try? await gen.image(at: t) {
                    imgs.append(NSImage(cgImage: r.image, size: .zero))
                }
            }
            if Task.isCancelled { return }
            self?.thumbnails = imgs
        }
    }
}
