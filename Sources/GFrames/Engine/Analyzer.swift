import Foundation
import AVFoundation
import Accelerate

/// One analysed frame.
struct Sample: Codable {
    var frame: Int          // decode-order index of the frame in the video
    var time: Double        // presentation time, seconds
    var sharpness: Double   // Laplacian variance at ~1280 px
    var motion: Double      // normalised displacement since the previous analysed frame
    var valid: Bool         // false = tracking lost (cut, extreme blur, textureless) -> new segment
    var inliers: Double
    var brightness: Double  // 0...255
    var people: Double      // share of the frame covered by people (0 when detection is off)
}

struct AnalysisResult: Codable {
    var samples: [Sample]
    var totalFrames: Int
    var analysisRate: Double
    var equirectangular: Bool
    var peopleDetected: Bool
    /// Burned-in static overlay (logo, caption) found in the footage, if any.
    var overlay: OverlayMask?
    var processingSeconds: Double
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Planar-8 scratch buffer for vImage.
final class Plane8 {
    let w: Int
    let h: Int
    let rowBytes: Int
    let data: UnsafeMutableRawPointer

    init(w: Int, h: Int) {
        let rb = (w + 15) & ~15
        self.w = w
        self.h = h
        self.rowBytes = rb
        self.data = UnsafeMutableRawPointer.allocate(byteCount: rb * h, alignment: 64)
    }
    deinit { data.deallocate() }

    var bytes: UnsafePointer<UInt8> { UnsafePointer(data.assumingMemoryBound(to: UInt8.self)) }

    func vbuf() -> vImage_Buffer {
        vImage_Buffer(data: data, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: rowBytes)
    }
}

func fitLong(_ w: Int, _ h: Int, _ long: Int) -> (Int, Int) {
    let m = max(w, h)
    if m <= long { return (w, h) }
    let s = Double(long) / Double(m)
    return (max(1, Int((Double(w) * s).rounded())), max(1, Int((Double(h) * s).rounded())))
}

enum Analyzer {
    static let sharpLong = 1280
    static let motionLong = 320
    static let motionLong360 = 640
    static let pyramidLevels = 4

