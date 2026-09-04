import AVFoundation
import CoreVideo
import Foundation
import UIKit

/// AVFoundation capture + strip acceptance for horizontal panorama.
final class PanoramaCaptureEngine: NSObject {
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.whik.gonggi.panorama.capture", qos: .userInitiated)
    private let composer = PanoramaStripComposer()
    private let motion = PanoramaMotionGuide()

    private(set) var phase: PanoramaCapturePhase = .idle
    private(set) var feedback: PanoramaGuideFeedback = .idle
    private(set) var direction: PanoramaScanDirection = .right
    private(set) var lastAcceptedYaw: Float?
    private(set) var rejectCounts: [String: Int] = [:]
    private(set) var processedFrameCount: Int = 0

    private var isCapturing = false
    private var captureStartedAt: TimeInterval = 0
    private var lastFrameTime: TimeInterval = 0
    var onUIUpdate: (() -> Void)?

    var acceptedStripCount: Int { composer.placements.count }
    var yawSpanDeg: Float { composer.yawSpanDeg() }
    var pxPerDegree: Float { composer.pxPerDegree }

    func prepareCamera() throws {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw PanoramaCaptureError.cameraUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw PanoramaCaptureError.cameraUnavailable }
        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(videoOutput) else { throw PanoramaCaptureError.cameraUnavailable }
        session.addOutput(videoOutput)
        if let conn = videoOutput.connection(with: .video) {
            if conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
            if conn.isVideoMirroringSupported {
                conn.isVideoMirrored = false
            }
        }
        session.commitConfiguration()
        phase = .ready
        feedback = .idle
        notify()
    }

    func startSession() {
        guard !session.isRunning else { return }
        queue.async { [weak self] in
            self?.session.startRunning()
        }
        motion.start()
    }

    func stopSession() {
        queue.async { [weak self] in
            self?.session.stopRunning()
        }
        motion.stop()
    }

    func beginCapture() {
        composer.reset()
        motion.resetReference()
        rejectCounts.removeAll()
        processedFrameCount = 0
        lastAcceptedYaw = nil
        isCapturing = true
        captureStartedAt = ProcessInfo.processInfo.systemUptime
        phase = .capturing
        feedback = .followLine
        direction = .right
        notify()
    }

    func finishCapture(
        sessionId: String,
        captureId: String
    ) async throws -> PanoramaCaptureResult {
        isCapturing = false
        phase = .composing
        notify()
        let t0 = ProcessInfo.processInfo.systemUptime
        let duration = t0 - captureStartedAt

        guard let composed = composer.composeUIImage(cropToContent: true) else {
            phase = .failed("파노라마를 만들 프레임이 부족해요")
            notify()
            throw PanoramaCaptureError.insufficientStrips
        }

        let finalImg = PanoramaStripComposer.resize(
            composed, longEdge: PanoramaCaptureConfig.finalLongEdgePx
        )
        let previewImg = PanoramaStripComposer.resize(
            composed, longEdge: PanoramaCaptureConfig.previewLongEdgePx
        )

        let dir = try CaptureSessionStore.createPanoramaScanDirectory(sessionId: sessionId)
        let finalURL = dir.appendingPathComponent("final_panorama.jpg")
        let previewURL = dir.appendingPathComponent("preview.jpg")
        guard let finalData = finalImg.jpegData(compressionQuality: 0.92),
              let previewData = previewImg.jpegData(compressionQuality: 0.85) else {
            throw PanoramaCaptureError.encodeFailed
        }
        try finalData.write(to: finalURL, options: .atomic)
        try previewData.write(to: previewURL, options: .atomic)

        let processSec = ProcessInfo.processInfo.systemUptime - t0
        let avgSpeed: Float
        if duration > 0.2, composer.placements.count > 1 {
            avgSpeed = yawSpanDeg / Float(duration)
        } else {
            avgSpeed = 0
        }

        let report = PanoramaCaptureReport(
            sessionId: sessionId,
            captureId: captureId,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            captureDurationSec: duration,
            processingTimeSec: processSec,
            acceptedStripCount: composer.placements.count,
            rejectedFrameCount: rejectCounts.values.reduce(0, +),
            rejectReasons: rejectCounts,
            yawSpanDeg: yawSpanDeg,
            avgRotationSpeedDegPerSec: avgSpeed,
            outputWidth: Int(finalImg.size.width.rounded()),
            outputHeight: Int(finalImg.size.height.rounded()),
            previewWidth: Int(previewImg.size.width.rounded()),
            previewHeight: Int(previewImg.size.height.rounded()),
            stripWidthPx: PanoramaCaptureConfig.stripWidthPx,
            pxPerDegree: composer.pxPerDegree,
            memoryEstimateMB: Double(composer.canvasWidth * composer.canvasHeight * 5)
                / (1024 * 1024),
            meanVerticalAlignPx: composer.meanVerticalAlignPx,
            seamFeatherPx: PanoramaCaptureConfig.seamFeatherPx,
            finalPanoramaPath: finalURL.path,
            previewPath: previewURL.path
        )
        let reportURL = try CaptureSessionStore.panoramaScanReportURL(sessionId: sessionId)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(report).write(to: reportURL, options: .atomic)

        // Debug traces (lightweight).
        let debugDir = try CaptureSessionStore.createPanoramaScanDebugDirectory(sessionId: sessionId)
        let layout: [[String: Any]] = composer.placements.map {
            [
                "index": $0.index,
                "yawDeg": $0.yawDeg,
                "x": $0.xOnCanvas,
                "vOffset": $0.verticalOffsetPx
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: [
            "placements": layout,
            "pxPerDegree": composer.pxPerDegree,
            "canvasWidth": composer.canvasWidth,
            "canvasHeight": composer.canvasHeight
        ], options: [.prettyPrinted]) {
            try? data.write(to: debugDir.appendingPathComponent("strip_layout.json"))
        }
        if let motionData = try? JSONSerialization.data(withJSONObject: [
            "samples": motion.samples.suffix(500).map {
                ["t": $0.timestamp, "yaw": $0.yawDeg, "pitch": $0.pitchDeg, "roll": $0.rollDeg]
            }
        ], options: [.prettyPrinted]) {
            try? motionData.write(to: debugDir.appendingPathComponent("motion_trace.json"))
        }

        phase = .preview
        notify()
        return PanoramaCaptureResult(
            sessionId: sessionId,
            captureId: captureId,
            finalJPEGURL: finalURL,
            previewJPEGURL: previewURL,
            report: report,
            previewImage: previewImg,
            finalImage: finalImg
        )
    }

    func cancelCapture() {
        isCapturing = false
        composer.reset()
        phase = .ready
        feedback = .idle
        notify()
    }

    // MARK: - Mock path (simulator / tests)

    func ingestMockFrame(rgba: [UInt8], width: Int, height: Int, yawDeg: Float) {
        guard isCapturing else { return }
        _ = tryAccept(rgba: rgba, width: width, height: height, yawDeg: yawDeg, pitch: 0, roll: 0)
        feedback = motion.feedback(
            isCapturing: true,
            lastAcceptedYaw: lastAcceptedYaw,
            yawSpanDeg: yawSpanDeg
        )
        notify()
    }

    func beginMockCapture() {
        beginCapture()
    }

    // MARK: - Private

    private func notify() {
        DispatchQueue.main.async { [weak self] in
            self?.onUIUpdate?()
        }
    }

    private func reject(_ code: String) {
        rejectCounts[code, default: 0] += 1
    }

    private func tryAccept(
        rgba: [UInt8],
        width: Int,
        height: Int,
        yawDeg: Float,
        pitch: Float,
        roll: Float,
        frameWidthForFov: Int? = nil
    ) -> Bool {
        processedFrameCount += 1
        if abs(pitch) > PanoramaCaptureConfig.maxPitchDeg
            || abs(roll) > PanoramaCaptureConfig.maxRollDeg {
            reject("level")
            return false
        }
        if let last = lastAcceptedYaw {
            let dy = abs(yawDeg - last)
            if dy < PanoramaCaptureConfig.minYawDeltaDeg {
                reject("yaw_small")
                return false
            }
            if dy > PanoramaCaptureConfig.maxYawDeltaDeg {
                reject("yaw_fast")
                return false
            }
            if yawDeg >= last { direction = .right } else { direction = .left }
        }
        let sharp = PanoramaStripComposer.sharpnessScore(rgba: rgba, width: width, height: height)
        // Strip-only frames have less spatial context; use a softer blur gate.
        if sharp < 2.5 {
            reject("blur")
            return false
        }
        let ok = composer.acceptFrame(
            rgba: rgba,
            width: width,
            height: height,
            yawDeg: yawDeg,
            frameWidthForFov: frameWidthForFov
        )
        if ok {
            lastAcceptedYaw = yawDeg
        } else {
            reject("compose")
        }
        return ok
    }
}

