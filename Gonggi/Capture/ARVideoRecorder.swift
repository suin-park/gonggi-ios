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
        let droppedFrameCount: Int
        let preferredTransform: [Double]
        let imageResolutionWidth: Int
        let imageResolutionHeight: Int
    }

    /// Returned only when a pixel buffer is actually appended to the MOV.
    struct WrittenFrame: Equatable {
        let videoFrameIndex: Int
        let sourceARTimestampSeconds: TimeInterval
        let arTimestampValue: Int64
        let arTimestampTimescale: Int32
        let videoPTSValue: Int64
        let videoPTSTimescale: Int32
        let videoPTSSeconds: Double
        let imageWidth: Int
        let imageHeight: Int
    }

    private let queue = DispatchQueue(label: "com.whik.gonggi.ar-video-recorder")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: CMTime?
    private var frameCount = 0
    private var droppedFrameCount = 0
    private var outputURL: URL?
    private var targetFPS: Double = 30
    private var configuredWidth: Int = 0
    private var configuredHeight: Int = 0
    private var sessionStarted = false
    private var recordedPreferredTransform: [Double] = [1, 0, 0, 1, 0, 0]
    private var recordedImageResolutionWidth = 0
    private var recordedImageResolutionHeight = 0
    private var _prefer4K = true
    private var configured = false

    func startRecording(to url: URL, prefer4K: Bool = true) throws {
        try queue.sync {
            outputURL = url
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            frameCount = 0
            droppedFrameCount = 0
            startTime = nil
            sessionStarted = false
            writer = nil
            input = nil
            adaptor = nil
            configured = false
            recordedPreferredTransform = [1, 0, 0, 1, 0, 0]
            recordedImageResolutionWidth = 0
            recordedImageResolutionHeight = 0
        }
        _prefer4K = prefer4K
    }

    /// Appends `ARFrame.capturedImage`. Returns mapping only on successful write
    /// so pose/intrinsics can share the same index (dropped frames skip pose rows).
    @discardableResult
    func append(frame: ARFrame) -> WrittenFrame? {
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

    private func appendLocked(frame: ARFrame) -> WrittenFrame? {
        guard outputURL != nil else { return nil }
        let pixelBuffer = frame.capturedImage
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        if !configured {
            do {
                try configureWriter(pixelBuffer: pixelBuffer, frame: frame)
                configured = true
            } catch {
                droppedFrameCount += 1
                return nil
            }
        }

        guard let writer, let input, let adaptor else {
            droppedFrameCount += 1
            return nil
        }
        guard writer.status != .failed, writer.status != .cancelled, writer.status != .completed else {
            droppedFrameCount += 1
            return nil
        }

        let timescale = CaptureFrameContract.writerTimescale
        let time = CaptureFrameContract.cmTime(fromSeconds: frame.timestamp, timescale: timescale)
        if !sessionStarted {
            guard writer.startWriting() else {
                droppedFrameCount += 1
                return nil
            }
            writer.startSession(atSourceTime: time)
            startTime = time
            sessionStarted = true
        }

        guard writer.status == .writing, input.isReadyForMoreMediaData else {
            droppedFrameCount += 1
            return nil
        }

        let relative = CMTimeSubtract(time, startTime ?? time)
        if adaptor.append(pixelBuffer, withPresentationTime: relative) {
            let index = frameCount
            frameCount += 1
            return WrittenFrame(
                videoFrameIndex: index,
                sourceARTimestampSeconds: frame.timestamp,
                arTimestampValue: time.value,
                arTimestampTimescale: time.timescale,
                videoPTSValue: relative.value,
                videoPTSTimescale: relative.timescale,
                videoPTSSeconds: CMTimeGetSeconds(relative),
                imageWidth: width,
                imageHeight: height
            )
        }
        droppedFrameCount += 1
        return nil
    }

    private func configureWriter(pixelBuffer: CVPixelBuffer, frame: ARFrame) throws {
        guard let url = outputURL else { throw RecorderError.notStarted }

        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)

        var width = srcWidth
        var height = srcHeight
        if _prefer4K, max(srcWidth, srcHeight) >= 3000 {
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
        let transform = videoTransform(for: frame)
        input.transform = transform
        recordedPreferredTransform = CaptureFrameContract.encodeAffine(transform)
        let res = frame.camera.imageResolution
        recordedImageResolutionWidth = Int(res.width.rounded())
        recordedImageResolutionHeight = Int(res.height.rounded())

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
            frameCount: frameCount,
            droppedFrameCount: droppedFrameCount,
            preferredTransform: recordedPreferredTransform,
            imageResolutionWidth: recordedImageResolutionWidth,
            imageResolutionHeight: recordedImageResolutionHeight
        )
        resetLocked()
        return result
    }

    private func safeAbortWritingLocked() {
        guard let writer else { return }
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
        droppedFrameCount = 0
        outputURL = nil
        configuredWidth = 0
        configuredHeight = 0
        recordedPreferredTransform = [1, 0, 0, 1, 0, 0]
        recordedImageResolutionWidth = 0
        recordedImageResolutionHeight = 0
    }

    private func videoTransform(for frame: ARFrame) -> CGAffineTransform {
        _ = frame
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
