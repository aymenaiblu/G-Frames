import Foundation
import AVFoundation
import CoreImage

struct ExportSettings {
    var outputParent: URL
    var jpegQuality: Double = 0.95
    /// nil = full resolution (recommended for photogrammetry).
    var maxLongEdge: Int? = nil
    var equirect: Bool = false
    var views: [ViewSpec] = ViewRig.views(up: false, down: false)
    var viewFOV: Double = 90
    var viewSize: Int = 1440
    /// Write a person mask next to every image (masks/<image>.jpg.png).
    var maskPeople: Bool = false
    /// Static overlay (logo, caption) to mask in every image, in display orientation.
    var overlay: CGImage? = nil
}

struct ExportResult {
    let folder: URL
    let imagesFolder: URL
    let frameCount: Int
    let imageCount: Int
    let failedWrites: Int
    let seconds: Double
    let masksFolder: URL?
    /// Masked share per image file name.
    let maskCoverage: [String: Double]
}

/// One output frame scheduled for extraction.
struct PlannedFrame {
    let outputIndex: Int    // 1-based, defines file order for sequential matching
    let sampleIndex: Int
    let frame: Int
    let time: Double
    let qualityOK: Bool
}

final class CoverageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Double] = [:]
    func set(_ name: String, _ v: Double) { lock.lock(); values[name] = v; lock.unlock() }
    var all: [String: Double] { lock.lock(); defer { lock.unlock() }; return values }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var ok = 0
    private var bad = 0
    func add(success: Bool) { lock.lock(); if success { ok += 1 } else { bad += 1 }; lock.unlock() }
    var values: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (ok, bad) }
}

