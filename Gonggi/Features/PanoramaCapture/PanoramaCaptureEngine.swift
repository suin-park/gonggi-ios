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
    private(set) var lastAcceptedRelativeYaw: Float?
    private(set) var rejectCounts: [String: Int] = [:]
    private(set) var processedFrameCount: Int = 0
    private(set) var stripEvents: [PanoramaStripEvent] = []
    private(set) var lastUprightFrameWidth: Int = 0
    private(set) var lastUprightFrameHeight: Int = 0

    private var yawTracker = PanoramaYawTracker()
    private var isCapturing = false
    private var captureStartedAt: TimeInterval = 0
    private var lastFrameTime: TimeInterval = 0
    var onUIUpdate: (() -> Void)?

    var acceptedStripCount: Int { composer.placements.count }
    var yawSpanDeg: Float { abs(yawTracker.unwrappedRelativeYawDeg) }
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
            PanoramaFrameOrientation.applyPortraitRotation(to: conn)
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
        yawTracker.reset()
        rejectCounts.removeAll()
        stripEvents.removeAll(keepingCapacity: true)
        processedFrameCount = 0
        lastAcceptedRelativeYaw = nil
        lastUprightFrameWidth = 0
        lastUprightFrameHeight = 0
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
        let span = abs(yawTracker.unwrappedRelativeYawDeg)
        let avgSpeed: Float = duration > 0.2 ? span / Float(duration) : 0
        let startYaw = yawTracker.startYawDeg ?? 0
        let endYaw = yawTracker.lastRawYawDeg ?? startYaw

        let report = PanoramaCaptureReport(
            sessionId: sessionId,
            captureId: captureId,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            captureDurationSec: duration,
            processingTimeSec: processSec,
            acceptedStripCount: composer.placements.count,
            rejectedStripCount: rejectCounts.values.reduce(0, +),
            rejectReasonCounts: rejectCounts,
            uprightFrameWidth: composer.uprightFrameWidth,
            uprightFrameHeight: composer.uprightFrameHeight,
            stripWidth: PanoramaCaptureConfig.stripWidthPx,
            approxHFovDeg: PanoramaCaptureConfig.approxHFovDeg,
            pxPerDegree: composer.pxPerDegree,
            startYawDeg: startYaw,
            endYawDeg: endYaw,
            unwrappedYawSpanDeg: span,
            firstPlacementX: composer.firstPlacementX,
            lastPlacementX: composer.lastPlacementX,
            finalCropWidth: composer.finalCropWidth,
            finalCropHeight: composer.finalCropHeight,
            avgRotationSpeedDegPerSec: avgSpeed,
            outputWidth: Int(finalImg.size.width.rounded()),
            outputHeight: Int(finalImg.size.height.rounded()),
            previewWidth: Int(previewImg.size.width.rounded()),
            previewHeight: Int(previewImg.size.height.rounded()),
            memoryEstimateMB: Double(composer.canvasWidth * composer.canvasHeight * 5)
                / (1024 * 1024),
            meanVerticalAlignPx: composer.meanVerticalAlignPx,
            seamFeatherPx: PanoramaCaptureConfig.seamFeatherPx,
            stripEvents: stripEvents,
            finalPanoramaPath: finalURL.path,
            previewPath: previewURL.path
        )
        let reportURL = try CaptureSessionStore.panoramaScanReportURL(sessionId: sessionId)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(report).write(to: reportURL, options: .atomic)

        let debugDir = try CaptureSessionStore.createPanoramaScanDebugDirectory(sessionId: sessionId)
        let layout: [[String: Any]] = composer.placements.map {
            [
                "index": $0.index,
                "rawYaw": $0.rawYawDeg,
                "relativeYaw": $0.relativeYawDeg,
                "x": $0.xOnCanvas,
                "vOffset": $0.verticalOffsetPx
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: [
            "placements": layout,
            "pxPerDegree": composer.pxPerDegree,
            "uprightFrameWidth": composer.uprightFrameWidth,
            "uprightFrameHeight": composer.uprightFrameHeight,
            "finalCropWidth": composer.finalCropWidth,
            "finalCropHeight": composer.finalCropHeight,
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
        yawTracker.reset()
        phase = .ready
        feedback = .idle
        notify()
    }

    // MARK: - Mock / synthetic

    func ingestMockFrame(
        rgba: [UInt8],
        width: Int,
        height: Int,
        yawDeg: Float,
        uprightFrameWidth: Int? = nil
    ) {
        guard isCapturing else { return }
        let fovW = uprightFrameWidth ?? width
        _ = tryAccept(
            rgba: rgba,
            width: width,
            height: height,
            rawYawDeg: yawDeg,
            pitch: 0,
            roll: 0,
            uprightFrameWidth: fovW,
            uprightFrameHeight: height
        )
        feedback = motion.feedback(
            isCapturing: true,
            lastAcceptedYaw: lastAcceptedRelativeYaw,
            currentYaw: yawTracker.unwrappedRelativeYawDeg,
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

    private func recordEvent(
        rawYaw: Float,
        relativeYaw: Float,
        xCenter: Float,
        accepted: Bool,
        reason: String?
    ) {
        let event = PanoramaStripEvent(
            index: stripEvents.count,
            rawYaw: rawYaw,
            unwrappedRelativeYaw: relativeYaw,
            xCenter: xCenter,
            accepted: accepted,
            rejectReason: reason
        )
        if stripEvents.count < 5_000 {
            stripEvents.append(event)
        }
    }

    @discardableResult
    private func tryAccept(
        rgba: [UInt8],
        width: Int,
        height: Int,
        rawYawDeg: Float,
        pitch: Float,
        roll: Float,
        uprightFrameWidth: Int,
        uprightFrameHeight: Int
    ) -> Bool {
        processedFrameCount += 1
        lastUprightFrameWidth = uprightFrameWidth
        lastUprightFrameHeight = uprightFrameHeight

        let relativeYaw = yawTracker.update(rawYawDeg: rawYawDeg)

        if abs(pitch) > PanoramaCaptureConfig.maxPitchDeg
            || abs(roll) > PanoramaCaptureConfig.maxRollDeg {
            reject("level")
            recordEvent(rawYaw: rawYawDeg, relativeYaw: relativeYaw, xCenter: 0, accepted: false, reason: "level")
            return false
        }

        // Spacing-based acceptance: take a strip every ~targetYawStepDeg.
        // Do NOT hard-reject large Δyaw (fast turns) — that caused ~4 strips on device.
        if let last = lastAcceptedRelativeYaw {
            let dy = abs(relativeYaw - last)
            if dy < PanoramaCaptureConfig.targetYawStepDeg {
                reject("yaw_spacing")
                recordEvent(
                    rawYaw: rawYawDeg, relativeYaw: relativeYaw, xCenter: 0,
                    accepted: false, reason: "yaw_spacing"
                )
                return false
            }
            if relativeYaw >= last { direction = .right } else { direction = .left }
        }

        let sharp = PanoramaStripComposer.sharpnessScore(rgba: rgba, width: width, height: height)
        if sharp < 1.0 {
            reject("blur")
            recordEvent(
                rawYaw: rawYawDeg, relativeYaw: relativeYaw, xCenter: 0,
                accepted: false, reason: "blur"
            )
            return false
        }

        let ok = composer.acceptStrip(
            rgba: rgba,
            width: width,
            height: height,
            uprightFrameWidth: uprightFrameWidth,
            rawYawDeg: rawYawDeg,
            relativeYawDeg: relativeYaw
        )
        if ok, let placed = composer.placements.last {
            lastAcceptedRelativeYaw = relativeYaw
            recordEvent(
                rawYaw: rawYawDeg,
                relativeYaw: relativeYaw,
                xCenter: placed.xOnCanvas,
                accepted: true,
                reason: nil
            )
        } else {
            reject("compose")
            recordEvent(
                rawYaw: rawYawDeg, relativeYaw: relativeYaw, xCenter: 0,
                accepted: false, reason: "compose"
            )
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
        if now - lastFrameTime < 0.033 { return } // ~30 fps cap
        lastFrameTime = now

        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let m = motion.latest
        feedback = motion.feedback(
            isCapturing: true,
            lastAcceptedYaw: lastAcceptedRelativeYaw,
            currentYaw: yawTracker.unwrappedRelativeYawDeg,
            yawSpanDeg: yawSpanDeg
        )

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        guard let extracted = PanoramaFrameOrientation.extractUprightCenterStripBGRA(
            pixelBuffer: pb,
            stripWidth: PanoramaCaptureConfig.stripWidthPx
        ) else { return }

        // Critical: FOV width is upright frame width, never strip width.
        let uprightW = extracted.uprightFrameWidth
        let uprightH = extracted.stripHeight
        guard uprightW > PanoramaCaptureConfig.stripWidthPx * 2 else { return }

        _ = tryAccept(
            rgba: extracted.rgba,
            width: extracted.stripWidth,
            height: extracted.stripHeight,
            rawYawDeg: m.yawDeg,
            pitch: m.pitchDeg,
            roll: m.rollDeg,
            uprightFrameWidth: uprightW,
            uprightFrameHeight: uprightH
        )
        notify()
    }
}
