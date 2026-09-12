import AVFoundation
import CoreMedia
import Foundation

#if DEBUG
/// Reads finished MOV samples and compares PTS to `poses.json` (DEBUG only).
enum CaptureMOVIntegrityValidator {
    struct Report: Equatable, Sendable {
        var writtenFrames: Int
        var poseSamples: Int
        var movSamples: Int
        var ptsMatched: Int
        var ptsMismatched: Int
        var maxPTSDeltaSec: Double
        var countsEqual: Bool
        var passed: Bool
        var note: String

        static let empty = Report(
            writtenFrames: 0,
            poseSamples: 0,
            movSamples: 0,
            ptsMatched: 0,
            ptsMismatched: 0,
            maxPTSDeltaSec: 0,
            countsEqual: false,
            passed: false,
            note: "not_run"
        )
    }

    /// Tolerance: half a tick at timescale 600 (~0.83 ms).
    static var ptsToleranceSec: Double = 0.5 / 600.0

    static func validate(
        videoURL: URL,
        poses: [CaptureFrameSample],
        writtenFrames: Int
    ) -> Report {
        let movPTS: [Double]
        do {
            movPTS = try readVideoSamplePTSSeconds(url: videoURL)
        } catch {
            return Report(
                writtenFrames: writtenFrames,
                poseSamples: poses.count,
                movSamples: -1,
                ptsMatched: 0,
                ptsMismatched: poses.count,
                maxPTSDeltaSec: .infinity,
                countsEqual: false,
                passed: false,
                note: "reader_failed: \(error.localizedDescription)"
            )
        }

        let countsEqual = writtenFrames == poses.count && poses.count == movPTS.count
        var matched = 0
        var mismatched = 0
        var maxDelta: Double = 0
        let n = min(poses.count, movPTS.count)
        for i in 0..<n {
            let posePTS = poses[i].videoPTSSeconds
            let delta = abs(posePTS - movPTS[i])
            maxDelta = max(maxDelta, delta)
            if delta <= ptsToleranceSec {
                matched += 1
            } else {
                mismatched += 1
            }
        }
        if poses.count != movPTS.count {
            mismatched += abs(poses.count - movPTS.count)
        }

        let passed = countsEqual && mismatched == 0 && n == poses.count
        return Report(
            writtenFrames: writtenFrames,
            poseSamples: poses.count,
            movSamples: movPTS.count,
            ptsMatched: matched,
            ptsMismatched: mismatched,
            maxPTSDeltaSec: maxDelta.isFinite ? maxDelta : -1,
            countsEqual: countsEqual,
            passed: passed,
            note: passed
                ? "written==poses==mov AND pts within \(ptsToleranceSec)s"
                : "integrity check failed"
        )
    }

    private static func readVideoSamplePTSSeconds(url: URL) throws -> [Double] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw ValidatorError.noVideoTrack
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ValidatorError.cannotAddOutput }
        reader.add(output)
        guard reader.startReading() else {
            throw ValidatorError.readFailed(reader.error?.localizedDescription ?? "startReading")
        }

        var pts: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            let t = CMSampleBufferGetPresentationTimeStamp(sample)
            if t.isValid, !t.isIndefinite {
                pts.append(CMTimeGetSeconds(t))
            }
        }
        if reader.status == .failed {
            throw ValidatorError.readFailed(reader.error?.localizedDescription ?? "failed")
        }
        return pts
    }

    enum ValidatorError: LocalizedError {
        case noVideoTrack
        case cannotAddOutput
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "No video track"
            case .cannotAddOutput: return "Cannot add reader output"
            case .readFailed(let m): return m
            }
        }
    }
}
#endif