enum PanoramaCaptureError: Error, LocalizedError {
    case cameraUnavailable
    case insufficientStrips
    case encodeFailed
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable: return "카메라를 열 수 없어요"
        case .insufficientStrips: return "파노라마를 만들 프레임이 부족해요"
        case .encodeFailed: return "이미지 저장에 실패했어요"
        case .notAuthorized: return "카메라 권한이 필요해요"
        }
    }
}

extension PanoramaCaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isCapturing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastFrameTime < 0.045 { return } // ~22 fps cap
        lastFrameTime = now

        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let m = motion.latest
        feedback = motion.feedback(
            isCapturing: true,
            lastAcceptedYaw: lastAcceptedYaw,
            yawSpanDeg: yawSpanDeg
        )

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)

        // Center strip only (BGRA → RGBA) — full-frame convert is too heavy for realtime.
        let stripW = min(PanoramaCaptureConfig.stripWidthPx, w)
        let sx0 = max(0, (w - stripW) / 2)
        var rgba = [UInt8](repeating: 0, count: stripW * h * 4)
        for y in 0..<h {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<stripW {
                let si = (sx0 + x) * 4
                let di = (y * stripW + x) * 4
                rgba[di] = row[si + 2]
                rgba[di + 1] = row[si + 1]
                rgba[di + 2] = row[si]
                rgba[di + 3] = 255
            }
        }

        _ = tryAccept(
            rgba: rgba, width: stripW, height: h,
            yawDeg: m.yawDeg, pitch: m.pitchDeg, roll: m.rollDeg,
            frameWidthForFov: w
        )
        notify()
    }
}
