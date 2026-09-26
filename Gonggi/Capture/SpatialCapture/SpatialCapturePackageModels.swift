import Foundation
import UIKit

/// Capture-package models (provider-agnostic). Coordinate convention is documented in
/// `SpatialCaptureCoordinateConvention` and written beside the package.
struct SpatialCapturePackageMetadata: Codable, Equatable, Sendable {
    var captureId: String
    var sessionId: String
    var captureVersion: String
    var pipelineVersion: String
    var createdAt: String
    var deviceModel: String
    var iOSVersion: String
    var hasLiDAR: Bool
    var supportsSceneDepth: Bool
    var supportsSmoothedSceneDepth: Bool
    var supportsSceneReconstruction: Bool
    var imageWidth: Int
    var imageHeight: Int
    var selectedKeyframeCount: Int
    var rejectedDecisionCount: Int
    var captureDurationSec: Double
    var totalTranslationDistanceM: Double
    var jpegCompressionQuality: Double
    var jpegMaxLongEdge: Int?
    var averageJPEGBytes: Int?
    var packageBytesEstimate: Int?
    var videoMovIncluded: Bool
    var videoRelativePath: String?
    /// Additive multi-room fields (optional for Baseline A readers).
    var captureMode: String?
    var packageSchemaVersion: Int?
    var regionCount: Int?
    var candidateSafetyCap: Int?
    /// TF62 additive selection diagnostics (ignored by schema v1 readers).
    var selectionDiagnostics: SpatialCaptureSelectionDiagnostics?
    /// Active capture policy at package write (`capture_pending_angular_rescue_v1` when ON).
    var policyVersion: String? = nil
    var appVersion: String? = nil
    var buildNumber: String? = nil
}

struct SpatialCapturePoseEntry: Codable, Equatable, Sendable {
    var frameId: String
    var arTimestampSeconds: Double
    /// Column-major 4×4 camera-to-world (ARKit `ARCamera.transform`).
    var cameraToWorldColumnMajor: [Float]
    var translationMeters: [Float]
    var rotationQuaternionXYZw: [Float]
    var trackingState: String
    var coverageCell: String?
    var regionId: String?
    var transitionScore: Double?
    var selectionScore: Double?
}

struct SpatialCapturePosesFile: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var coordinateConvention: String
    var unit: String
    var matrixLayout: String
    var frames: [SpatialCapturePoseEntry]
}

struct SpatialCaptureIntrinsicsEntry: Codable, Equatable, Sendable {
    var frameId: String
    var fx: Float
    var fy: Float
    var cx: Float
    var cy: Float
    var width: Int
    var height: Int
    /// Pixel space matches JPEG as written (ARKit sensor / landscape buffer; no UI orientation bake).
    var pixelSpace: String
}

struct SpatialCaptureIntrinsicsFile: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var frames: [SpatialCaptureIntrinsicsEntry]
}

struct SpatialCaptureFrameQuality: Codable, Equatable, Sendable {
    var frameId: String
    var sharpnessScore: Double?
    var sharpnessState: String?
    var motionSpeed: Double?
    var angularVelocity: Double?
    var parallaxGrade: String?
    var translationBaselineM: Float?
    var overlapScore: Double?
    var overlapState: String?
    var trackingState: String
    var lowTextureScore: Double?
    var acceptReason: String
    var selectionScore: Double?
    var transitionScore: Double?
    var coverageCell: String?
    var regionId: String?
}

struct SpatialCaptureSessionQuality: Codable, Equatable, Sendable {
    var acceptedFrames: Int
    var rejectedDecisions: Int
    var averageSharpness: Double?
    var trackingFailureCount: Int
    var totalTranslationM: Double
    var observedCoverage: Double
    var qualityCoverage: Double
    var viewAngleDiversity: Double
    var captureDurationSec: Double
    var translationBaselineGrade: String
    /// Reconstruction + sector/ring metrics (P1 gate inputs).
    var reconstructionMetrics: CaptureReconstructionMetricsSnapshot?
    /// Explicit completion gate snapshot for device validation (section 9).
    var reconstructionCompletion: CaptureReconstructionCompletionRecord?
    var captureMode: String?
    var localCoverage: Double?
    var globalCoverage: Double?
    var regionCount: Int?
    var transitionSegmentHint: Double?
}

struct SpatialCaptureQualityFile: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var session: SpatialCaptureSessionQuality
    var frames: [SpatialCaptureFrameQuality]
    /// Guide v2 stage 1: what surfaces were seen, how close and from how many directions (nil on older packages).
    var surfaceCoverage: SpatialCaptureSurfaceCoverage? = nil
}

/// Surface ("what was seen") coverage summary. World coordinates = ARKit world, same as poses.json.
struct SpatialCaptureSurfaceCoverage: Codable, Equatable, Sendable {
    struct Thresholds: Codable, Equatable, Sendable {
        var minSharpViews: Int
        var minNearViews: Int
        var minAzimuthBuckets: Int
        var nearDistanceM: Double
        var maxViewDistanceM: Double
        var maxIncidenceDeg: Double
        var azimuthBucketDeg: Double
    }

    struct Deficit: Codable, Equatable, Sendable {
        var kind: String
        var state: String
        var center: [Double]
        var normal: [Double]?
        var areaM2: Double
        var views: Int
        var nearViews: Int
        var minDistanceM: Double?
        var azimuthBuckets: Int
    }

    var schemaVersion: Int
    var calibrationId: String
    var thresholds: Thresholds
    var planeCount: Int
    var planeTileCount: Int
    var featureVoxelCount: Int
    var keyframeCount: Int
    var sharpKeyframeCount: Int
    /// unseen / farOnly / oneSide / fewViews / enough
    var areaM2ByState: [String: Double]
    var countByState: [String: Int]
    var enoughAreaRatio: Double
    var pathCentroid: [Double]
    /// Not-enough area per 45° world-azimuth sector around the path centroid (0 = +z, clockwise to +x).
    var directionDeficitM2: [Double]
    /// Largest not-enough surfaces (up to 40).
    var deficits: [Deficit]
}

struct SpatialCaptureKeyframeDecision: Codable, Equatable, Sendable {
    var arTimestampSeconds: Double
    var accepted: Bool
    var reason: String
    var frameId: String?
}

/// Documented once for COLMAP / VGGT / gsplat consumers.
enum SpatialCaptureCoordinateConvention {
    static let documentId = "arkit-camera-to-world-v1"

    static var jsonObject: [String: Any] {
        [
            "id": documentId,
            "source": "ARKit ARCamera.transform",
            "world": "ARKit world coordinates with worldAlignment = .gravity (Y up ≈ gravity)",
            "matrix": "4x4 camera-to-world, column-major float16",
            "handedness": "right-handed",
            "translationUnit": "meters",
            "cameraForward": "ARKit camera looks along -Z in camera space",
            "cameraUp": "ARKit camera +Y in camera space",
            "rotationQuaternion": "simd_quatf (x, y, z, w) from camera-to-world",
            "intrinsics": "ARKit camera.intrinsics in sensor pixel space matching frames/*.jpg (no portrait bake)",
            "timestamp": "ARFrame.timestamp seconds (canonical sync key with frameId)",
        ]
    }

    static func writeJSON(to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
    }
}

struct SpatialCapturePackagePaths: Equatable, Sendable {
    var root: URL
    var metadataURL: URL
    var posesURL: URL
    var intrinsicsURL: URL
    var qualityURL: URL
    var framesDirectory: URL
    var optionalDepthDirectory: URL
    var debugDirectory: URL
    var conventionURL: URL
}
