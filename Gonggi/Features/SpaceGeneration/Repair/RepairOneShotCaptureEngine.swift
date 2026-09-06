import AVFoundation
import Foundation
import UIKit

/// Single-shot repair capture: align to target direction, freeze motionAtPhotoRequest, auto-shoot.
final class RepairOneShotCaptureEngine: NSObject {
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "com.whik.gonggi.repair.capture", qos: .userInitiated)
    private let motion = PanoramaMotionGuide()
    private var yawTracker = PanoramaYawTracker()

    private(set) var lastMotion = DirectionMotionReading(
        timestamp: 0, relativeYawDeg: 0, yaw0to360: 0,
        pitchDeg: 0, rollDeg: 0, rotationRate: 0, elevationDeg: 0
    )
    private(set) var guideText = "선택한 부분을 다시 촬영해주세요."
    private(set) var isAligned = false
    private(set) var didCapture = false
    private(set) var capturedImage: UIImage?
    private(set) var capturedYawDeg: Float = 0
    private(set) var capturedElevationDeg: Float = 0

    /// Equirect target (right-positive) — converted to iOS yaw for alignment.
    var targetEquirectYawDeg: Float = 0
    var targetPitchDeg: Float = 0
    var yawToleranceDeg: Float = 12
    var pitchToleranceDeg: Float = 12

    private var useMock = false
    private var photoInFlight = false
    private var motionAtPhotoRequest: DirectionMotionReading?
    private var alignedSince: TimeInterval?
    private let settleSeconds: TimeInterval = 0.35
    private var sessionActive = false

    var onUIUpdate: (() -> Void)?
    var onCaptured: ((UIImage, Float, Float) -> Void)?

    func prepareCamera(mockMode: Bool) throws {
        useMock = mockMode
        if mockMode { return }
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
        }

        guard session.canAddOutput(photoOutput) else { throw DirectionCaptureError.cameraUnavailable }
        session.addOutput(photoOutput)
        if let pconn = photoOutput.connection(with: .video) {
            PanoramaFrameOrientation.applyPortraitRotation(to: pconn)
        }
        session.commitConfiguration()
    }

    func start() {
        yawTracker.reset()
        motion.resetReference()
        didCapture = false
        capturedImage = nil
        alignedSince = nil
        sessionActive = true
        if useMock {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.finishMockCapture()
            }
            return
        }
        guard !session.isRunning else { return }
        queue.async { [weak self] in self?.session.startRunning() }
        motion.start()
    }

    func stop() {
        sessionActive = false
        if !useMock {
            queue.async { [weak self] in self?.session.stopRunning() }
        }
        motion.stop()
    }

    private func finishMockCapture() {
        guard !didCapture else { return }
        let img = UIImage(systemName: "photo") ?? UIImage()
        capturedImage = img
        capturedYawDeg = VRSphereEquirectBridge.iosCaptureYaw(fromEquirectYawDeg: targetEquirectYawDeg)
        capturedElevationDeg = targetPitchDeg
        didCapture = true
        onCaptured?(img, capturedYawDeg, capturedElevationDeg)
        onUIUpdate?()
    }

    private func processMotionTick() {
        guard sessionActive, !didCapture else { return }
        let m = motion.latest
        let unwrapped = yawTracker.update(rawYawDeg: m.yawDeg)
        lastMotion = DirectionMotionReading(
            timestamp: m.timestamp,
            relativeYawDeg: unwrapped,
            yaw0to360: DirectionCaptureGuide.normalizeYaw0to360(unwrapped),
            pitchDeg: m.pitchDeg,
            rollDeg: m.rollDeg,
            rotationRate: m.rotationRate,
            elevationDeg: m.elevationDeg
        )
        evaluateAlignment(now: CACurrentMediaTime())
    }

    private func evaluateAlignment(now: TimeInterval) {
        guard !didCapture, !photoInFlight else { return }
        let iosTargetYaw = VRSphereEquirectBridge.iosCaptureYaw(fromEquirectYawDeg: targetEquirectYawDeg)
        let dyaw = abs(lastMotion.relativeYawDeg - iosTargetYaw)
        let dpitch = abs(lastMotion.elevationDeg - targetPitchDeg)
        let extreme = DirectionCaptureGuide.isExtremePose(pitchDeg: lastMotion.pitchDeg, rollDeg: lastMotion.rollDeg)
            || DirectionCaptureGuide.isExtremeRotation(lastMotion.rotationRate)

        let aligned = dyaw <= yawToleranceDeg && dpitch <= pitchToleranceDeg && !extreme
        isAligned = aligned
        if aligned {
            if alignedSince == nil { alignedSince = now }
            guideText = "좋아요. 잠시만요…"
            if let since = alignedSince, now - since >= settleSeconds {
                requestPhoto()
            }
        } else {
            alignedSince = nil
            guideText = "처음 기록했던 위치에서 화면의 원을 맞춰주세요."
        }
        DispatchQueue.main.async { [weak self] in self?.onUIUpdate?() }
    }

    private func requestPhoto() {
        guard !photoInFlight, !didCapture else { return }
        photoInFlight = true
        motionAtPhotoRequest = lastMotion
        if useMock {
            finishMockCapture()
            return
        }
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

extension RepairOneShotCaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        processMotionTick()
    }
}

extension RepairOneShotCaptureEngine: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        defer { photoInFlight = false }
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data)
        else { return }

        let m = motionAtPhotoRequest ?? lastMotion
        let yaw = m.relativeYawDeg
        let elev = m.elevationDeg
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didCapture else { return }
            self.capturedImage = image
            self.capturedYawDeg = yaw
            self.capturedElevationDeg = elev
            self.didCapture = true
            self.guideText = "촬영 완료"
            self.onCaptured?(image, yaw, elev)
            self.onUIUpdate?()
        }
    }
}
