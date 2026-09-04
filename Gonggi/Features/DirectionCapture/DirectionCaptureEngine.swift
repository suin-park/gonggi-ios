import AVFoundation
import CoreVideo
import Foundation
import UIKit

/// Portrait camera + CoreMotion auto-capture for 10 named directions.
/// Does not use panorama strip compositor / stitching / NCC.
final class DirectionCaptureEngine: NSObject {
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
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
        pitchDeg: 0, rollDeg: 0, rotationRate: 0
    )

    private var isCapturing = false
    private(set) var sessionId: String = ""
    private var outputDirectory: URL?
    private var dwellDirection: DirectionName?
    private var dwellStartedAt: TimeInterval?
    private var latestPixelBuffer: CVPixelBuffer?
    private var useMock = false
    private var mockTick: Int = 0

    var onUIUpdate: (() -> Void)?
    var onCaptured: ((DirectionName) -> Void)?
    var onCompleted: ((DirectionCaptureResult) -> Void)?

    var capturedCount: Int { captured.count }
    var completedDirections: [DirectionName] {
        DirectionName.captureOrder.filter { captured[$0] != nil }
    }

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

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(videoOutput) else { throw DirectionCaptureError.cameraUnavailable }
        session.addOutput(videoOutput)
        if let conn = videoOutput.connection(with: .video) {
            PanoramaFrameOrientation.applyPortraitRotation(to: conn)
            if conn.isVideoMirroringSupported {
                conn.isVideoMirrored = false
            }
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
    }

    /// Single user action: lock front = 0°, begin horizontal auto-capture.
    func beginCapture() {
        captured.removeAll()
        images.removeAll()
        dwellDirection = nil
        dwellStartedAt = nil
        mockTick = 0
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
        phase = .capturingHorizontal
        refreshTarget()
        notify()

        if useMock {
            startMockProgression()
        }
    }

    func cancel() {
        isCapturing = false
        phase = .ready
        guideText = "공간 기록 시작을 눌러주세요"
        notify()
    }

    func retake() {
        beginCapture()
    }

    // MARK: - Frame / motion

    private func processMotionAndMaybeCapture() {
        guard isCapturing else { return }
        let m = motion.latest
        let unwrapped = yawTracker.update(rawYawDeg: m.yawDeg)
        let yaw360 = DirectionCaptureGuide.normalizeYaw0to360(unwrapped)
        lastMotion = DirectionMotionReading(
            timestamp: m.timestamp,
            relativeYawDeg: unwrapped,
            yaw0to360: yaw360,
            pitchDeg: m.pitchDeg,
            rollDeg: m.rollDeg,
            rotationRate: m.rotationRate
        )
        evaluateCapture(reading: lastMotion)
        refreshTarget()
        notify()
    }

    private func evaluateCapture(reading: DirectionMotionReading) {
        let candidate: DirectionName?
        switch phase {
        case .capturingHorizontal:
            candidate = DirectionCaptureGuide.classifyHorizontal(yawDeg: reading.yaw0to360)
        case .capturingUp:
            let v = DirectionCaptureGuide.classifyVertical(pitchDeg: reading.pitchDeg)
            candidate = (v == .up) ? .up : nil
        case .capturingDown:
            let v = DirectionCaptureGuide.classifyVertical(pitchDeg: reading.pitchDeg)
            candidate = (v == .down) ? .down : nil
        default:
            candidate = nil
        }

        guard let direction = candidate else {
            clearDwell()
            return
        }
        // Duplicate prevention
        if captured[direction] != nil {
            clearDwell()
            advancePhaseIfNeeded()
            return
        }
        // Phase gating: don't accept up while still on horizontal, etc.
        if phase == .capturingHorizontal, !direction.isHorizontal {
            clearDwell()
            return
        }
        if phase == .capturingUp, direction != .up {
            clearDwell()
            return
        }
        if phase == .capturingDown, direction != .down {
            clearDwell()
            return
        }

        guard DirectionCaptureGuide.isStable(
            rotationRate: reading.rotationRate,
            pitchDeg: reading.pitchDeg,
            rollDeg: reading.rollDeg,
            for: direction
        ) else {
            clearDwell()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if dwellDirection != direction {
            dwellDirection = direction
            dwellStartedAt = now
            return
        }
        guard let started = dwellStartedAt,
              now - started >= DirectionCaptureConfig.stabilityDwellSec else {
            return
        }

        accept(direction: direction, reading: reading)
    }

    private func clearDwell() {
        dwellDirection = nil
        dwellStartedAt = nil
    }

    private func accept(direction: DirectionName, reading: DirectionMotionReading) {
        clearDwell()
        guard captured[direction] == nil else { return }
        guard let dirURL = outputDirectory else { return }

        let image: UIImage
        if useMock {
            image = Self.makeMockImage(direction: direction)
        } else {
            guard let pb = latestPixelBuffer,
                  let img = Self.uprightJPEGImage(from: pb) else {
                return
            }
            image = img
        }

        let fileURL = dirURL.appendingPathComponent(direction.fileName)
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            phase = .failed("JPEG 저장 실패: \(direction.rawValue)")
            notify()
            return
        }

        let record = DirectionCaptureRecord(
            direction: direction,
            filePath: "direction_capture/\(direction.fileName)",
            yawDeg: reading.yaw0to360,
            pitchDeg: reading.pitchDeg,
            rollDeg: reading.rollDeg,
            timestamp: reading.timestamp
        )
        captured[direction] = record
        images[direction] = image
        progressText = "\(captured.count) / 10"
        onCaptured?(direction)
        advancePhaseIfNeeded()
        refreshTarget()
        if phase == .completed {
            finishAndEmitResult()
        }
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
        default:
            break
        }
    }

    private func refreshTarget() {
        currentTarget = DirectionCaptureGuide.nextTarget(captured: Set(captured.keys), phase: phase)
        guideText = DirectionCaptureGuide.guideMessage(for: currentTarget)
        progressText = "\(captured.count) / 10"
    }

    private func finishAndEmitResult() {
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let ordered = DirectionName.captureOrder.compactMap { captured[$0] }
        let report = DirectionCaptureReport(
            sessionId: sessionId,
            createdAt: createdAt,
            captures: ordered
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
        let result = DirectionCaptureResult(
            sessionId: sessionId,
            report: report,
            images: imgs,
            directoryURL: outputDirectory ?? URL(fileURLWithPath: "/")
        )
        onCompleted?(result)
        notify()
    }

    private func notify() {
        DispatchQueue.main.async { [weak self] in self?.onUIUpdate?() }
    }

    // MARK: - Mock progression (simulator / CI)

    private func startMockProgression() {
        // Drive synthetic attitudes so unit/UI mock completes without device motion.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let sequence: [(DirectionName, Float, Float)] = [
                (.front, 0, 0),
                (.frontRight, 45, 0),
                (.right, 90, 0),
                (.backRight, 135, 0),
                (.back, 180, 0),
                (.backLeft, 225, 0),
                (.left, 270, 0),
                (.frontLeft, 315, 0),
                (.up, 0, 80),
                (.down, 0, -80)
            ]
            for (dir, yaw, pitch) in sequence {
                guard self.isCapturing else { return }
                // Dwell slightly longer than stability window
                let steps = 8
                for s in 0..<steps {
                    let reading = DirectionMotionReading(
                        timestamp: TimeInterval(self.mockTick) * 0.05,
                        relativeYawDeg: yaw,
                        yaw0to360: DirectionCaptureGuide.normalizeYaw0to360(yaw),
                        pitchDeg: pitch,
                        rollDeg: 0,
                        rotationRate: 0.05
                    )
                    self.mockTick += 1
                    self.lastMotion = reading
                    // Force phase-appropriate accept path
                    DispatchQueue.main.sync {
                        self.evaluateCapture(reading: reading)
                        self.refreshTarget()
                        self.notify()
                    }
                    Thread.sleep(forTimeInterval: DirectionCaptureConfig.stabilityDwellSec / Double(steps - 1))
                    _ = dir
                    _ = s
                }
            }
        }
    }

    // MARK: - Image helpers

    static func uprightJPEGImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 8, h > 8 else { return nil }
        let rotate = PanoramaFrameOrientation.needsLandscapeToPortraitRotate(width: w, height: h)
        let uprightW = rotate ? h : w
        let uprightH = rotate ? w : h

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var rgba = [UInt8](repeating: 0, count: uprightW * uprightH * 4)

        for uy in 0..<uprightH {
            for ux in 0..<uprightW {
                let bx: Int
                let by: Int
                if rotate {
                    bx = uy
                    by = h - 1 - ux
                } else {
                    bx = ux
                    by = uy
                }
                let row = base.advanced(by: by * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                let si = bx * 4
                let di = (uy * uprightW + ux) * 4
                rgba[di] = row[si + 2]
                rgba[di + 1] = row[si + 1]
                rgba[di + 2] = row[si]
                rgba[di + 3] = 255
            }
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rgba,
            width: uprightW,
            height: uprightH,
            bitsPerComponent: 8,
            bytesPerRow: uprightW * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cg = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
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
        latestPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        processMotionAndMaybeCapture()
    }
}
