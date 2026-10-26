import Foundation
import AVFoundation
import ImageIO

enum GFramesError: LocalizedError {
    case noVideoTrack
    case readerFailed(String)
    case cancelled
    case outputFolder(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "This file has no readable video track."
        case .readerFailed(let s): return "Video decoding failed: \(s)"
        case .cancelled: return "Cancelled."
        case .outputFolder(let s): return "Could not create the output folder: \(s)"
        }
    }
}

/// Everything we need to know about a video before analysing it.
struct VideoInfo {
    let url: URL
    let name: String
    let fileSize: Int64
    let duration: Double
    let fps: Double
    let estimatedFrames: Int
    /// Encoded (sensor) dimensions.
    let pixelWidth: Int
    let pixelHeight: Int
    /// Dimensions after applying the rotation flag.
    let displayWidth: Int
    let displayHeight: Int
    let orientation: CGImagePropertyOrientation
    let codec: String
    let isLikely360: Bool
    let make: String?
    let model: String?
    /// 35 mm-equivalent focal length if the container carries it (e.g. iPhone footage).
    let focal35mm: Double?
}

enum VideoProbe {
    static func probe(_ url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw GFramesError.noVideoTrack }

        let duration = try await asset.load(.duration)
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let nominalFPS = try await track.load(.nominalFrameRate)
        let formats = try await track.load(.formatDescriptions)

        var codec = "unknown"
        if let fd = formats.first {
            codec = fourCC(CMFormatDescriptionGetMediaSubType(fd))
        }

        let angle = atan2(Double(transform.b), Double(transform.a)) * 180.0 / Double.pi
        let rounded = Int(angle.rounded())
        let orientation: CGImagePropertyOrientation
        switch rounded {
        case 85...95: orientation = .right
        case -95 ... -85: orientation = .left
        case 175...180, -180 ... -175: orientation = .down
        default: orientation = .up
        }
        let pw = Int(abs(size.width).rounded())
        let ph = Int(abs(size.height).rounded())
        let swapped = orientation == .right || orientation == .left
        let dw = swapped ? ph : pw
        let dh = swapped ? pw : ph

        let seconds = duration.seconds.isFinite ? duration.seconds : 0
        let fps = nominalFPS > 0 ? Double(nominalFPS) : 30.0

        var fileSize: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let n = attrs[.size] as? NSNumber {
            fileSize = n.int64Value
        }

        // Metadata: make / model / 35 mm-equivalent focal length when present.
        var make: String?
        var model: String?
        var focal: Double?
        var items: [AVMetadataItem] = []
        if let m = try? await asset.load(.metadata) { items.append(contentsOf: m) }
        for item in items {
            let key = (item.identifier?.rawValue ?? "").lowercased()
            if make == nil, item.commonKey == .commonKeyMake || key.hasSuffix(".make") {
                make = try? await item.load(.stringValue)
            } else if model == nil, item.commonKey == .commonKeyModel || key.hasSuffix(".model") {
                model = try? await item.load(.stringValue)
            } else if focal == nil, key.contains("focal_length"), key.contains("35") {
                if let num = try? await item.load(.numberValue) {
                    focal = num.doubleValue
                } else if let s = try? await item.load(.stringValue) {
                    focal = Double(s.filter { "0123456789.".contains($0) })
                }
            }
        }
        if let f = focal, !(f > 5 && f < 1000) { focal = nil }

        let ratio = Double(dw) / Double(max(dh, 1))
        let is360 = abs(ratio - 2.0) < 0.03 && dw >= 1920

        return VideoInfo(
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            fileSize: fileSize,
            duration: seconds,
            fps: fps,
            estimatedFrames: Int((seconds * fps).rounded()),
            pixelWidth: pw, pixelHeight: ph,
            displayWidth: dw, displayHeight: dh,
            orientation: orientation,
            codec: codec,
            isLikely360: is360,
            make: make?.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model?.trimmingCharacters(in: .whitespacesAndNewlines),
            focal35mm: focal
        )
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff), UInt8(code & 0xff)
        ]
        let s = String(bytes: bytes, encoding: .ascii) ?? "????"
        switch s {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "apcn", "apch", "apcs", "apco", "ap4h", "ap4x": return "ProRes"
        case "av01": return "AV1"
        default: return s.trimmingCharacters(in: .whitespaces)
        }
    }
}

/// Opens the first video track for sequential reading.
func makeReader(url: URL, pixelFormat: OSType) async throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let track = tracks.first else { throw GFramesError.noVideoTrack }
    let reader = try AVAssetReader(asset: asset)
    let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: Int(pixelFormat)]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw GFramesError.readerFailed("cannot attach track output") }
    reader.add(output)
    guard reader.startReading() else {
        throw GFramesError.readerFailed(reader.error?.localizedDescription ?? "could not start reading")
    }
    return (reader, output)
}
