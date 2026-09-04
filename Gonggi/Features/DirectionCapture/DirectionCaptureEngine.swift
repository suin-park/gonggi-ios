import AVFoundation
import CoreVideo
import Foundation
import UIKit

/// Portrait camera + continuous yaw-crossing capture for 10 named directions.
/// No panorama strip compositor / stitching / NCC.
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
    private(set) var sessionId: String = ""

    private var isCapturing = false
    private var outputDirectory: URL?
    private var useMock = false
    private var frameBuffer: [DirectionBufferedFrame] = []
    private var previousUnwrappedYaw: Float?
    private var previousPitch: Float?
    private var horizontalTargetIndex: Int = 0
    private var captureStartedAt: TimeInterval = 0
    private var frontCaptured = false
    private var warnFast = false
    /// When false, beginCapture will not spawn the demo mock yaw sweep (unit tests).
    var enableMockSweep = true

    var onUIUpdate: (() -> Void)?
    var onCaptured: ((DirectionName) -> Void)?
    var onCompleted: ((DirectionCaptureResult) -> Void)?

    var capturedCount: Int { captured.count }

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

    /// Lock front = 0° and start continuous clockwise capture.
    func beginCapture() {
        captured.removeAll()
        images.removeAll()
        frameBuffer.removeAll(keepingCapacity: true)
        previousUnwrappedYaw = nil
        previousPitch = nil
        horizontalTargetIndex = 0
        frontCaptured = false
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

        if useMock {
            startMockContinuousSweep()
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

    /// Test / synthetic injection: owned image + attitude sample (unwrapped yaw is absolute from start).
    func ingestSyntheticFrame(
        image: UIImage?,
        unwrappedYaw: Float,
        pitchDeg: Float,
        rollDeg: Float = 0,
        rotationRate: Float = 0.2,
        timestamp: TimeInterval,
        sharpness: Float = 100
    ) {
        guard isCapturing else { return }
        let img = image ?? Self.makeMockImage(direction: currentTarget ?? .front)
        let frame = DirectionBufferedFrame(
            image: img,
            unwrappedYaw: unwrappedYaw,
            pitchDeg: pitchDeg,
            rollDeg: rollDeg,
            timestamp: timestamp,
            sharpness: sharpness,
            rotationRate: rotationRate
        )
        pushFrame(frame)
        processSample(
            unwrappedYaw: unwrappedYaw,
            pitchDeg: pitchDeg,
            rollDeg: rollDeg,
            rotationRate: rotationRate,
            timestamp: timestamp
        )
    }

    // MARK: - Live pipeline

    private func processLiveFrame(pixelBuffer: CVPixelBuffer) {
        guard isCapturing else { return }
        let m = motion.latest
        let unwrapped = yawTracker.update(rawYawDeg: m.yawDeg)
        guard let image = Self.uprightJPEGImage(from: pixelBuffer) else { return }
        let sharpness = Self.estimateSharpness(image)
        let frame = DirectionBufferedFrame(
            image: image,
            unwrappedYaw: unwrapped,
            pitchDeg: m.pitchDeg,
            rollDeg: m.rollDeg,
            timestamp: m.timestamp,
            sharpness: sharpness,
            rotationRate: m.rotationRate
        )
        pushFrame(frame)
        processSample(
            unwrappedYaw: unwrapped,
            pitchDeg: m.pitchDeg,
            rollDeg: m.rollDeg,
            rotationRate: m.rotationRate,
            timestamp: m.timestamp
        )
    }

    private func processSample(
        unwrappedYaw: Float,
        pitchDeg: Float,
        rollDeg: Float,
        rotationRate: Float,
        timestamp: TimeInterval
    ) {
        lastMotion = DirectionMotionReading(
            timestamp: timestamp,
            relativeYawDeg: unwrappedYaw,
            yaw0to360: DirectionCaptureGuide.normalizeYaw0to360(unwrappedYaw),
            pitchDeg: pitchDeg,
            rollDeg: rollDeg,
            rotationRate: rotationRate
        )
        warnFast = DirectionCaptureGuide.shouldWarnRotation(rotationRate)

        switch phase {
        case .capturingHorizontal:
            processHorizontal(unwrappedYaw: unwrappedYaw, pitchDeg: pitchDeg, rollDeg: rollDeg, rotationRate: rotationRate)
        case .capturingUp, .capturingDown:
            processVertical(pitchDeg: pitchDeg, rollDeg: rollDeg, rotationRate: rotationRate)
        default:
            break
        }
        refreshTargetUI()
        notify()
    }

    private func processHorizontal(
        unwrappedYaw: Float,
        pitchDeg: Float,
        rollDeg: Float,
        rotationRate: Float
    ) {
        // Front: auto-grab soon after start — no stop / dwell required.
        if !frontCaptured {
            let elapsed = ProcessInfo.processInfo.systemUptime - captureStartedAt
            if !frameBuffer.isEmpty, elapsed >= DirectionCaptureConfig.frontAutoCaptureDelaySec {
                if !DirectionCaptureGuide.isExtremePose(pitchDeg: pitchDeg, rollDeg: rollDeg) {
                    if let best = DirectionCaptureGuide.bestFrame(in: frameBuffer, targetYaw: 0) {
                        commitCapture(.front, frame: best)
                        frontCaptured = true
                        horizontalTargetIndex = 1
                        previousUnwrappedYaw = unwrappedYaw
                        return
                    }
                }
            }
            previousUnwrappedYaw = unwrappedYaw
            return
        }

        guard horizontalTargetIndex < DirectionName.horizontalOrder.count else {
            advancePhaseIfNeeded()
            return
        }

        if DirectionCaptureGuide.isExtremePose(pitchDeg: pitchDeg, rollDeg: rollDeg) {
            previousUnwrappedYaw = unwrappedYaw
            return
        }
        if DirectionCaptureGuide.isExtremeRotation(rotationRate) {
            previousUnwrappedYaw = unwrappedYaw
            return
        }

        let targetDir = DirectionName.horizontalOrder[horizontalTargetIndex]
        guard let targetYaw = targetDir.targetYawDeg else { return }
        guard let prev = previousUnwrappedYaw else {
            previousUnwrappedYaw = unwrappedYaw
            return
        }

        if DirectionCaptureGuide.crossesTarget(
            previousYaw: prev,
            currentYaw: unwrappedYaw,
            targetYaw: targetYaw
        ) {
            if let best = DirectionCaptureGuide.bestFrame(in: frameBuffer, targetYaw: targetYaw) {
                commitCapture(targetDir, frame: best)
                horizontalTargetIndex += 1
                if horizontalTargetIndex >= DirectionName.horizontalOrder.count {
                    advancePhaseIfNeeded()
                }
            }
        }
        previousUnwrappedYaw = unwrappedYaw
    }

    private func processVertical(pitchDeg: Float, rollDeg: Float, rotationRate: Float) {
        if DirectionCaptureGuide.isExtremeRotation(rotationRate) {
            previousPitch = pitchDeg
            return
        }
        if abs(rollDeg) > DirectionCaptureConfig.extremeRollRejectDeg {
            previousPitch = pitchDeg
            return
        }

        let prev = previousPitch
        previousPitch = pitchDeg

        switch phase {
        case .capturingUp:
            guard captured[.up] == nil else { return }
            let crossed: Bool
            if let prev {
                crossed = prev < DirectionCaptureConfig.upPitchMinDeg
                    && pitchDeg >= DirectionCaptureConfig.upPitchMinDeg
            } else {
                crossed = pitchDeg >= DirectionCaptureConfig.upPitchMinDeg
            }
            if crossed || DirectionCaptureGuide.classifyVertical(pitchDeg: pitchDeg) == .up {
                let best = frameBuffer.max(by: { $0.pitchDeg < $1.pitchDeg })
                    ?? frameBuffer.last
                if let best {
                    commitCapture(.up, frame: best)
                    advancePhaseIfNeeded()
                }
            }
        case .capturingDown:
            guard captured[.down] == nil else { return }
            let crossed: Bool
            if let prev {
                crossed = prev > DirectionCaptureConfig.downPitchMaxDeg
                    && pitchDeg <= DirectionCaptureConfig.downPitchMaxDeg
            } else {
                crossed = pitchDeg <= DirectionCaptureConfig.downPitchMaxDeg
            }
            if crossed || DirectionCaptureGuide.classifyVertical(pitchDeg: pitchDeg) == .down {
                let best = frameBuffer.min(by: { $0.pitchDeg < $1.pitchDeg })
                    ?? frameBuffer.last
                if let best {
                    commitCapture(.down, frame: best)
                    advancePhaseIfNeeded()
                }
            }
        default:
            break
        }
    }

    private func pushFrame(_ frame: DirectionBufferedFrame) {
        frameBuffer.append(frame)
        let cap = DirectionCaptureConfig.frameBufferCapacity
        if frameBuffer.count > cap {
            frameBuffer.removeFirst(frameBuffer.count - cap)
        }
    }

    private func commitCapture(_ direction: DirectionName, frame: DirectionBufferedFrame) {
        guard captured[direction] == nil else { return }
        guard let dirURL = outputDirectory else { return }

        let fileURL = dirURL.appendingPathComponent(direction.fileName)
        guard let data = frame.image.jpegData(compressionQuality: 0.9) else { return }
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
            yawDeg: DirectionCaptureGuide.normalizeYaw0to360(frame.unwrappedYaw),
            pitchDeg: frame.pitchDeg,
            rollDeg: frame.rollDeg,
            timestamp: frame.timestamp
        )
        captured[direction] = record
        images[direction] = frame.image
        progressText = "\(captured.count) / 10"
        onCaptured?(direction)
    }

    private func advancePhaseIfNeeded() {
        let horizontalDone = DirectionName.horizontalOrder.allSatisfy { captured[$0] != nil }
        switch phase {
        case .capturingHorizontal where horizontalDone:
            phase = .capturingUp
            previousPitch = lastMotion.pitchDeg
            frameBuffer.removeAll(keepingCapacity: true)
        case .capturingUp where captured[.up] != nil:
            phase = .capturingDown
            previousPitch = lastMotion.pitchDeg
            frameBuffer.removeAll(keepingCapacity: true)
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
            currentTarget = .up
            guideText = DirectionCaptureGuide.verticalGuideMessage(for: .up)
        case .capturingDown:
            currentTarget = .down
            guideText = DirectionCaptureGuide.verticalGuideMessage(for: .down)
        case .completed:
            currentTarget = nil
            guideText = "완료"
        default:
            break
        }
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

    // MARK: - Mock continuous sweep

    private func startMockContinuousSweep() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // Dense yaw steps that do not land exactly on 45° multiples.
            var yaws: [Float] = []
            var y: Float = 0
            while y <= 360 {
                yaws.append(y)
                y += 4.3
            }
            // Ensure crossings: inject near-miss pairs around each target after front.
            for t in stride(from: 45, through: 315, by: 45) {
                yaws.append(Float(t) - 2)
                yaws.append(Float(t) + 2)
            }
            yaws.sort()

            var t: TimeInterval = 0
            // Front auto-capture delay
            for i in 0..<6 {
                guard self.isCapturing else { return }
                let yaw: Float = Float(i) * 0.4
                let img = Self.makeMockImage(direction: .front)
                DispatchQueue.main.sync {
                    // Force front delay clock: first call sets start; sleep outside
                    self.ingestSyntheticFrame(
                        image: img, unwrappedYaw: yaw, pitchDeg: -5,
                        timestamp: t, sharpness: 80 + Float(i)
                    )
                }
                t += 0.04
                Thread.sleep(forTimeInterval: 0.04)
            }
            Thread.sleep(forTimeInterval: max(0, DirectionCaptureConfig.frontAutoCaptureDelaySec - 0.2))

            for yaw in yaws {
                guard self.isCapturing else { return }
                if self.capturedCount >= 8 { break }
                let img = Self.makeMockImage(direction: .frontRight)
                DispatchQueue.main.sync {
                    self.ingestSyntheticFrame(
                        image: img, unwrappedYaw: yaw, pitchDeg: -12,
                        rotationRate: 0.3, timestamp: t, sharpness: 90
                    )
                }
                t += 0.03
                Thread.sleep(forTimeInterval: 0.01)
            }

            // Up / down
            for pitch in stride(from: 0, through: 85, by: 8) {
                guard self.isCapturing else { return }
                DispatchQueue.main.sync {
                    self.ingestSyntheticFrame(
                        image: Self.makeMockImage(direction: .up),
                        unwrappedYaw: 360, pitchDeg: Float(pitch),
                        timestamp: t, sharpness: 95
                    )
                }
                t += 0.03
                Thread.sleep(forTimeInterval: 0.01)
            }
            for pitch in stride(from: 40, through: -85, by: -10) {
                guard self.isCapturing else { return }
                DispatchQueue.main.sync {
                    self.ingestSyntheticFrame(
                        image: Self.makeMockImage(direction: .down),
                        unwrappedYaw: 360, pitchDeg: Float(pitch),
                        timestamp: t, sharpness: 95
                    )
                }
                t += 0.03
                Thread.sleep(forTimeInterval: 0.01)
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

    static func estimateSharpness(_ image: UIImage) -> Float {
        guard let cg = image.cgImage else { return 0 }
        let w = min(64, cg.width)
        let h = min(64, cg.height)
        var gray = [UInt8](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &gray, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum: Float = 0
        var sumSq: Float = 0
        var n: Float = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let lap = Float(gray[i - 1]) + Float(gray[i + 1])
                    + Float(gray[i - w]) + Float(gray[i + w])
                    - 4 * Float(gray[i])
                sum += lap
                sumSq += lap * lap
                n += 1
            }
        }
        guard n > 0 else { return 0 }
        let mean = sum / n
        return max(0, sumSq / n - mean * mean)
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
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        processLiveFrame(pixelBuffer: pb)
    }
}
