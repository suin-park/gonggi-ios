import CoreGraphics
import Dispatch
import Foundation

/// Tunables for 3D spatial capture keyframe JPEG package (Capture Layer).
/// Keep magic numbers here — do not scatter across call sites.
enum SpatialCaptureConfig {
    /// Capture package schema / pipeline id written into metadata.json.
    static let captureVersion = "spatial-capture-package-v1"
    static let pipelineVersion = "gonggi-spatial-capture-v1"

    /// JPEG lossy quality (0…1). High enough for reconstruction; tunable for size A/B.
    static var jpegCompressionQuality: CGFloat = 0.92
    /// Long-edge cap; `nil` keeps ARKit full resolution.
    static var jpegMaxLongEdge: Int? = nil

    /// Soft observation band for 30–60s walks (not a hard product SLA).
    static var targetKeyframeMin: Int = 60
    static var targetKeyframeMax: Int = 150
    static var hardMaxKeyframes: Int = 200

    /// Keyframe selector (extends KeyframeSelector3DGS defaults).
    static var minTranslationM: Float = 0.12
    static var maxRotationRad: Float = 1.0
    static var minIntervalSec: Double = 0.30
    /// Reject when motion is too fast (m/s / rad/s).
    static var maxMotionSpeedMps: Double = 0.55
    static var maxAngularVelocityRadPerSec: Double = 1.4
    /// Reject when low-texture heuristic is above this (0…1).
    static var maxLowTextureScore: Double = 0.75

    static var packageDirectoryName = "capture"
    static var framesDirectoryName = "frames"
    static var optionalDepthDirectoryName = "optional_depth"
    static var debugDirectoryName = "debug"
    static var metadataFileName = "metadata.json"
    static var posesFileName = "poses.json"
    static var intrinsicsFileName = "intrinsics.json"
    static var qualityFileName = "quality.json"
    static var decisionsFileName = "keyframe_decisions.jsonl"
    static var coordinateConventionFileName = "coordinate_convention.json"
    static var telemetryFileName = "capture_telemetry.json"
    static var sensorSpaceReportFileName = "sensor_space_report.json"
    static var cameraPathXZFileName = "camera_path_xz.svg"

    /// Max pending JPEG encode/write jobs. When full, new keyframes are rejected (`jpeg_queue_full`).
    static var jpegQueueMaxDepth: Int = 8
    /// QoS for encode/write (never run on ARSessionDelegate).
    static var jpegQueueQoS: DispatchQoS = .userInitiated

    #if DEBUG
    /// Draw `(cx, cy)` crosshair on debug JPEG copies (not reconstruction frames).
    static var debugDrawPrincipalPoint: Bool = true
    #else
    /// TestFlight internal: when Spatial Capture beta is on, write principal-point debug copies.
    static var debugDrawPrincipalPoint: Bool {
        GonggiFeatureFlags.show3DGSCaptureFlows
    }
    #endif
}
