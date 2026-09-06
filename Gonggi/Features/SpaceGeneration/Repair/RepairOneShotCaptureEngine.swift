import AVFoundation
import Foundation
import UIKit

/// Manual one-shot repair capture — no auto-alignment gate.
/// Freezes `motionAtPhotoRequest` at shutter tap for metadata.
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
    private(set) var didCapture = false
    private(set) var capturedImage: UIImage?
    private(set) var capturedYawDeg: Float = 0
    private(set) var capturedElevationDeg: Float = 0
    private(set) var yawDeltaDeg: Float = 0
    private(set) var pitchDeltaDeg: Float = 0
    /// Soft warning only — never blocks shutter.
    private(set) var softMisalignmentWarning = false

    /// Equirect target from VR long-press (right-positive).
    var targetEquirectYawDeg: Float = 0
    var targetPitchDeg: Float = 0

    private var useMock = false
    private var photoInFlight = false
    private var motionAtPhotoRequest: DirectionMotionReading?
    private var sessionActive = false
    /// Bumps on cancel/reset so in-flight photo callbacks are ignored.
    private var captureGeneration: UInt64 = 0

    var onUIUpdate: (() -> Void)?
    var onCaptured: ((UIImage, Float, Float, Float, Float) -> Void)?

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
        resetCaptureState(keepSession: true)
        sessionActive = true
        if useMock { return }
        guard !session.isRunning else { return }
        queue.async { [weak self] in self?.session.startRunning() }
        motion.start()
    }

    func stop() {
        sessionActive = false
        captureGeneration &+= 1
        photoInFlight = false
        if !useMock {
            queue.async { [weak self] in self?.session.stopRunning() }
        }
        motion.stop()
    }

    /// Cancel: ignore pending photo, clear capture, keep camera usable until dismiss.
    func cancelPendingPhoto() {
        captureGeneration &+= 1
        photoInFlight = false
        resetCaptureState(keepSession: true)
        onUIUpdate?()
    }

    func resetForRetake() {
        captureGeneration &+= 1
        photoInFlight = false
        resetCaptureState(keepSession: true)
        onUIUpdate?()
    }

    private func resetCaptureState(keepSession: Bool) {
        didCapture = false
        capturedImage = nil
        capturedYawDeg = 0
        capturedElevationDeg = 0
        yawDeltaDeg = 0
        pitchDeltaDeg = 0
        softMisalignmentWarning = false
        motionAtPhotoRequest = nil
        if !keepSession { sessionActive = false }
    }

    /// Manual shutter — never gated on yaw/pitch alignment.
    func captureNow() {
        guard sessionActive, !photoInFlight, !didCapture else { return }
        photoInFlight = true
        let gen = captureGeneration
        motionAtPhotoRequest = lastMotion
        refreshDeltas(from: lastMotion)

        if useMock {
            finishMockCapture(generation: gen)
            return
        }
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func finishMockCapture(generation: UInt64) {
        guard generation == captureGeneration else {
            photoInFlight = false
            return
        }
        let img = UIImage(systemName: "photo") ?? UIImage()
        let yaw = lastMotion.relativeYawDeg
        let elev = lastMotion.elevationDeg
        applyCapture(image: img, yaw: yaw, elev: elev, generation: generation)
    }

    private func refreshDeltas(from motion: DirectionMotionReading) {
        let iosTargetYaw = VRSphereEquirectBridge.iosCaptureYaw(fromEquirectYawDeg: targetEquirectYawDeg)
        yawDeltaDeg = motion.relativeYawDeg - iosTargetYaw
        pitchDeltaDeg = motion.elevationDeg - targetPitchDeg
        softMisalignmentWarning = VRSphereEquirectBridge.shouldSoftWarnMisalignment(
            yawDeltaDeg: yawDeltaDeg,
            pitchDeltaDeg: pitchDeltaDeg
        )
    }

    private func applyCapture(image: UIImage, yaw: Float, elev: Float, generation: UInt64) {
        guard generation == captureGeneration else {
            photoInFlight = false
            return
        }
        capturedImage = image
        capturedYawDeg = yaw
        capturedElevationDeg = elev
        didCapture = true
        photoInFlight = false
        let reading = DirectionMotionReading(
            timestamp: lastMotion.timestamp,
            relativeYawDeg: yaw,
            yaw0to360: DirectionCaptureGuide.normalizeYaw0to360(yaw),
            pitchDeg: lastMotion.pitchDeg,
            rollDeg: lastMotion.rollDeg,
            rotationRate: lastMotion.rotationRate,
            elevationDeg: elev
        )
        refreshDeltas(from: reading)
        onCaptured?(image, yaw, elev, yawDeltaDeg, pitchDeltaDeg)
        onUIUpdate?()
    }

    private func processMotionTick() {
        guard sessionActive else { return }
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
        if !didCapture {
            refreshDeltas(from: lastMotion)
            DispatchQueue.main.async { [weak self] in self?.onUIUpdate?() }
        }
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
        let gen = captureGeneration
        defer {
            if gen == captureGeneration { photoInFlight = false }
        }
        guard gen == captureGeneration else { return }
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data)
        else { return }

        let m = motionAtPhotoRequest ?? lastMotion
        DispatchQueue.main.async { [weak self] in
            self?.applyCapture(
                image: image,
                yaw: m.relativeYawDeg,
                elev: m.elevationDeg,
                generation: gen
            )
        }
    }
}
