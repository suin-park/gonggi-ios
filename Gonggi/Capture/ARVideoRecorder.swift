import ARKit
import AVFoundation
import CoreVideo
import Foundation
import UIKit

/// Records video from ARKit `ARFrame.capturedImage` via AVAssetWriter.
///
/// **Why not AVCaptureMovieFileOutput + ARSession?**
/// iOS grants exclusive camera access to one capture pipeline. Running a parallel
/// `AVCaptureSession` alongside `ARSession` causes failures or degraded tracking on
/// physical devices. ARFrame → AVAssetWriter is Apple's recommended pattern for
/// AR video recording.
final class ARVideoRecorder: @unchecked Sendable {
    struct Result: Equatable {
        let url: URL
        let byteSize: Int64
        let width: Int
        let height: Int
        let fps: Double
        let codec: String
        let frameCount: Int
    }

    private let queue = DispatchQueue(label: "com.whik.gonggi.ar-video-recorder")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: CMTime?
    private var frameCount = 0
    private var outputURL: URL?
    private var targetFPS: Double = 30
    private var configuredWidth: Int = 0
    private var configuredHeight: Int = 0
    private var sessionStarted = false

    func startRecording(to url: URL, prefer4K: Bool = true) throws {
        try queue.sync {
            outputURL = url
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            frameCount = 0
            startTime = nil
            sessionStarted = false
            writer = nil
            input = nil
            adaptor = nil
            configured = false
        }
        _prefer4K = prefer4K
    }

    private var _prefer4K = true
    private var configured = false

    func append(frame: ARFrame) {
        queue.sync {
            appendLocked(frame: frame)
        }
    }

    func finish() async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: RecorderError.notStarted)
                    return
                }
                do {
                    let result = try self.finishLocked()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            let url = outputURL
            self.safeAbortWritingLocked()
            if let url {
                try? FileManager.default.removeItem(at: url)
            }
            self.resetLocked()
        }
    }

    // MARK: - Private

    private func appendLocked(frame: ARFrame) {
        guard outputURL != nil else { return }
        let pixelBuffer = frame.capturedImage

        if !configured {
            do {
                try configureWriter(pixelBuffer: pixelBuffer, frame: frame)
                configured = true
            } catch {
                return
            }
        }

        guard let writer, let input, let adaptor else { return }
        guard writer.status != .failed, writer.status != .cancelled, writer.status != .completed else {
            return
        }

        let time = CMTime(seconds: frame.timestamp, preferredTimescale: 600)
        if !sessionStarted {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: time)
            startTime = time
            sessionStarted = true
        }

        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }

        let relative = CMTimeSubtract(time, startTime ?? time)
        if adaptor.append(pixelBuffer, withPresentationTime: relative) {
            frameCount += 1
        }
    }

    private func configureWriter(pixelBuffer: CVPixelBuffer, frame: ARFrame) throws {
        guard let url = outputURL else { throw RecorderError.notStarted }

        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)

        var width = srcWidth
        var height = srcHeight
        if _prefer4K, max(srcWidth, srcHeight) >= 3000 {
            // Keep native buffer size — ARKit typically delivers up to 3840×2160 on Pro devices.
            width = srcWidth
            height = srcHeight
        }

        targetFPS = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 24_000_000,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        input.transform = videoTransform(for: frame)

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attrs
        )

        guard writer.canAdd(input) else { throw RecorderError.cannotAddInput }
        writer.add(input)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        configuredWidth = width
        configuredHeight = height
    }

    private func finishLocked() throws -> Result {
        guard let writer, let input, let url = outputURL else {
            throw RecorderError.notStarted
        }

        // Never call markAsFinished unless the writer is actively writing —
        // otherwise AVFoundation raises an ObjC exception that bypasses Swift `catch`
        // and aborts the process (TestFlight: “그냥 꺼집니다”).
        guard sessionStarted, writer.status == .writing else {
            safeAbortWritingLocked()
            resetLocked()
            throw RecorderError.finishFailed("recording never started (no frames)")
        }

        input.markAsFinished()
        let group = DispatchGroup()
        group.enter()
        writer.finishWriting { group.leave() }
        _ = group.wait(timeout: .now() + 30)

        guard writer.status == .completed else {
            let message = writer.error?.localizedDescription ?? "status=\(writer.status.rawValue)"
            resetLocked()
            throw RecorderError.finishFailed(message)
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let result = Result(
            url: url,
            byteSize: size,
            width: configuredWidth,
            height: configuredHeight,
            fps: targetFPS,
            codec: "hevc",
            frameCount: frameCount
        )
        resetLocked()
        return result
    }

    /// Cancel / tear down without ObjC exceptions when writer never entered `.writing`.
    private func safeAbortWritingLocked() {
        guard let writer else { return }
        // Both markAsFinished and cancelWriting raise if startWriting never ran.
        guard writer.status == .writing else { return }
        input?.markAsFinished()
        writer.cancelWriting()
    }

    private func resetLocked() {
        writer = nil
        input = nil
        adaptor = nil
        startTime = nil
        sessionStarted = false
        configured = false
        frameCount = 0
        outputURL = nil
        configuredWidth = 0
        configuredHeight = 0
    }

    private func videoTransform(for frame: ARFrame) -> CGAffineTransform {
        // Portrait capture — rotate landscape buffer.
        switch UIDevice.current.orientation {
        case .landscapeLeft:
            return CGAffineTransform(rotationAngle: .pi / 2)
        case .landscapeRight:
            return CGAffineTransform(rotationAngle: -.pi / 2)
        default:
            return CGAffineTransform(rotationAngle: .pi / 2)
        }
    }

    enum RecorderError: LocalizedError {
        case notStarted
        case cannotAddInput
        case finishFailed(String)

        var errorDescription: String? {
            switch self {
            case .notStarted: return "Recorder not started"
            case .cannotAddInput: return "Cannot add video input"
            case .finishFailed(let m): return "Finish failed: \(m)"
            }
        }
    }
}
