import AVFoundation
import CoreVideo
import Foundation
import UIKit

/// AVFoundation capture + yaw-prior + visual-tracking strip placement.
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
    private(set) var trackingPairDebug: [PanoramaTrackingPairDebug] = []
    private(set) var lastUprightFrameWidth: Int = 0
    private(set) var lastUprightFrameHeight: Int = 0

    // Visual placement state
    private var previousTracking: PanoramaTrackingSample?
    private var visualAccumX: Float = 0
    private var cumulativeY: Float = 0
    private var lockedDirection: PanoramaScanDirection?
    private var visualUsedCount = 0
    private var visualFallbackCount = 0
    private var visualDxSum: Float = 0
    private var visualDxAbsCorrSum: Float = 0
    private var visualDySum: Float = 0
    private var confidenceSamples: [Float] = []
    private var maxAbsCumulativeY: Float = 0
    private var pendingDebugImages: [(name: String, gray: [Float], w: Int, h: Int)] = []

    private var yawTracker = PanoramaYawTracker()
    private var isCapturing = false
    private var captureStartedAt: TimeInterval = 0
    private var lastFrameTime: TimeInterval = 0
    private var sessionIdForDebug: String?
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
        queue.async { [weak self] in self?.session.startRunning() }
        motion.start()
    }

    func stopSession() {
        queue.async { [weak self] in self?.session.stopRunning() }
        motion.stop()
    }

    func beginCapture() {
        composer.reset()
        motion.resetReference()
        yawTracker.reset()
        rejectCounts.removeAll()
        stripEvents.removeAll(keepingCapacity: true)
        trackingPairDebug.removeAll(keepingCapacity: true)
        pendingDebugImages.removeAll()
        previousTracking = nil
        visualAccumX = 0
        cumulativeY = 0
        lockedDirection = nil
        visualUsedCount = 0
        visualFallbackCount = 0
        visualDxSum = 0
        visualDxAbsCorrSum = 0
        visualDySum = 0
        confidenceSamples.removeAll()
        maxAbsCumulativeY = 0
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
        sessionIdForDebug = sessionId
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

        try writeTrackingDebug(sessionId: sessionId)

        let processSec = ProcessInfo.processInfo.systemUptime - t0
        let span = abs(yawTracker.unwrappedRelativeYawDeg)
        let avgSpeed: Float = duration > 0.2 ? span / Float(duration) : 0
        let startYaw = yawTracker.startYawDeg ?? 0
        let endYaw = yawTracker.lastRawYawDeg ?? startYaw
        let pairN = max(1, trackingPairDebug.count)
        let meanConf: Float
        let p10Conf: Float
        if confidenceSamples.isEmpty {
            meanConf = 0
            p10Conf = 0
        } else {
            meanConf = confidenceSamples.reduce(0, +) / Float(confidenceSamples.count)
            let sorted = confidenceSamples.sorted()
            p10Conf = sorted[max(0, sorted.count / 10)]
        }
        let lastYawX = composer.placements.last.map {
            composer.yawPriorX(relativeYawDeg: $0.relativeYawDeg)
        } ?? 0
        let lastCorrX = composer.lastPlacementX
        let drift = abs(lastCorrX - lastYawX)

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
            trackingCropWidth: PanoramaCaptureConfig.trackingCropWidthPx,
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
            visualCorrectionUsedCount: visualUsedCount,
            visualFallbackCount: visualFallbackCount,
            avgVisualDx: visualDxSum / Float(pairN),
            avgAbsVisualCorrectionPx: visualDxAbsCorrSum / Float(pairN),
            avgVisualDy: visualDySum / Float(pairN),
            meanTrackingConfidence: meanConf,
            p10TrackingConfidence: p10Conf,
            maxCumulativeVerticalOffset: maxAbsCumulativeY,
            finalVisualVsYawDriftPx: drift,
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
                "predictedX": $0.predictedX,
                "x": $0.xOnCanvas,
                "vOffset": $0.verticalOffsetPx,
                "usedVisual": $0.usedVisualCorrection,
                "confidence": $0.trackingConfidence
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: [
            "placements": layout,
            "pxPerDegree": composer.pxPerDegree,
            "visualCorrectionUsedCount": visualUsedCount,
            "visualFallbackCount": visualFallbackCount
        ], options: [.prettyPrinted]) {
            try? data.write(to: debugDir.appendingPathComponent("strip_layout.json"))
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
        previousTracking = nil
        phase = .ready
        feedback = .idle
        notify()
    }

    // MARK: - Mock / synthetic ingest

    func ingestMockFrame(
        rgba: [UInt8],
        width: Int,
        height: Int,
        yawDeg: Float,
        uprightFrameWidth: Int? = nil,
        trackingGray: [Float]? = nil,
        trackingWidth: Int? = nil
    ) {
        guard isCapturing else { return }
        let fovW = uprightFrameWidth ?? width
        let trackW = trackingWidth ?? min(PanoramaCaptureConfig.trackingCropWidthPx, fovW)
        let gray: [Float]
        if let trackingGray, let tw = trackingWidth, trackingGray.count == tw * height {
            gray = trackingGray
        } else {
            // Build tracking gray from strip/full rgba center.
            let tw = trackW
            let tx0 = max(0, (width - tw) / 2)
            var g = [Float](repeating: 0, count: tw * height)
            for y in 0..<height {
                for x in 0..<tw {
                    let srcX = min(width - 1, tx0 + x)
                    let o = (y * width + srcX) * 4
                    g[y * tw + x] = 0.299 * Float(rgba[o]) + 0.587 * Float(rgba[o + 1])
                        + 0.114 * Float(rgba[o + 2])
                }
            }
            gray = g
        }
        _ = tryAcceptSample(
            stripRGBA: rgba,
            stripWidth: width,
            stripHeight: height,
            trackingGray: gray,
            trackingWidth: trackW,
            trackingHeight: height,
            uprightFrameWidth: fovW,
            rawYawDeg: yawDeg,
            pitch: 0,
            roll: 0
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
        DispatchQueue.main.async { [weak self] in self?.onUIUpdate?() }
    }

    private func reject(_ code: String) {
        rejectCounts[code, default: 0] += 1
    }

    private func recordEvent(
        rawYaw: Float, relativeYaw: Float, xCenter: Float, accepted: Bool, reason: String?
    ) {
        let event = PanoramaStripEvent(
            index: stripEvents.count,
            rawYaw: rawYaw,
            unwrappedRelativeYaw: relativeYaw,
            xCenter: xCenter,
            accepted: accepted,
            rejectReason: reason
        )
        if stripEvents.count < 5_000 { stripEvents.append(event) }
    }

    @discardableResult
    private func tryAcceptSample(
        stripRGBA: [UInt8],
        stripWidth: Int,
        stripHeight: Int,
        trackingGray: [Float],
        trackingWidth: Int,
        trackingHeight: Int,
        uprightFrameWidth: Int,
        rawYawDeg: Float,
        pitch: Float,
        roll: Float
    ) -> Bool {
        processedFrameCount += 1
        lastUprightFrameWidth = uprightFrameWidth
        lastUprightFrameHeight = stripHeight

        let relativeYaw = yawTracker.update(rawYawDeg: rawYawDeg)

        if abs(pitch) > PanoramaCaptureConfig.maxPitchDeg
            || abs(roll) > PanoramaCaptureConfig.maxRollDeg {
            reject("level")
            recordEvent(rawYaw: rawYawDeg, relativeYaw: relativeYaw, xCenter: 0, accepted: false, reason: "level")
            return false
        }

        // Direction lock: reject clear reverse after direction established.
        if let last = lastAcceptedRelativeYaw, let locked = lockedDirection {
            let reverse = locked == .right
                ? (relativeYaw < last - PanoramaCaptureConfig.reverseYawRejectDeg)
                : (relativeYaw > last + PanoramaCaptureConfig.reverseYawRejectDeg)
            if reverse {
                reject("reverse")
                recordEvent(rawYaw: rawYawDeg, relativeYaw: relativeYaw, xCenter: 0, accepted: false, reason: "reverse")
                return false
            }
        }

        if let last = lastAcceptedRelativeYaw {
            let dy = abs(relativeYaw - last)
            if dy < PanoramaCaptureConfig.targetYawStepDeg {
                reject("yaw_spacing")
                recordEvent(rawYaw: rawYawDeg, relativeYaw: relativeYaw, xCenter: 0, accepted: false, reason: "yaw_spacing")
                return false
            }
            if relativeYaw >= last { direction = .right } else { direction = .left }
            if lockedDirection == nil, abs(relativeYaw) > 4 {
                lockedDirection = direction
            }
        }

        let sharp = PanoramaStripComposer.sharpnessScore(
            rgba: stripRGBA, width: stripWidth, height: stripHeight
        )
        if sharp < 1.0 {
            reject("blur")
            recordEvent(rawYaw: rawYawDeg, relativeYaw: relativeYaw, xCenter: 0, accepted: false, reason: "blur")
            return false
        }

        // Ensure composer geometry so yaw prior X is meaningful.
        ensureComposerReady(uprightW: uprightFrameWidth, height: stripHeight)

        let yawPriorX = composer.yawPriorX(relativeYawDeg: relativeYaw)
        var correctedX = yawPriorX
        var correctedY: Float = cumulativeY
        var usedVisual = false
        var confidence: Float = 0
        var match = PanoramaVisualMatch(
            visualDx: 0, visualDy: 0, nccBest: 0, nccSecond: 0, confidence: 0,
            textureOK: false, usedVisual: false, fallbackReason: "first_frame"
        )

        if let prev = previousTracking {
            let expectedDx = (relativeYaw - prev.relativeYawDeg) * composer.pxPerDegree
            match = PanoramaVisualTracker.match(
                prev: prev.trackingGray, prevW: prev.trackingWidth, prevH: prev.trackingHeight,
                curr: trackingGray, currW: trackingWidth, currH: trackingHeight,
                expectedDx: expectedDx
            )
            confidence = match.confidence
            confidenceSamples.append(confidence)

            let stepDy = max(
                -PanoramaCaptureConfig.maxStepVerticalPx,
                min(PanoramaCaptureConfig.maxStepVerticalPx, match.usedVisual ? match.visualDy : 0)
            )
            if match.usedVisual {
                visualAccumX = prev.correctedX + match.visualDx
                let blended = PanoramaVisualTracker.blendPlacement(
                    visualAccumX: visualAccumX,
                    yawPriorX: yawPriorX,
                    confidence: confidence
                )
                correctedX = blended.x
                usedVisual = blended.visualWeight > 0.05
                if usedVisual { visualUsedCount += 1 } else { visualFallbackCount += 1 }
                cumulativeY += stepDy
                cumulativeY = max(
                    -PanoramaCaptureConfig.maxCumulativeVerticalPx,
                    min(PanoramaCaptureConfig.maxCumulativeVerticalPx, cumulativeY)
                )
                correctedY = cumulativeY
                visualDxSum += match.visualDx
                visualDxAbsCorrSum += abs(correctedX - yawPriorX)
                visualDySum += match.visualDy
            } else {
                visualFallbackCount += 1
                visualAccumX = yawPriorX
                correctedX = yawPriorX
                visualDxSum += expectedDx
                visualDxAbsCorrSum += 0
            }

            let pair = PanoramaTrackingPairDebug(
                prevIndex: prev.index,
                currIndex: composer.placements.count,
                yawDeltaDeg: relativeYaw - prev.relativeYawDeg,
                expectedDx: expectedDx,
                visualDx: match.visualDx,
                visualDy: match.visualDy,
                correctedX: correctedX,
                correctedY: correctedY,
                nccBest: match.nccBest,
                nccSecond: match.nccSecond,
                confidence: confidence,
                usedVisualCorrection: usedVisual,
                fallbackReason: match.fallbackReason
            )
            trackingPairDebug.append(pair)
            // Keep a few debug crops (memory-bounded).
            if trackingPairDebug.count <= 40 {
                pendingDebugImages.append((
                    "pair_\(prev.index)_\(composer.placements.count)_prev",
                    prev.trackingGray, prev.trackingWidth, prev.trackingHeight
                ))
                pendingDebugImages.append((
                    "pair_\(prev.index)_\(composer.placements.count)_curr",
                    trackingGray, trackingWidth, trackingHeight
                ))
            }
        } else {
            // First strip
            visualAccumX = yawPriorX
            correctedX = yawPriorX
        }

        maxAbsCumulativeY = max(maxAbsCumulativeY, abs(cumulativeY))

        // If we accidentally placed a temp strip during ensure — shouldn't happen.
        let ok = composer.acceptStrip(
            rgba: stripRGBA, width: stripWidth, height: stripHeight,
            uprightFrameWidth: uprightFrameWidth,
            rawYawDeg: rawYawDeg, relativeYawDeg: relativeYaw,
            canvasX: correctedX,
            verticalOffsetPx: Int(round(correctedY)),
            predictedX: yawPriorX,
            usedVisualCorrection: usedVisual,
            trackingConfidence: confidence
        )
        if ok, let placed = composer.placements.last {
            lastAcceptedRelativeYaw = relativeYaw
            let sample = PanoramaTrackingSample(
                index: placed.index,
                rawYawDeg: rawYawDeg,
                relativeYawDeg: relativeYaw,
                trackingGray: trackingGray,
                trackingWidth: trackingWidth,
                trackingHeight: trackingHeight,
                stripRGBA: stripRGBA,
                stripWidth: stripWidth,
                stripHeight: stripHeight,
                predictedX: yawPriorX,
                correctedX: correctedX,
                correctedY: correctedY
            )
            previousTracking = sample
            recordEvent(
                rawYaw: rawYawDeg, relativeYaw: relativeYaw,
                xCenter: placed.xOnCanvas, accepted: true, reason: nil
            )
        } else {
            reject("compose")
            recordEvent(rawYaw: rawYawDeg, relativeYaw: relativeYaw, xCenter: 0, accepted: false, reason: "compose")
        }
        return ok
    }

    private func ensureComposerReady(uprightW: Int, height: Int) {
        guard composer.canvasHeight == 0 else { return }
        composer.configureGeometry(uprightFrameWidth: uprightW, uprightFrameHeight: height)
        composer.prepareEmptyCanvas(height: height)
    }

    private func writeTrackingDebug(sessionId: String) throws {
        let trackDir = try CaptureSessionStore.createPanoramaTrackingDebugDirectory(sessionId: sessionId)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        for (i, pair) in trackingPairDebug.enumerated() {
            let name = String(format: "pair_%03d_%03d.json", pair.prevIndex, pair.currIndex)
            if let data = try? enc.encode(pair) {
                try? data.write(to: trackDir.appendingPathComponent(name), options: .atomic)
            }
            _ = i
        }
        // Write a limited set of tracking crop previews.
        for item in pendingDebugImages.prefix(24) {
            if let img = grayToJPEG(item.gray, width: item.w, height: item.h) {
                try? img.write(
                    to: trackDir.appendingPathComponent("\(item.name).jpg"),
                    options: .atomic
                )
            }
        }
    }

    private func grayToJPEG(_ gray: [Float], width: Int, height: Int) -> Data? {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let v = UInt8(clamping: Int(gray[i].rounded()))
            let o = i * 4
            rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 255
        }
        guard let ui = PanoramaStripComposer.image(fromRGBA: rgba, width: width, height: height) else {
            return nil
        }
        // Downscale for debug size.
        let small = PanoramaStripComposer.resize(ui, longEdge: 480)
        return small.jpegData(compressionQuality: 0.7)
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
        if now - lastFrameTime < 0.033 { return }
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

        guard let extracted = PanoramaFrameOrientation.extractUprightStripAndTrackingBGRA(
            pixelBuffer: pb,
            stripWidth: PanoramaCaptureConfig.stripWidthPx,
            trackingWidth: PanoramaCaptureConfig.trackingCropWidthPx
        ) else { return }

        guard extracted.uprightFrameWidth > PanoramaCaptureConfig.stripWidthPx * 2 else { return }

        _ = tryAcceptSample(
            stripRGBA: extracted.stripRGBA,
            stripWidth: extracted.stripWidth,
            stripHeight: extracted.stripHeight,
            trackingGray: extracted.trackingGray,
            trackingWidth: extracted.trackingWidth,
            trackingHeight: extracted.trackingHeight,
            uprightFrameWidth: extracted.uprightFrameWidth,
            rawYawDeg: m.yawDeg,
            pitch: m.pitchDeg,
            roll: m.rollDeg
        )
        notify()
    }
}
