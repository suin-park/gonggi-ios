import CoreVideo
import Foundation
import simd

/// Immutable ARFrame extract taken while `capturedImage` is still valid.
/// Pose / intrinsics / timestamp / pixels must all come from the same frame — never re-read ARFrame later.
struct SpatialKeyframeSnapshot {
    var frameId: String
    var arTimestampSeconds: Double
    var ownedPixelBuffer: CVPixelBuffer
    var cameraToWorld: simd_float4x4
    var trackingState: String
    /// Sensor-space intrinsics from `ARCamera.intrinsics` (unscaled).
    var fx: Float
    var fy: Float
    var cx: Float
    var cy: Float
    var sensorImageWidth: Int
    var sensorImageHeight: Int
    var imageResolutionWidth: Int
    var imageResolutionHeight: Int
    var sharpnessScore: Double?
    var sharpnessState: String?
    var motionSpeed: Double?
    var angularVelocity: Double?
    var parallaxGrade: String?
    var translationBaselineM: Float?
    var overlapScore: Double?
    var overlapState: String?
    var lowTextureScore: Double?
    var acceptReason: String
    /// Selector accept kind at reservation time (bridge vs recon). Used for async JPEG failure repair.
    var acceptKindRaw: String? = nil
    var selectionScore: Double?
    var transitionScore: Double?
    var coverageCell: String?
    var regionId: String?
    var jpegURL: URL
    /// DEBUG-only overlay JPEG path (principal point). Nil in Release / when disabled.
    var debugPrincipalPointJPEGURL: URL?
    var optionalDepthRelativePath: String?
}