    /// Single streaming pass over the whole video. Memory use is constant regardless of length.
    static func run(info: VideoInfo,
                    rate: Double,
                    equirect: Bool,
                    detectPeople: Bool,
                    detectOverlays: Bool,
                    cancel: CancelFlag,
                    progress: @escaping (Double, Int, Int) -> Void) async throws -> AnalysisResult {
        let (reader, output) = try await makeReader(url: info.url,
                                                    pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        return try scan(reader: reader, output: output, info: info, rate: rate, equirect: equirect,
                        detectPeople: detectPeople, detectOverlays: detectOverlays && !equirect,
                        cancel: cancel, progress: progress)
    }

    /// Synchronous decode loop (kept out of the async context so autoreleasepool can be used freely).
    private static func scan(reader: AVAssetReader,
                             output: AVAssetReaderTrackOutput,
                             info: VideoInfo,
                             rate: Double,
                             equirect: Bool,
                             detectPeople: Bool,
                             detectOverlays: Bool,
                             cancel: CancelFlag,
                             progress: @escaping (Double, Int, Int) -> Void) throws -> AnalysisResult {
        let started = Date()
        let probe = detectPeople ? PeopleProbe() : nil
        let overlays = detectOverlays ? OverlayAccumulator() : nil
        defer { if reader.status == .reading { reader.cancelReading() } }

        let tracker = LKTracker(equirectangular: equirect)
        var samples: [Sample] = []
        samples.reserveCapacity(Int(info.duration * rate) + 16)

        var sharpPlane: Plane8?
        var motionPlane: Plane8?
        var prevPyr: Pyramid?
        var frameIndex = -1
        var nextT = -Double.infinity
        let dt = 1.0 / rate
        var lastReport = Date.distantPast
        var failure: String?

        while true {
            if cancel.isCancelled { reader.cancelReading(); throw GFramesError.cancelled }
            var finished = false
            autoreleasepool {
                guard let sbuf = output.copyNextSampleBuffer() else { finished = true; return }
                guard let pb = CMSampleBufferGetImageBuffer(sbuf) else { return }
                frameIndex += 1
                let t = CMSampleBufferGetPresentationTimeStamp(sbuf).seconds
                let tt = t.isFinite ? t : Double(frameIndex) / info.fps

                let now = Date()
                if now.timeIntervalSince(lastReport) > 0.2 {
                    lastReport = now
                    progress(info.duration > 0 ? min(1, tt / info.duration) : 0, frameIndex, samples.count)
                }

                if tt + 1e-6 < nextT { return }
                nextT = (nextT < tt - dt) ? tt + dt : nextT + dt

                let people = probe?.coverage(pb, orientation: info.orientation) ?? 0

                CVPixelBufferLockBaseAddress(pb, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }
                let w = CVPixelBufferGetWidthOfPlane(pb, 0)
                let h = CVPixelBufferGetHeightOfPlane(pb, 0)
                let rb = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)

                let (sw, sh) = fitLong(w, h, sharpLong)
                if sharpPlane == nil || sharpPlane!.w != sw || sharpPlane!.h != sh {
                    sharpPlane = Plane8(w: sw, h: sh)
                }
                let (mw, mh) = fitLong(sw, sh, equirect ? motionLong360 : motionLong)
                if motionPlane == nil || motionPlane!.w != mw || motionPlane!.h != mh {
                    motionPlane = Plane8(w: mw, h: mh)
                    prevPyr = nil
                }
                guard let sp = sharpPlane, let mp = motionPlane else { return }

                var src = vImage_Buffer(data: base, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: rb)
                var sdst = sp.vbuf()
                var err = vImageScale_Planar8(&src, &sdst, nil, vImage_Flags(kvImageNoFlags))
                if err != kvImageNoError { failure = "vImage scale error \(err)"; finished = true; return }
                var mdst = mp.vbuf()
                err = vImageScale_Planar8(&sdst, &mdst, nil, vImage_Flags(kvImageNoFlags))
                if err != kvImageNoError { failure = "vImage scale error \(err)"; finished = true; return }

                let sharp = laplacianVariance(bytes: sp.bytes, w: sw, h: sh, rowBytes: sp.rowBytes)
                let bright = planeMean(bytes: sp.bytes, w: sw, h: sh, rowBytes: sp.rowBytes)
                let gray = GrayF(bytes: mp.bytes, w: mw, h: mh, rowBytes: mp.rowBytes)
                let pyr = Pyramid(base: gray, count: pyramidLevels)

                var motion = 0.0, valid = true, inl = 1.0
                if let prev = prevPyr {
                    let est = tracker.motion(from: prev, to: pyr)
                    valid = est.valid
                    motion = est.valid ? est.displacement : 0
                    inl = est.inlierFraction
                }
                prevPyr = pyr
                overlays?.add(gray, moving: valid && motion > 0.002)
                samples.append(Sample(frame: frameIndex, time: tt, sharpness: sharp, motion: motion,
                                      valid: valid, inliers: inl, brightness: bright, people: people))
            }
            if finished { break }
        }

        if let f = failure { throw GFramesError.readerFailed(f) }
        if reader.status == .failed {
            throw GFramesError.readerFailed(reader.error?.localizedDescription ?? "unknown error")
        }
        progress(1, frameIndex + 1, samples.count)
        return AnalysisResult(samples: samples,
                              totalFrames: frameIndex + 1,
                              analysisRate: rate,
                              equirectangular: equirect,
                              peopleDetected: detectPeople,
                              overlay: overlays?.result(),
                              processingSeconds: Date().timeIntervalSince(started))
    }
}
