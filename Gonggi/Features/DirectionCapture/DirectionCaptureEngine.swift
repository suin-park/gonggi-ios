import AVFoundation
import Foundation
import UIKit

/// Portrait 10-direction auto capture via angle-radius + AVCapturePhotoOutput.
/// Motion pipeline unchanged: video ticks update yaw/pitch; photos come from PhotoOutput.
final class DirectionCaptureEngine: NSObject {
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "com.whik.gonggi.direction.capture", qos: .userInitiated)
    private let motion = PanoramaMotionGuide()
    private var yawTracker = PanoramaYawTracker()

    private(set) var phase: DirectionCapturePhase = .idle
    private(set) var captured: [DirectionName: DirectionCaptureRecord] = [:]
    private(set) var images: [DirectionName: UIImage] = [:]
    private(set) var currentTarget: DirectionName?
    private(set) var guideText: String = "공간 기록 시작을 눌러주세요"
    private(set) var progressText: String = "0 / 10"
    private(set) var lastMotion = DirectionMotionReading(
        timestamp: 0, relativeYawDeg: 0, yaw0to360: 0,
        pitchDeg: 0, rollDeg: 0, rotationRate: 0, elevationDeg: 0
    )
    private(set) var sessionId: String = ""
    /// Test telemetry: how many times a photo was requested per direction.
    private(set) var photoRequestCounts: [DirectionName: Int] = [:]
    /// Pending photo direction (nil = idle for capture).
    private(set) var pendingDirection: DirectionName?

    private var isCapturing = false
    private var outputDirectory: URL?
    private var useMock = false
    private var horizontalTargetIndex: Int = 0
    private var captureStartedAt: TimeInterval = 0
    private var warnFast = false
    private var motionAtPhotoRequest: DirectionMotionReading?

    /// When false, beginCapture will not spawn demo mock sweep (unit tests).
    var enableMockSweep = true
    /// Tests: if false, mock photo stays pending until `completePendingPhotoForTests`.
    var autoCompletePhotoInMock = true

    var onUIUpdate: (() -> Void)?
    var onCaptured: ((DirectionName) -> Void)?
    var onCompleted: ((DirectionCaptureResult) -> Void)?
    var onPhotoRequested: ((DirectionName) -> Void)?

    var capturedCount: Int { captured.count }
    var isPhotoPending: Bool { pendingDirection != nil }

    // MARK: - Lifecycle

    func prepareCamera(mockMode: Bool) throws {
        useMock = mockMode
        if mockMode {
            phase = .ready
            guideText = "공간 기록 시작을 눌러주세요"
            notify()
            return
        }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw DirectionCaptureError.cameraUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw DirectionCaptureError.cameraUnavailable }
        session.addInput(input)

        // Video: motion tick only (not photo source).
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(videoOutput) else { throw DirectionCaptureError.cameraUnavailable }
        session.addOutput(videoOutput)
        if let conn = videoOutput.connection(with: .video) {
            PanoramaFrameOrientation.applyPortraitRotation(to: conn)
            if conn.isVideoMirroringSupported { conn.isVideoMirrored = false }
        }

        guard session.canAddOutput(photoOutput) else { throw DirectionCaptureError.cameraUnavailable }
        session.addOutput(photoOutput)
        if let pconn = photoOutput.connection(with: .video) {
            PanoramaFrameOrientation.applyPortraitRotation(to: pconn)
            if pconn.isVideoMirroringSupported { pconn.isVideoMirrored = false }
        }
        session.commitConfiguration()
        phase = .ready
        guideText = "공간 기록 시작을 눌러주세요"
        notify()
    }

    func startSession() {
        if useMock { return }
        guard !session.isRunning else { return }
        queue.async { [weak self] in self?.session.startRunning() }
        motion.start()
    }

    func stopSession() {
        if !useMock {
            queue.async { [weak self] in self?.session.stopRunning() }
        }
        motion.stop()
        isCapturing = false
        pendingDirection = nil
    }

    func beginCapture() {
        captured.removeAll()
        images.removeAll()
        photoRequestCounts.removeAll()
        pendingDirection = nil
        motionAtPhotoRequest = nil
        horizontalTargetIndex = 0
        warnFast = false
        yawTracker.reset()
        motion.resetReference()
        sessionId = "dir-\(UUID().uuidString)"
        do {
            outputDirectory = try CaptureSessionStore.createDirectionCaptureDirectory(sessionId: sessionId)
        } catch {
            phase = .failed("저장 폴더를 만들 수 없습니다")
            notify()
            return
        }
        isCapturing = true
        captureStartedAt = ProcessInfo.processInfo.systemUptime
        phase = .capturingHorizontal
        refreshTargetUI()
        notify()

        if useMock, enableMockSweep {
            startMockContinuousSweep()
        }
    }

    func cancel() {
        isCapturing = false
        pendingDirection = nil
        phase = .ready
        guideText = "공간 기록 시작을 눌러주세요"
        notify()
    }

    func retake() {
        beginCapture()
    }

    /// Inject motion sample (tests / mock). May request a photo when inside angle radius.
    func ingestMotionSample(
        unwrappedYaw: Float,
        pitchDeg: Float = 0,
        rollDeg: Float = 0,
        rotationRate: Float = 0.2,
        elevationDeg: Float = 0,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard isCapturing else { return }
        applyMotionAndEvaluate(
            unwrappedYaw: unwrappedYaw,
            pitchDeg: pitchDeg,
            rollDeg: rollDeg,
            rotationRate: rotationRate,
            elevationDeg: elevationDeg,
            timestamp: timestamp
        )
    }

    /// Tests: finish a pending mock photo without auto-complete.
    func completePendingPhotoForTests(success: Bool, image: UIImage? = nil) {
        guard let direction = pendingDirection else { return }
        if success {
            let img = image ?? Self.makeMockImage(direction: direction)
            finishPhotoSuccess(direction: direction, image: img)
        } else {
            pendingDirection = nil
            motionAtPhotoRequest = nil
            notify()
        }
    }

    // MARK: - Motion + evaluate

    private func processMotionTick() {
        guard isCapturing else { return }
        let m = motion.latest
        let unwrapped = yawTracker.update(rawYawDeg: m.yawDeg)
        applyMotionAndEvaluate(
            unwrappedYaw: unwrapped,
            pitchDeg: m.pitchDeg,
            rollDeg: m.rollDeg,
            rotationRate: m.rotationRate,
            elevationDeg: m.elevationDeg,
            timestamp: m.timestamp
        )
    }

    private func applyMotionAndEvaluate(
        unwrappedYaw: Float,
        pitchDeg: Float,
        rollDeg: Float,
        rotationRate: Float,
        elevationDeg: Float,
        timestamp: TimeInterval
    ) {
        lastMotion = DirectionMotionReading(
            timestamp: timestamp,
            relativeYawDeg: unwrappedYaw,
            yaw0to360: DirectionCaptureGuide.normalizeYaw0to360(unwrappedYaw),
            pitchDeg: pitchDeg,
            rollDeg: rollDeg,
            rotationRate: rotationRate,
            elevationDeg: elevationDeg
        )
        warnFast = DirectionCaptureGuide.shouldWarnRotation(rotationRate)

        // Never advance / re-trigger while a photo is in flight.
        if pendingDirection == nil {
            switch phase {
            case .capturingHorizontal:
                evaluateHorizontal(unwrappedYaw: unwrappedYaw, pitchDeg: pitchDeg, rollDeg: rollDeg, rotationRate: rotationRate)
            case .capturingUp, .capturingDown:
                evaluateVertical(elevationDeg: elevationDeg)
            default:
                break
            }
        }
        refreshTargetUI()
        notify()
    }

    private func evaluateHorizontal(
        unwrappedYaw: Float,
        pitchDeg: Float,
        rollDeg: Float,
        rotationRate: Float
    ) {
        guard horizontalTargetIndex < DirectionName.horizontalOrder.count else {
            advancePhaseIfNeeded()
            return
        }
        let target = DirectionName.horizontalOrder[horizontalTargetIndex]
        guard let targetYaw = target.targetYawDeg else { return }
        guard captured[target] == nil else {
            horizontalTargetIndex += 1
            return
        }

        if DirectionCaptureGuide.isExtremeRotation(rotationRate) { return }
        if DirectionCaptureGuide.isExtremePose(pitchDeg: pitchDeg, rollDeg: rollDeg) { return }

        // Front: wait briefly after start, then shoot when in radius.
        if target == .front {
            let elapsed = ProcessInfo.processInfo.systemUptime - captureStartedAt
            guard elapsed >= DirectionCaptureConfig.frontAutoCaptureDelaySec else { return }
        }

        guard DirectionCaptureGuide.withinYawTolerance(
            currentYaw: unwrappedYaw,
            targetYaw: targetYaw
        ) else { return }

        requestPhoto(for: target)
    }

    /// Up/down: elevation angle-radius only (no pitch, no crossing).
    private func evaluateVertical(elevationDeg: Float) {
        switch phase {
        case .capturingUp:
            guard captured[.up] == nil else { return }
            guard DirectionCaptureGuide.withinElevationTolerance(
                elevationDeg: elevationDeg,
                targetElevation: DirectionCaptureConfig.upElevationTargetDeg
            ) else { return }
            requestPhoto(for: .up)
        case .capturingDown:
            guard captured[.down] == nil else { return }
            guard DirectionCaptureGuide.withinElevationTolerance(
                elevationDeg: elevationDeg,
                targetElevation: DirectionCaptureConfig.downElevationTargetDeg
            ) else { return }
            requestPhoto(for: .down)
        default:
            break
        }
    }

    // MARK: - Photo capture

    private func requestPhoto(for direction: DirectionName) {
        guard pendingDirection == nil else { return }
        guard captured[direction] == nil else { return }

        pendingDirection = direction
        motionAtPhotoRequest = lastMotion
        photoRequestCounts[direction, default: 0] += 1
        onPhotoRequested?(direction)
        notify()

        if useMock {
            if autoCompletePhotoInMock {
                let img = Self.makeMockImage(direction: direction)
                finishPhotoSuccess(direction: direction, image: img)
            }
            return
        }

        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        } else {
            settings = AVCapturePhotoSettings()
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func finishPhotoSuccess(direction: DirectionName, image: UIImage) {
        guard pendingDirection == direction else { return }
        guard captured[direction] == nil else {
            pendingDirection = nil
            return
        }
        guard let dirURL = outputDirectory else {
            pendingDirection = nil
            phase = .failed("저장 폴더 없음")
            notify()
            return
        }

        let fileURL = dirURL.appendingPathComponent(direction.fileName)
        let normalized = DirectionCaptureImageNormalizer.normalizeForUpload(image)
        guard let data = normalized.image.jpegData(compressionQuality: 0.92) else {
            pendingDirection = nil
            notify()
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            pendingDirection = nil
            phase = .failed("JPEG 저장 실패: \(direction.rawValue)")
            notify()
            return
        }

        let m = motionAtPhotoRequest ?? lastMotion
        #if DEBUG
        print(
            "[DirectionCapture] save \(direction.rawValue)"
                + " elev=\(String(format: "%.1f", m.elevationDeg))"
                + " photoOrientation=\(normalized.sourceOrientationRaw)"
                + " pixelRotationApplied=\(normalized.pixelRotationApplied)"
                + " final=\(normalized.finalPixelWidth)x\(normalized.finalPixelHeight)"
        )
        #endif
        let record = DirectionCaptureRecord(
            direction: direction,
            filePath: "direction_capture/\(direction.fileName)",
            yawDeg: DirectionCaptureGuide.normalizeYaw0to360(m.relativeYawDeg),
            pitchDeg: m.pitchDeg,
            rollDeg: m.rollDeg,
            timestamp: m.timestamp,
            elevationDeg: m.elevationDeg,
            photoOrientation: normalized.sourceOrientationRaw,
            pixelRotationApplied: normalized.pixelRotationApplied,
            finalPixelWidth: normalized.finalPixelWidth,
            finalPixelHeight: normalized.finalPixelHeight
        )
        captured[direction] = record
        images[direction] = normalized.image
        pendingDirection = nil
        motionAtPhotoRequest = nil
        progressText = "\(captured.count) / 10"
        onCaptured?(direction)

        if direction.isHorizontal {
            if let idx = DirectionName.horizontalOrder.firstIndex(of: direction) {
                horizontalTargetIndex = idx + 1
            }
        }
        advancePhaseIfNeeded()
        refreshTargetUI()
        notify()
    }

    private func advancePhaseIfNeeded() {
        let horizontalDone = DirectionName.horizontalOrder.allSatisfy { captured[$0] != nil }
        switch phase {
        case .capturingHorizontal where horizontalDone:
            phase = .capturingUp
        case .capturingUp where captured[.up] != nil:
            phase = .capturingDown
        case .capturingDown where captured[.down] != nil:
            phase = .completed
            isCapturing = false
            finishAndEmitResult()
        default:
            break
        }
    }

    private func refreshTargetUI() {
        switch phase {
        case .capturingHorizontal:
            if horizontalTargetIndex < DirectionName.horizontalOrder.count {
                currentTarget = DirectionName.horizontalOrder[horizontalTargetIndex]
            } else {
                currentTarget = nil
            }
            guideText = DirectionCaptureGuide.horizontalGuideMessage(
                target: currentTarget,
                warnFast: warnFast
            )
        case .capturingUp:
            currentTarget = captured[.up] == nil ? .up : nil
            guideText = DirectionCaptureGuide.verticalGuideMessage(for: .up)
        case .capturingDown:
            currentTarget = captured[.down] == nil ? .down : nil
            guideText = DirectionCaptureGuide.verticalGuideMessage(for: .down)
        case .completed:
            currentTarget = nil
            guideText = "촬영 완료"
        default:
            break
        }
        progressText = "\(captured.count) / 10"
    }

    private func finishAndEmitResult() {
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let ordered = DirectionName.captureOrder.compactMap { captured[$0] }
        let up = captured[.up]
        let down = captured[.down]
        let report = DirectionCaptureReport(
            sessionId: sessionId,
            createdAt: createdAt,
            captures: ordered,
            upCaptureElevation: up?.elevationDeg,
            downCaptureElevation: down?.elevationDeg,
            upPhotoOrientation: up?.photoOrientation,
            downPhotoOrientation: down?.photoOrientation,
            upPixelRotationApplied: up?.pixelRotationApplied,
            downPixelRotationApplied: down?.pixelRotationApplied,
            upFinalPixelWidth: up?.finalPixelWidth,
            upFinalPixelHeight: up?.finalPixelHeight,
            downFinalPixelWidth: down?.finalPixelWidth,
            downFinalPixelHeight: down?.finalPixelHeight
        )
        if let dirURL = outputDirectory {
            let reportURL = dirURL.appendingPathComponent("capture_report.json")
            if let data = try? JSONEncoder().encode(report) {
                try? data.write(to: reportURL, options: .atomic)
            }
        }
        let imgs = DirectionName.captureOrder.compactMap { d -> (DirectionName, UIImage)? in
            guard let img = images[d] else { return nil }
            return (d, img)
        }
        onCompleted?(
            DirectionCaptureResult(
                sessionId: sessionId,
                report: report,
                images: imgs,
                directoryURL: outputDirectory ?? URL(fileURLWithPath: "/")
            )
        )
        notify()
    }

    private func notify() {
        DispatchQueue.main.async { [weak self] in self?.onUIUpdate?() }
    }

    // MARK: - Mock sweep

    private func startMockContinuousSweep() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            Thread.sleep(forTimeInterval: DirectionCaptureConfig.frontAutoCaptureDelaySec)
            let yaws: [Float] = [0, -10, -20, -40, -45, -50, -80, -90, -100,
                                 -130, -135, -140, -175, -180, -185,
                                 -220, -225, -230, -265, -270, -275,
                                 -310, -315, -320]
            var t: TimeInterval = 0
            for yaw in yaws {
                guard self.isCapturing else { return }
                while self.isPhotoPending { Thread.sleep(forTimeInterval: 0.02) }
                DispatchQueue.main.sync {
                    self.ingestMotionSample(unwrappedYaw: yaw, pitchDeg: -8, timestamp: t)
                }
                t += 0.05
                Thread.sleep(forTimeInterval: 0.04)
            }
            // up zone +80±8 → 72…88; down −80±8 → −88…−72
            for elev: Float in [60, 72, 80, 85] {
                guard self.isCapturing else { return }
                while self.isPhotoPending { Thread.sleep(forTimeInterval: 0.02) }
                DispatchQueue.main.sync {
                    self.ingestMotionSample(unwrappedYaw: -320, elevationDeg: elev, timestamp: t)
                }
                t += 0.05
                Thread.sleep(forTimeInterval: 0.04)
            }
            for elev: Float in [-60, -72, -80, -85] {
                guard self.isCapturing else { return }
                while self.isPhotoPending { Thread.sleep(forTimeInterval: 0.02) }
                DispatchQueue.main.sync {
                    self.ingestMotionSample(unwrappedYaw: -320, elevationDeg: elev, timestamp: t)
                }
                t += 0.05
                Thread.sleep(forTimeInterval: 0.04)
            }
        }
    }

    static func makeMockImage(direction: DirectionName) -> UIImage {
        let size = CGSize(width: 360, height: 640)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor(white: 0.15, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 28, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
            let text = direction.rawValue as NSString
            let tSize = text.size(withAttributes: attrs)
            text.draw(
                at: CGPoint(x: (size.width - tSize.width) / 2, y: (size.height - tSize.height) / 2),
                withAttributes: attrs
            )
        }
    }
}

enum DirectionCaptureError: Error {
    case cameraUnavailable
}

extension DirectionCaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isCapturing, !useMock else { return }
        // Motion tick only — do not convert pixel buffers into saved photos.
        processMotionTick()
    }
}

extension DirectionCaptureEngine: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard let direction = pendingDirection else { return }
        if let error {
            pendingDirection = nil
            motionAtPhotoRequest = nil
            phase = .failed("사진 촬영 실패: \(error.localizedDescription)")
            notify()
            return
        }
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            pendingDirection = nil
            motionAtPhotoRequest = nil
            notify()
            return
        }
        // Keep source orientation; `finishPhotoSuccess` bakes upright pixels (not tag-only).
        finishPhotoSuccess(direction: direction, image: image)
    }
}
