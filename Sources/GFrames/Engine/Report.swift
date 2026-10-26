import Foundation

/// Writes the provenance files next to the images: frames.csv, analysis.json, report.txt, colmap.sh.
enum Report {
    static func writeAll(folder: URL, info: VideoInfo, analysis: AnalysisResult, selection: Selection,
                         params: SelectionParams, settings: ExportSettings, planned: [PlannedFrame],
                         slug: String, result: ExportResult) throws {
        try framesCSV(planned: planned, analysis: analysis, selection: selection, settings: settings, slug: slug,
                      maskCoverage: result.maskCoverage)
            .write(to: folder.appendingPathComponent("frames.csv"), atomically: true, encoding: .utf8)
        try analysisJSON(info: info, analysis: analysis, selection: selection, params: params, settings: settings)
            .write(to: folder.appendingPathComponent("analysis.json"))
        try reportText(info: info, analysis: analysis, selection: selection, params: params,
                       settings: settings, planned: planned, result: result)
            .write(to: folder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        let script = folder.appendingPathComponent("colmap.sh")
        try colmapScript(settings: settings, imageCount: result.imageCount, segments: selection.segmentStarts.count,
                         masks: result.masksFolder != nil)
            .write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    static func framesCSV(planned: [PlannedFrame], analysis: AnalysisResult, selection: Selection,
                          settings: ExportSettings, slug: String, maskCoverage: [String: Double]) -> String {
        var lines = ["index,file,source_frame,time_s,sharpness,rel_sharpness,cumulative_travel,segment,quality_ok,people_est,mask_coverage"]
        let starts = selection.segmentStarts
        for p in planned {
            let s = analysis.samples[p.sampleIndex]
            let seg = (starts.lastIndex { $0 <= p.sampleIndex } ?? 0) + 1
            let files: [String]
            if settings.equirect {
                files = (0..<settings.views.count).map { Extractor.fileName(slug: slug, index: p.outputIndex, view: $0) }
            } else {
                files = [Extractor.fileName(slug: slug, index: p.outputIndex, view: nil)]
            }
            for f in files {
                let nums = String(format: "%.4f,%.2f,%.3f,%.4f", s.time, s.sharpness,
                                  selection.relSharpness[p.sampleIndex], selection.cumulative[p.sampleIndex])
                let people = analysis.peopleDetected ? String(format: "%.3f", s.people) : ""
                var mask = ""
                if let m = maskCoverage[f] { mask = m < 0 ? "failed" : String(format: "%.3f", m) }
                lines.append("\(p.outputIndex),\(f),\(s.frame),\(nums),\(seg),\(p.qualityOK ? "yes" : "no"),\(people),\(mask)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    struct AnalysisDump: Codable {
        struct Video: Codable {
            var file: String; var duration: Double; var fps: Double; var width: Int; var height: Int
            var codec: String; var make: String?; var model: String?; var focal35mm: Double?
        }
        struct Params: Codable {
            var targetOverlap: Double; var blurThreshold: Double; var analysisRate: Double
            var equirectangular: Bool; var views: [ViewSpec]; var viewFOV: Double; var viewSize: Int
            var jpegQuality: Double; var maxLongEdge: Int?
            var peopleDetection: Bool; var avoidPeople: Bool; var maxPeople: Double; var personMasks: Bool
            var staticOverlayShare: Double?; var overlayMasked: Bool
            var algorithm: String
        }
        var app: String
        var created: String
        var video: Video
        var params: Params
        var totalFrames: Int
        var selectedSamples: [Int]
        var segmentStarts: [Int]
        var samples: [Sample]
    }

    static func analysisJSON(info: VideoInfo, analysis: AnalysisResult, selection: Selection,
                             params: SelectionParams, settings: ExportSettings) throws -> Data {
        let dump = AnalysisDump(
            app: "G-Frames 1.1 — Developed by Aymen Aiblu",
            created: ISO8601DateFormatter().string(from: Date()),
            video: .init(file: info.url.lastPathComponent, duration: info.duration, fps: info.fps,
                         width: info.displayWidth, height: info.displayHeight, codec: info.codec,
                         make: info.make, model: info.model, focal35mm: info.focal35mm),
            params: .init(targetOverlap: params.overlap, blurThreshold: params.blurThreshold,
                          analysisRate: analysis.analysisRate, equirectangular: settings.equirect,
                          views: settings.equirect ? settings.views : [], viewFOV: settings.viewFOV,
                          viewSize: settings.viewSize, jpegQuality: settings.jpegQuality,
                          maxLongEdge: settings.maxLongEdge,
                          peopleDetection: analysis.peopleDetected, avoidPeople: params.avoidPeople,
                          maxPeople: params.maxPeople, personMasks: settings.maskPeople,
                          staticOverlayShare: analysis.overlay?.coverage, overlayMasked: settings.overlay != nil,
                          algorithm: "pyramidal LK (4 levels, 11x11, fwd-bwd 0.5px) median normalised flow; overlap-step keyframing with sharpness window [0.5,1.0] step, extension 1.5 step; sharpness = Laplacian variance @1280px vs local 80th percentile (±2 s); people: Apple Vision person segmentation (fast during analysis, candidate score = rel_sharpness × (1 − coverage)^3; accurate + small-person rectangles for masks, dilated 1.2% of long edge); static overlays: textured (mean gradient > 12) yet static between moving frames (mean |dI| < 3) at 320 px, compact components box-filled and dilated, masked in every image; masks exclude pixels, nothing is inpainted"),
            totalFrames: analysis.totalFrames,
            selectedSamples: selection.picks.map { $0.sample }.sorted(),
            segmentStarts: selection.segmentStarts,
            samples: analysis.samples)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(dump)
    }

    static func reportText(info: VideoInfo, analysis: AnalysisResult, selection: Selection,
                           params: SelectionParams, settings: ExportSettings, planned: [PlannedFrame],
                           result: ExportResult) -> String {
        var r: [String] = []
        r.append("G-Frames 1.1 report — \(ISO8601DateFormatter().string(from: Date()))")
        r.append("Developed by Aymen Aiblu")
        r.append("")
        r.append("Video:      \(info.url.path)")
        r.append(String(format: "Duration:   %.1f s, %.3f fps, %d decoded frames", info.duration, info.fps, analysis.totalFrames))
        r.append("Resolution: \(info.displayWidth)×\(info.displayHeight) (\(info.codec))\(settings.equirect ? ", equirectangular 360°" : "")")
        let camera = [info.make, info.model].compactMap { $0 }.joined(separator: " ")
        if !camera.isEmpty { r.append("Camera:     \(camera)") }
        if let f = info.focal35mm { r.append(String(format: "Focal:      %.0f mm (35 mm equiv., from container metadata)", f)) }
        r.append("")
        r.append(String(format: "Analysis:   %d frames sampled at %.0f/s in %.0f s", analysis.samples.count, analysis.analysisRate, analysis.processingSeconds))
        r.append(String(format: "Target overlap %.0f%%, blur threshold %.2f", params.overlap * 100, params.blurThreshold))
        r.append(String(format: "Camera travel: %.2f frame-widths across %d segment(s)", selection.totalTravel, selection.segmentStarts.count))
        r.append("Selected frames: \(planned.count)  (flagged low-quality: \(selection.flaggedCount))")
        if settings.equirect {
            r.append("Views per frame: \(settings.views.count) @ \(settings.viewSize)px, \(Int(settings.viewFOV))° FOV")
        }
        r.append(String(format: "Images written: %d (failed: %d) in %.0f s", result.imageCount, result.failedWrites, result.seconds))
        if analysis.peopleDetected {
            let picked = selection.picks.map { analysis.samples[$0.sample].people }
            let all = analysis.samples.map { $0.people }
            if !picked.isEmpty && !all.isEmpty {
                r.append(String(format: "People in view (estimate): %.1f%% of selected frames' area on average, vs %.1f%% across the whole video",
                                100 * picked.reduce(0, +) / Double(picked.count), 100 * all.reduce(0, +) / Double(all.count)))
            }
        }
        if let ov = analysis.overlay {
            r.append(String(format: "Static overlay detected (logo, caption or bars): %.1f%% of the frame, %@",
                            100 * ov.coverage, settings.overlay != nil ? "masked in every image" : "NOT masked"))
        }
        let cov = result.maskCoverage.values.filter { $0 >= 0 }
        if result.masksFolder != nil {
            let failed = result.maskCoverage.values.filter { $0 < 0 }.count
            if !cov.isEmpty {
                let heavy = cov.filter { $0 > 0.4 }.count
                r.append(String(format: "Person masks: %d written, mean masked area %.1f%%, max %.1f%%, %d image(s) more than 40%% masked",
                                cov.count, 100 * cov.reduce(0, +) / Double(cov.count), 100 * (cov.max() ?? 0), heavy))
            }
            if failed > 0 { r.append("Person detection failed on \(failed) image(s); they received all-white masks (nothing excluded).") }
        }
        r.append("")
        if result.masksFolder != nil {
            r.append("Masks: masks/<image file name>.png, white = use, black = ignore. Nothing in images/ was altered or inpainted.")
            var what: [String] = []
            if settings.maskPeople { what.append("people") }
            if settings.overlay != nil { what.append("static overlay") }
            r.append("Masked: " + what.joined(separator: " + ") + ".")
            r.append("  COLMAP:    colmap.sh passes --ImageReader.mask_path masks (no features are extracted under people).")
            r.append("  Metashape: File > Import > Import Masks, Method: From File, Filename template: {filename}.jpg.png,")
            r.append("             then enable masks for tie points and depth maps during alignment and dense matching.")
            r.append("  OpenMVS:   check whether your build's DensifyPointCloud offers a mask option (DensifyPointCloud --help).")
            r.append("Shadows cast by people are not masked.")
            r.append("")
        }
        if selection.segmentStarts.count > 1 {
            r.append("Note: tracking was lost \(selection.segmentStarts.count - 1) time(s) (cuts, extreme blur or textureless views).")
            r.append("Segments may not connect with sequential matching; consider exhaustive or vocabulary-tree matching.")
            r.append("")
        }
        if selection.flaggedCount > 0 {
            r.append("Flagged frames (quality_ok = no in frames.csv) were the best available in their window but are")
            r.append("still blurry or badly exposed. Keep them for continuity unless reconstruction fails around them.")
            r.append("")
        }
        r.append("Run ./colmap.sh to build a sparse model with your COLMAP install (set COLMAP=/path/to/colmap if needed).")
        return r.joined(separator: "\n") + "\n"
    }

    static func colmapScript(settings: ExportSettings, imageCount: Int, segments: Int, masks: Bool) -> String {
        let maskArg = masks ? " \\\n  --ImageReader.mask_path masks" : ""
        var s = """
        #!/bin/bash
        # Generated by G-Frames (developed by Aymen Aiblu). Builds a sparse COLMAP model from ./images.
        # Override the binary with: COLMAP=/path/to/colmap ./colmap.sh
        set -euo pipefail
        cd "$(dirname "$0")"
        COLMAP="${COLMAP:-colmap}"
        mkdir -p sparse

        """
        if settings.equirect {
            let f = ViewRig.focalPixels(size: settings.viewSize, fovDeg: settings.viewFOV)
            let c = Double(settings.viewSize) / 2
            s += String(format: """
            # All virtual views share one exactly known pinhole camera.
            "$COLMAP" feature_extractor --database_path database.db --image_path images \\
              --ImageReader.single_camera 1 --ImageReader.camera_model PINHOLE \\
              --ImageReader.camera_params "%.4f,%.4f,%.4f,%.4f"
            """, f, f, c, c) + maskArg + "\n\n"
        } else {
            s += """
            # Video = one camera with fixed intrinsics; COLMAP refines them.
            "$COLMAP" feature_extractor --database_path database.db --image_path images \\
              --ImageReader.single_camera 1 --ImageReader.camera_model OPENCV
            """ + maskArg + "\n\n"
        }
        let overlap = settings.equirect ? settings.views.count * 3 : 15
        if segments > 1 && imageCount <= 1500 {
            s += """
            # Tracking was lost between segments: exhaustive matching reconnects them.
            "$COLMAP" exhaustive_matcher --database_path database.db

            """
        } else {
            s += """
            "$COLMAP" sequential_matcher --database_path database.db --SequentialMatching.overlap \(overlap)

            """
        }
        s += """
        "$COLMAP" mapper --database_path database.db --image_path images --output_path sparse
        echo "Done. Sparse model(s) in ./sparse"

        """
        return s
    }
}
