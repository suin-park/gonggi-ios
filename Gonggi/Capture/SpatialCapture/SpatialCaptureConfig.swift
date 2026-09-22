import CoreGraphics
import Dispatch
import Foundation

/// Tunables for 3D spatial capture keyframe JPEG package (Capture Layer).
/// Keep magic numbers here ??do not scatter across call sites.
enum SpatialCaptureConfig {
    /// Capture package schema / pipeline id written into metadata.json.
    /// Baseline A readers still accept v1; multi-room adds additive optional fields.
    static let captureVersion = "spatial-capture-package-v1"
    static let pipelineVersion = "gonggi-spatial-capture-v1"
    /// Additive package schema (poses/quality still decode on schemaVersion 1 readers via optional fields).
    static let packageSchemaVersion: Int = 2

    /// Default capture mode for Spatial Capture sessions.
    static var captureMode: String = "multi_room"

    /// JPEG lossy quality (0??). High enough for reconstruction; tunable for size A/B.
    static var jpegCompressionQuality: CGFloat = 0.92
    /// Long-edge cap; `nil` keeps ARKit full resolution.
    static var jpegMaxLongEdge: Int? = nil

    /// Soft observation band (guidance only ??not a hard product SLA).
    static var targetKeyframeMin: Int = 60
    static var targetKeyframeMax: Int = 150

    /// Absolute device safety cap for on-device candidate JPEGs (multi-room).
    /// Not a UX message; server adaptive select further compresses.
    static var candidateSafetyCap: Int = 520
    /// Back-compat alias used by older call sites ??maps to candidateSafetyCap.
    static var hardMaxKeyframes: Int {
        get { candidateSafetyCap }
        set { candidateSafetyCap = newValue }
    }

    /// Server-side reconstruction budget targets (config ??experiment-tunable).
    static var serverTargetSmallMin: Int = 60
    static var serverTargetSmallMax: Int = 100
    static var serverTargetNormalMin: Int = 80
    static var serverTargetNormalMax: Int = 140
    static var serverTargetMultiMin: Int = 120
    static var serverTargetMultiMax: Int = 220

    /// Keyframe selector (extends KeyframeSelector3DGS defaults).
    static var minTranslationM: Float = 0.12
    static var maxRotationRad: Float = 1.0
    /// Minimum spacing between accepted keyframes (hard gate before scoring).
    static var minIntervalSec: Double = 0.30
    /// Reject when motion is too fast (m/s / rad/s).
    static var maxMotionSpeedMps: Double = 0.55
    static var maxAngularVelocityRadPerSec: Double = 1.4
    /// Reject when low-texture heuristic is above this (0??).
    static var maxLowTextureScore: Double = 0.75

    // MARK: - Adaptive scoring (config-driven)

    static var adaptiveNewCoverageWeight: Double = 1.15
    static var adaptiveSpatialBaselineWeight: Double = 0.85
    static var adaptiveViewNoveltyWeight: Double = 0.65
    static var adaptiveImageQualityWeight: Double = 0.65
    static var adaptiveTransitionWeight: Double = 1.35
    static var adaptiveRedundancyPenalty: Double = 0.95
    static var adaptiveSaturatedAreaPenalty: Double = 0.80
    static var adaptiveTimeRedundancyPenalty: Double = 0.55
    static var adaptiveSpatialBaselineRefM: Float = 0.45
    static var adaptiveYawNoveltyRefDeg: Double = 25
    static var adaptivePitchNoveltyRefDeg: Double = 18
    static var adaptiveRedundantCellVisitThreshold: Int = 6
    static var adaptiveRedundantNewCoverageMax: Double = 0.12
    static var adaptiveLocalSaturatedCoverage: Double = 0.78
    static var adaptiveMinTranslationWhenSaturatedM: Float = 0.18
    static var adaptiveTransitionPriorityThreshold: Double = 0.45
    static var adaptiveHighNewCoverageThreshold: Double = 0.35
    /// Keep threshold; continuity is added as separate bonus terms (TF62).
    static var adaptiveAcceptThreshold: Double = 1.05
    static var useAdaptiveKeyframeScoring: Bool = true

    // MARK: - Continuity / starvation (TF62) ??quality-pass candidates only

    /// Max gap between accepted frames during normal travel (after minInterval).
    static var normalMaxGapSec: Double = 0.7
    /// Max gap while in doorway/transition chain window.
    static var transitionMaxGapSec: Double = 0.4
    /// Travel since last accept that elevates continuity-distance starvation (meters).
    static var distanceStarvationM: Float = 0.40
    /// Score bonus weights for continuity (do not force a target frame count).
    static var continuityTimeWeight: Double = 0.55
    static var continuityDistanceWeight: Double = 0.50
    static var continuityTransitionChainWeight: Double = 0.40
    /// Multiply redundancy penalties by this while inside transition chain window.
    static var transitionRedundancyScale: Double = 0.35
    /// Half-window (sec) kept as transition chain before/after a doorway peak.
    static var transitionChainHalfWindowSec: Double = 1.25

    // MARK: - Local / region tracking

    static var localCoverageWindowCells: Int = 24
    static var globalCoverageSoftDenom: Int = 48
    /// Distance from **anchor** centroids required to spawn a new region.
    static var regionSplitDistanceM: Float = 2.8
    /// Rejoin existing region only when closer than this (hysteresis < split).
    static var regionRejoinDistanceM: Float = 1.6
    /// Ignore additional splits for this long after a split (anti flap).
    static var regionSplitCooldownSec: Double = 2.5
    static var doorwaySpeedMaxMps: Float = 0.42

    static var packageDirectoryName = "capture"
    static var framesDirectoryName = "frames"
    static var optionalDepthDirectoryName = "optional_depth"
    static var debugDirectoryName = "debug"
    static var metadataFileName = "metadata.json"
    static var posesFileName = "poses.json"
    static var intrinsicsFileName = "intrinsics.json"
    static var qualityFileName = "quality.json"
    static var decisionsFileName = "keyframe_decisions.jsonl"
    static var selectionDiagnosticsFileName = "selection_diagnostics.json"
    static var coordinateConventionFileName = "coordinate_convention.json"
    static var telemetryFileName = "capture_telemetry.json"
    static var sensorSpaceReportFileName = "sensor_space_report.json"
    static var cameraPathXZFileName = "camera_path_xz.svg"
    /// Observe-only feature continuity telemetry (package root + debug). Optional; absent on <=2.0(64).
    static var frameContinuityTelemetryFileName = FrameContinuityTelemetryConfig.fileName
    static var frameContinuityTelemetryDebugJSONLFileName = FrameContinuityTelemetryConfig.debugJSONLFileName

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

    /// First JPEG in the spatial package frames/ directory (for library thumbnail).
    static func firstKeyframeJPEG(packageRoot: URL) -> URL? {
        let frames = packageRoot.appendingPathComponent(framesDirectoryName, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frames.path))?
            .filter { $0.lowercased().hasSuffix(".jpg") || $0.lowercased().hasSuffix(".jpeg") }
            .sorted() ?? []
        guard let first = names.first else { return nil }
        return frames.appendingPathComponent(first)
    }
}