enum Extractor {
    static func asciiSlug(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            if ch.isASCII, CharacterSet.alphanumerics.contains(ch) { out.unicodeScalars.append(ch) }
            else if ch == "-" || ch == "_" { out.unicodeScalars.append(ch) }
            else if ch == " " || ch == "." { out.append("_") }
        }
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        if out.count > 40 { out = String(out.prefix(40)) }
        return out.isEmpty ? "video" : out
    }

    static func makeOutputFolder(parent: URL, base: String) throws -> URL {
        let fm = FileManager.default
        var candidate = parent.appendingPathComponent("\(base)_frames", isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base)_frames_\(n)", isDirectory: true)
            n += 1
        }
        do {
            try fm.createDirectory(at: candidate.appendingPathComponent("images", isDirectory: true),
                                   withIntermediateDirectories: true)
        } catch {
            throw GFramesError.outputFolder(error.localizedDescription)
        }
        return candidate
    }

    static func plan(_ analysis: AnalysisResult, _ selection: Selection) -> [PlannedFrame] {
        let sorted = selection.picks.sorted { $0.sample < $1.sample }
        var out: [PlannedFrame] = []
        for (i, p) in sorted.enumerated() {
            let s = analysis.samples[p.sample]
            out.append(PlannedFrame(outputIndex: i + 1, sampleIndex: p.sample, frame: s.frame,
                                    time: s.time, qualityOK: p.qualityOK))
        }
        return out
    }

    static func fileName(slug: String, index: Int, view: Int?) -> String {
        let idx = String(format: "%05d", index)
        if let v = view { return "\(slug)_\(idx)_v\(String(format: "%02d", v)).jpg" }
        return "\(slug)_\(idx).jpg"
    }

    static func run(info: VideoInfo,
                    analysis: AnalysisResult,
                    selection: Selection,
                    params: SelectionParams,
                    settings: ExportSettings,
                    cancel: CancelFlag,
                    progress: @escaping (Double, Int, Int) -> Void) async throws -> ExportResult {
        let slug = asciiSlug(info.name)
        let folder = try makeOutputFolder(parent: settings.outputParent, base: slug)
        let images = folder.appendingPathComponent("images", isDirectory: true)
        var masks: URL?
        if settings.maskPeople || settings.overlay != nil {
            let m = folder.appendingPathComponent("masks", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: m, withIntermediateDirectories: true)
            } catch {
                throw GFramesError.outputFolder(error.localizedDescription)
            }
            masks = m
        }
        let planned = plan(analysis, selection)
        let (reader, output) = try await makeReader(url: info.url, pixelFormat: kCVPixelFormatType_32BGRA)
        let result = try scan(reader: reader, output: output, info: info, planned: planned, slug: slug,
                              images: images, masks: masks, folder: folder, settings: settings,
                              cancel: cancel, progress: progress)
        try Report.writeAll(folder: folder, info: info, analysis: analysis, selection: selection,
                            params: params, settings: settings, planned: planned, slug: slug, result: result)
        return result
    }

    private static func scan(reader: AVAssetReader,
                             output: AVAssetReaderTrackOutput,
                             info: VideoInfo,
                             planned: [PlannedFrame],
                             slug: String,
                             images: URL,
                             masks: URL?,
                             folder: URL,
                             settings: ExportSettings,
                             cancel: CancelFlag,
                             progress: @escaping (Double, Int, Int) -> Void) throws -> ExportResult {
        let started = Date()
        defer { if reader.status == .reading { reader.cancelReading() } }

        let ciContext = CIContext(options: [.cacheIntermediates: false])
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let queue = DispatchQueue(label: "gframes.encode", qos: .userInitiated, attributes: .concurrent)
        let group = DispatchGroup()
        let inFlight = DispatchSemaphore(value: settings.equirect ? 2 : 6)
        let counter = Counter()
        let coverage = CoverageLog()
        // Writes the person mask for one exported image (COLMAP naming: <image file>.png).
        let writeMask: (CGImage, String) -> Void = { cg, name in
            guard let dir = masks else { return }
            let url = dir.appendingPathComponent(name + ".png")
            if let m = PeopleMasker.mask(for: cg, people: settings.maskPeople, overlay: settings.overlay) {
                PeopleMasker.writePNG(m.image, to: url)
                coverage.set(name, m.coverage)
            } else if let blank = PeopleMasker.blankMask(width: cg.width, height: cg.height) {
                // Detection failed: an all-white mask keeps every pixel, so COLMAP still sees one mask per image.
                PeopleMasker.writePNG(blank, to: url)
                coverage.set(name, -1)
            }
        }
        let viewsPerFrame = settings.equirect ? settings.views.count : 1
        let totalImages = planned.count * viewsPerFrame

        var ptr = 0
        var frameIndex = -1
        var failure: String?

        while ptr < planned.count {
            if cancel.isCancelled {
                reader.cancelReading()
                group.wait()
                throw GFramesError.cancelled
            }
            var finished = false
            autoreleasepool {
                guard let sbuf = output.copyNextSampleBuffer() else { finished = true; return }
                guard let pb = CMSampleBufferGetImageBuffer(sbuf) else { return }
                frameIndex += 1
                while ptr < planned.count && planned[ptr].frame < frameIndex { ptr += 1 }
                guard ptr < planned.count, frameIndex == planned[ptr].frame else { return }
                let job = planned[ptr]
                ptr += 1

                if settings.equirect {
                    // Copy the panorama so decoding can continue while views are rendered.
                    CVPixelBufferLockBaseAddress(pb, .readOnly)
                    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
                    let rb = CVPixelBufferGetBytesPerRow(pb)
                    guard let base = CVPixelBufferGetBaseAddress(pb) else {
                        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                        failure = "could not access frame pixels"; finished = true; return
                    }
                    let pano = BGRAImage(w: w, h: h)
                    for y in 0..<h {
                        memcpy(pano.data + y * pano.rowBytes, base + y * rb, w * 4)
                    }
                    CVPixelBufferUnlockBaseAddress(pb, .readOnly)

                    inFlight.wait()
                    group.enter()
                    queue.async {
                        defer { inFlight.signal(); group.leave() }
                        for (vi, view) in settings.views.enumerated() {
                            let out = BGRAImage(w: settings.viewSize, h: settings.viewSize)
                            Equirect.render(view: view, fovDeg: settings.viewFOV, size: settings.viewSize,
                                            src: UnsafeRawPointer(pano.data), sw: pano.w, sh: pano.h,
                                            srcRowBytes: pano.rowBytes, dst: out)
                            var ok = false
                            if let cg = out.makeCGImage() {
                                let name = fileName(slug: slug, index: job.outputIndex, view: vi)
                                let url = images.appendingPathComponent(name)
                                let meta = ImageMeta(make: info.make, model: info.model,
                                                     focal35mm: 36.0 / (2 * tan(settings.viewFOV * Double.pi / 360)),
                                                     focalMM: nil,
                                                     description: String(format: "G-Frames: source frame %d, t=%.3fs, view yaw %.0f pitch %.0f",
                                                                         job.frame, job.time, view.yaw, view.pitch))
                                ok = ImageWriter.writeJPEG(cg, to: url, quality: settings.jpegQuality, meta: meta)
                                if ok { writeMask(cg, name) }
                            }
                            counter.add(success: ok)
                        }
                    }
                } else {
                    var img = CIImage(cvPixelBuffer: pb).oriented(info.orientation)
                    if let maxEdge = settings.maxLongEdge {
                        let ext = img.extent
                        let long = max(ext.width, ext.height)
                        if long > CGFloat(maxEdge) {
                            let s = CGFloat(maxEdge) / long
                            img = img.applyingFilter("CILanczosScaleTransform",
                                                     parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1.0])
                        }
                    }
                    let ext = img.extent
                    let w = Int(ext.width.rounded(.down)), h = Int(ext.height.rounded(.down))
                    guard w > 0, h > 0 else { failure = "empty frame"; finished = true; return }
                    let bmp = BGRAImage(w: w, h: h)
                    ciContext.render(img, toBitmap: bmp.data, rowBytes: bmp.rowBytes,
                                     bounds: CGRect(x: ext.minX, y: ext.minY, width: CGFloat(w), height: CGFloat(h)),
                                     format: .BGRA8, colorSpace: sRGB)
                    inFlight.wait()
                    group.enter()
                    queue.async {
                        defer { inFlight.signal(); group.leave() }
                        var ok = false
                        if let cg = bmp.makeCGImage() {
                            let name = fileName(slug: slug, index: job.outputIndex, view: nil)
                            let url = images.appendingPathComponent(name)
                            let meta = ImageMeta(make: info.make, model: info.model, focal35mm: info.focal35mm,
                                                 focalMM: nil,
                                                 description: String(format: "G-Frames: source frame %d, t=%.3fs",
                                                                     job.frame, job.time))
                            ok = ImageWriter.writeJPEG(cg, to: url, quality: settings.jpegQuality, meta: meta)
                            if ok { writeMask(cg, name) }
                        }
                        counter.add(success: ok)
                    }
                }
                let (done, bad) = counter.values
                progress(Double(done + bad) / Double(max(1, totalImages)), done + bad, totalImages)
            }
            if finished { break }
        }
        reader.cancelReading()
        group.wait()

        if let f = failure { throw GFramesError.readerFailed(f) }
        if reader.status == .failed {
            throw GFramesError.readerFailed(reader.error?.localizedDescription ?? "unknown error")
        }
        let (ok, bad) = counter.values
        progress(1, ok + bad, totalImages)
        return ExportResult(folder: folder, imagesFolder: images, frameCount: ptr,
                            imageCount: ok, failedWrites: bad, seconds: Date().timeIntervalSince(started),
                            masksFolder: masks, maskCoverage: coverage.all)
    }
}
