import ARKit
import AVFoundation
import Combine
import Foundation

/// 실험 › 고화질 공간 촬영 (off by default). When on, 기록하기 3D 공간 기록 also saves a full-resolution still
/// (`ARSession.captureHighResolutionFrame`, 12 MP on iPhone 14 Plus) for every accepted keyframe into
/// `{package}/hires/`, caps the auto-exposure shutter, and only accepts photos taken while the phone is nearly still.
///
/// The upload package is unchanged: `SpatialCapturePackageZipper` lists files explicitly, so `hires/` only travels
/// with 「원본 패키지 내보내기」 (`includeHighRes: true`), never to the production GPU path (512 MiB package cap).
///
/// Why (V1_061, 10-25): photos taken while nearly still (< 0.1 rad/s) were no sharper than ones at 0.3 rad/s, so the
/// 1920×1440 video frames themselves limit detail; dropping blurred photos alone gave only +1 dB.
enum HighResCaptureMode {
    static let enabledDefaultsKey = "gonggi.capture.highResStills.enabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledDefaultsKey) }
    }

    /// Longest shutter auto-exposure may pick. 1/120 s keeps smear at 0.25 rad/s under 3 px (fx ≈ 1437).
    static let maxExposureSec: Double = 1.0 / 120
    /// Stricter keyframe smear gate while on (video-resolution pixels; ≈ 2× that in the 12 MP still).
    static let stillMaxBlurPx: Double = 3.0
    /// "천천히" prompt threshold while on.
    static let angularSpeedPromptRadPerSec: Double = 0.3

    static let directoryName = "hires"
    static let indexFileName = "hires_frames.json"

    /// Video format whose high-resolution capture is the largest still the device offers.
    static func configure(_ config: ARWorldTrackingConfiguration) {
        guard isEnabled else { return }
        if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = format
        }
    }

    /// Caps the shutter while leaving exposure automatic. Call after `ARSession.run`. Returns what was applied.
    @discardableResult
    static func applyExposureCap() -> [String: Any] {
        guard isEnabled else { return ["applied": false, "reason": "disabled"] }
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else {
            return ["applied": false, "reason": "no_configurable_device"]
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            guard device.exposureMode == .continuousAutoExposure || device.exposureMode == .autoExpose else {
                return ["applied": false, "reason": "exposure_mode_\(device.exposureMode.rawValue)"]
            }
            let format = device.activeFormat
            let wanted = CMTime(seconds: maxExposureSec, preferredTimescale: 1_000_000)
            let clamped = CMTimeClampToRange(
                wanted,
                range: CMTimeRange(start: format.minExposureDuration, end: format.maxExposureDuration)
            )
            device.activeMaxExposureDuration = clamped
            return ["applied": true, "maxExposureSec": clamped.seconds, "maxISO": format.maxISO]
        } catch {
            return ["applied": false, "reason": "lock_failed"]
        }
    }
}

/// One saved full-resolution still. Pose and intrinsics are the still's own (scaled to its pixels).
struct HighResStillRecord: Codable, Equatable {
    var frameId: String
    var file: String
    var arTimestampSeconds: Double
    var width: Int
    var height: Int
    var fx: Float
    var fy: Float
    var cx: Float
    var cy: Float
    var cameraToWorldColumnMajor: [Float]
    var trackingState: String
    var exposureDurationSec: Double?
    var byteCount: Int
    var laplacianVarianceHalfRes: Double?
}

struct HighResStillIndex: Codable, Equatable {
    var schema = "gonggi.hires_stills.v1"
    var note = "Full-resolution stills paired with frames/ by frameId. Sensor pixel space (no orientation bake), same pose convention as poses.json."
    var exposureCap: [String: String] = [:]
    var failures: [String: Int] = [:]
    var stills: [HighResStillRecord] = []
}

/// Requests at most one still at a time and rewrites `hires_frames.json` after each one, so a crash or an early
/// finish still leaves a consistent index.
final class HighResStillWriter: ObservableObject {
    @Published private(set) var savedCount = 0

    private let queue = DispatchQueue(label: "gonggi.hires-still-writer", qos: .utility)
    private let lock = NSLock()
    private var inFlight = false
    private var root: URL?
    private var index = HighResStillIndex()

    /// Scales ARKit intrinsics (given for `cameraResolution`) to the pixels actually delivered.
    static func scaledIntrinsics(
        _ k: simd_float3x3, cameraResolution: CGSize, pixelWidth: Int, pixelHeight: Int
    ) -> (fx: Float, fy: Float, cx: Float, cy: Float) {
        let sx = cameraResolution.width > 0 ? Float(pixelWidth) / Float(cameraResolution.width) : 1
        let sy = cameraResolution.height > 0 ? Float(pixelHeight) / Float(cameraResolution.height) : 1
        return (k.columns.0.x * sx, k.columns.1.y * sy, k.columns.2.x * sx, k.columns.2.y * sy)
    }

    func reset(exposureCap: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        root = nil
        inFlight = false
        index = HighResStillIndex(exposureCap: exposureCap.mapValues { "\($0)" })
        DispatchQueue.main.async { self.savedCount = 0 }
    }

    /// Called from the AR delegate queue right after a keyframe is accepted.
    func request(session: ARSession, frameId: String, packageRoot: URL) {
        lock.lock()
        if inFlight {
            index.failures["busy", default: 0] += 1
            lock.unlock()
            return
        }
        inFlight = true
        root = packageRoot
        lock.unlock()

        session.captureHighResolutionFrame { [weak self] frame, error in
            guard let self else { return }
            guard let frame, error == nil else {
                self.finish(record: nil, failure: "capture_error", root: packageRoot)
                return
            }
            self.queue.async { self.encode(frame: frame, frameId: frameId, root: packageRoot) }
        }
    }

    private func encode(frame: ARFrame, frameId: String, root: URL) {
        let dir = root.appendingPathComponent(HighResCaptureMode.directoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let buffer = frame.capturedImage
            let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
            let file = "\(frameId).jpg"
            let written = try SpatialKeyframeJPEGWriter.write(
                pixelBuffer: buffer, to: dir.appendingPathComponent(file), compressionQuality: 0.9, maxLongEdge: nil
            )
            let k = Self.scaledIntrinsics(
                frame.camera.intrinsics, cameraResolution: frame.camera.imageResolution, pixelWidth: w, pixelHeight: h
            )
            let record = HighResStillRecord(
                frameId: frameId,
                file: "\(HighResCaptureMode.directoryName)/\(file)",
                arTimestampSeconds: frame.timestamp,
                width: written.width,
                height: written.height,
                fx: k.fx, fy: k.fy, cx: k.cx, cy: k.cy,
                cameraToWorldColumnMajor: CaptureFrameContract.encodeTransform(frame.camera.transform),
                trackingState: CaptureFrameContract.trackingLabel(frame.camera.trackingState),
                exposureDurationSec: frame.camera.exposureDuration > 0 ? frame.camera.exposureDuration : nil,
                byteCount: written.byteCount,
                laplacianVarianceHalfRes: MotionBlurEstimate.keyframeLaplacianVariance(pixelBuffer: buffer)
            )
            finish(record: record, failure: nil, root: root)
        } catch {
            finish(record: nil, failure: "encode_failed", root: root)
        }
    }

    private func finish(record: HighResStillRecord?, failure: String?, root: URL) {
        lock.lock()
        inFlight = false
        // A newer session (reset) owns the index now; drop late results from the old one.
        guard self.root == root else { lock.unlock(); return }
        if let record { index.stills.append(record) }
        if let failure { index.failures[failure, default: 0] += 1 }
        let snapshot = index
        lock.unlock()

        let dir = root.appendingPathComponent(HighResCaptureMode.directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: dir.appendingPathComponent(HighResCaptureMode.indexFileName), options: [.atomic])
        }
        let count = snapshot.stills.count
        DispatchQueue.main.async { self.savedCount = count }
    }
}
