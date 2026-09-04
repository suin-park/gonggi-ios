import Foundation
import simd

/// Configuration for Quick 360 Hybrid Space Capture (V4 → full sphere).
enum Quick360Config {
    // Final offline panorama (high-res equirect — never upscale live atlas)
    static let outputWidth = 4096
    static let outputHeight = 2048

    /// Nominal yaw spacing for mid-latitude rings (~25–30°).
    static let keyframeYawIntervalDeg: Float = 30
    /// Horizon ring yaw steps (legacy accessor — prefer `pitchBandSpecs`).
    static let yawStepCount = 12
    /// Full-sphere rings tuned for iPhone 14 Plus portrait FOV (~53° H × ~67° V after remap).
    /// Ring spacing targets ≥30% FOV overlap with neighbors (not just more targets).
    static let pitchBandSpecs: [(pitchDeg: Float, yawSteps: Int)] = [
        (0, 12),   // horizon: step ~30° → ~43% H overlap at 53° HFOV
        (45, 10),  // upper: 45° from horizon → ~33% V overlap at 67° VFOV
        (-45, 10),
        (75, 4),   // zenith: 30° from upper → ~55% V overlap
        (-75, 4)
    ]
    /// Legacy flat list for tests / callers that only need pitch angles.
    static var pitchBandsDeg: [Float] { pitchBandSpecs.map(\.pitchDeg) }
    static let targetAngularToleranceDeg: Float = 14
    static let candidateWindowSec: Double = 0.65
    static let maxCandidatesPerTarget = 6
    static let minCandidatesBeforeSelect = 2
    static let keyframeJPEGQuality: CGFloat = 0.85
    static let keyframeMaxPixelWidth = 1920
    /// Candidate quality gates before accepting a keyframe for final stitch.
    static let keyframeMinSharpness: Float = 0.12
    static let keyframeMinExposure: Float = 0.18
    static let keyframeMaxDynamicRatio: Float = 0.45
    static let keyframeMaxTranslationM: Float = 0.4
    /// Minimum expected FOV overlap fraction vs previous keyframe.
    static let keyframeMinOverlapFraction: Float = 0.18

    // Spherical coverage map (independent of live paint)
    static let coverageMapWidth = 72
    static let coverageMapHeight = 36
    static let coverageStampStride = 2
    /// Half-angle (rad) stamped CAPTURED when a keyframe is selected (~FOV/2).
    static let coverageKeyframeHalfAngleRad: Float = 0.55
    static let coverageBandWeights: (
        horizon: Float, upper: Float, lower: Float, zenith: Float, nadir: Float
    ) = (0.35, 0.22, 0.22, 0.105, 0.105)
    static let coveragePhaseThresholds: (
        horizon: Float, upper: Float, lower: Float, zenith: Float, nadir: Float, enoughOverall: Float
    ) = (70, 55, 55, 40, 35, 62)
    /// Soft finish unlock (forced finish still allowed below this).
    static let coverageFinishUnlockPercent: Float = 35
    static let coverageEnoughOverallPercent: Float = 62

    // Visual refinement (ARKit pose = initial guess only)
    static let refinementMinMatches = 8
    static let refinementMinInlierRatio: Float = 0.4
    static let refinementMaxReprojPx: Float = 3.5
    static let refinementMaxYawDeltaDeg: Float = 8
    static let refinementMaxPitchDeltaDeg: Float = 6
    static let refinementRansacIterations = 48
    static let refinementInlierThresholdPx: Float = 2.5
    static let refinementParallaxDisagreementPx: Float = 4.0
    static let refinementMatchThumbMaxWidth = 320
    static let refinementMaxCorners = 120
    static let writeStitchDebugArtifacts = true

    /// TestFlight / Release validation only: run Legacy (user output) + OpenCV A/B artifacts.
    /// Does **not** change `productionDefault` (.legacy). Set `false` before App Store promote.
    static let testFlightABCompareEnabled = true

    // Live sphere brush proxy (separate from final panorama)
    /// Live equirect atlas (UX preview — not final stitch resolution).
    static let livePreviewWidth = 1024
    static let livePreviewHeight = 512
    /// Nominal continuous paint rate (~5 Hz). May adapt 3–7 Hz from motion/CPU.
    static let liveBrushMinIntervalSec: Double = 0.2
    static let liveBrushFastMotionIntervalSec: Double = 0.14 // ~7 Hz when rotating quickly
    static let liveBrushSlowCPUIntervalSec: Double = 0.28 // ~3.5 Hz if paintMs high
    static let liveBrushFastMotionDegPerSec: Float = 55
    static let liveBrushSlowCPUPaintMs: Double = 40
    /// Brush source thumb max edge (bilinear sample into atlas).
    static let brushThumbMaxWidth = 512
    /// Fade-in for newly painted pixels; settles to full opacity (not persistent translucency).
    static let brushRevealFadeSec: Double = 0.22
    /// FOV edge-only feather band (normalized |nx|/|ny| beyond this gets soft blend).
    static let brushBoundaryFeatherStart: Float = 0.88
    static let unseenNeutralGray: UInt8 = 148
    /// Cool mist bias for unfilled canvas (presentation only).
    static let unseenFogBlueBias: Int = 8
    static let unseenFogGreenBias: Int = 4
    /// Subtle veil on weak confidence (does not desaturate/blur captured content).
    static let weakConfidenceVeil: Float = 0.12
    /// Debug coordinate HUD (DEBUG builds only unless overridden).
    #if DEBUG
    static let showBrushCoordinateDebug = true
    #else
    static let showBrushCoordinateDebug = false
    #endif
    /// Production default: inside-out sphere paint UX.
    /// DEBUG builds may reopen Split Debug at runtime via ViewModel toggle (coordinate regression).
    /// Do not invent ±90° offsets / mirrors on the sphere while debugging.
    static let splitDebugCaptureModeDefault = false
    /// Compatibility alias — prefer ViewModel runtime toggle in DEBUG.
    static var splitDebugCaptureMode: Bool { splitDebugCaptureModeDefault }
    static let sphereWeakConfidence: Float = 0.35
    static let sphereGoodConfidence: Float = 0.65
    /// Legacy brush-only threshold — prefer spherical coverage overall.
    static let sphereCoverageCompletePercent: Int = 55
    static let sphereLookUpPitchDeg: Float = 35
    static let sphereCeilingSparsePercent: Int = 25
    /// Viewer pitch clamp (~±89°) — avoid exact ±90° singularity.
    static let viewerMaxPitchRad: Float = (.pi / 2) - 0.02

    // Local floor placement surface
    static let floorTextureSize = 512
    static let floorMaxRadiusM: Float = 3.0
    static let floorMinExtentM: Float = 0.4
    static let floorPreferredMaxDepthBelowCameraM: Float = 2.5
    static let floorMinIncidenceCos: Float = 0.28 // reject grazing
    static let floorWeakConfidence: Float = 0.3
    static let floorGoodConfidence: Float = 0.6
    static let floorCoverageHintPercent: Int = 18
    static let floorGoodCoveragePercent: Int = 35
    static let floorStabilizeUpdates: Int = 3

    // Translation: allow natural body/arm motion; only soft-warn on walking away
    static let translationSafeM: Float = 0.12
    static let translationWarningM: Float = 0.28
    static let translationExcessiveM: Float = 0.45

    // Quality scoring weights (internal keyframes)
    static let weightOrientation: Float = 0.35
    static let weightTranslation: Float = 0.25
    static let weightSharpness: Float = 0.25
    static let weightExposure: Float = 0.15

    static var targetCount: Int { pitchBandSpecs.reduce(0) { $0 + $1.yawSteps } }
}

enum Quick360CapturePhase: String, Codable, Equatable {
    case alignFront
    case readyToStart
    case capturing
    case complete
}

enum Quick360TargetState: String, Codable, Equatable {
    case pending
    case accumulating
    case selected
}

struct Quick360SphericalTarget: Equatable, Identifiable {
    let id: Int
    let yawDeg: Float
    let pitchDeg: Float
    var state: Quick360TargetState

    var yawRad: Float { yawDeg * .pi / 180 }
    var pitchRad: Float { pitchDeg * .pi / 180 }
}

enum Quick360TranslationLevel: String, Codable, Equatable {
    case safe
    case warning
    case excessive

    /// Soft guidance only — never blocks capture.
    var guidanceMessage: String? {
        switch self {
        case .safe, .warning: return nil
        case .excessive: return "가능하면 같은 자리에서 촬영해 주세요"
        }
    }
}

enum Quick360GuidanceKind: Equatable {
    case faceForward
    case readyToStart
    case lookAround
    case lookUp
    case lookDown
    case lookDownFloor
    case fillGaps
    case floorRecorded
    case spaceReady
    case spaceReadyNoFloor
    case stayInPlace
    case waitForClear
    case success

    // Legacy aliases used by internal target layout helpers
    case alignTarget
    case rotateRight
    case rotateLeft
    case holdStill
    case returnToOrigin

    var primaryText: String {
        switch self {
        case .faceForward, .alignTarget:
            return "정면을 먼저 비춰주세요"
        case .readyToStart:
            return "준비가 되면 촬영을 시작해보세요"
        case .lookAround, .rotateRight, .rotateLeft:
            return "천천히 주변을 한 바퀴 비춰보세요"
        case .lookUp:
            return "이제 위쪽을 천천히 비춰보세요"
        case .lookDown, .lookDownFloor:
            return "바닥 쪽도 천천히 비춰주세요"
        case .fillGaps:
            return "아직 비어 있는 공간이 있어요"
        case .floorRecorded:
            return "바닥도 잘 기록됐어요"
        case .spaceReady, .spaceReadyNoFloor:
            return "공간이 충분히 기록됐어요"
        case .stayInPlace, .returnToOrigin, .holdStill:
            return "가능하면 같은 자리에서 촬영해 주세요"
        case .waitForClear:
            return "잠시 기다렸다 다시 비춰주세요"
        case .success:
            return "이제 마무리해도 괜찮아요"
        }
    }

    /// Optional second line — never duplicates `primaryText`.
    var secondaryText: String? {
        switch self {
        case .faceForward, .alignTarget:
            return "정면을 맞춘 뒤 천천히 주변을 기록해보세요"
        case .readyToStart:
            return nil
        case .lookAround, .rotateRight, .rotateLeft:
            return nil
        case .lookUp:
            return "천장 근처까지 천천히 올려 주세요"
        case .lookDown, .lookDownFloor:
            return "발밑을 너무 가깝지 않게 비춰 주세요"
        case .fillGaps:
            return "안내된 방향을 한 번 더 비춰보세요"
        case .spaceReady, .success:
            return "이제 마무리해도 괜찮아요"
        case .spaceReadyNoFloor:
            return nil
        default:
            return nil
        }
    }
}

struct Quick360FrameCandidate: Equatable {
    let timestamp: Double
    let yawRad: Float
    let pitchRad: Float
    let translationM: Float
    let sharpness: Float
    let exposure: Float
    let dynamicRatio: Float
    let intrinsics: CameraIntrinsics
    let transform: [Float]
    let imageJPEG: Data?
    let fileName: String?

    var cameraTransform: simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(transform[0], transform[1], transform[2], transform[3]),
            SIMD4(transform[4], transform[5], transform[6], transform[7]),
            SIMD4(transform[8], transform[9], transform[10], transform[11]),
            SIMD4(transform[12], transform[13], transform[14], transform[15])
        ))
    }
}

struct Quick360SelectedKeyframe: Codable, Equatable {
    let targetId: Int
    let targetYawDeg: Float
    let targetPitchDeg: Float
    let fileName: String
    let timestamp: Double
    let yawRad: Float
    let pitchRad: Float
    let translationM: Float
    let qualityScore: Float
    let sharpness: Float
    let exposure: Float
    let dynamicRatio: Float
    let intrinsics: CameraIntrinsics
    let transform: [Float]
}

/// ARKit lighting snapshot for future product compositing (not physically accurate).
struct Quick360LightingSample: Codable, Equatable {
    let timestamp: Double
    let ambientIntensity: Float
    let ambientColorTemperature: Float
}

struct Quick360CaptureMetadata: Codable, Equatable {
    let sessionId: String
    let captureId: String
    let startedAt: String
    let endedAt: String
    let originTransform: [Float]
    let outputWidth: Int
    let outputHeight: Int
    let targetCount: Int
    let selectedKeyframeCount: Int
    let cameraNotes: [String]
    let keyframes: [Quick360SelectedKeyframe]
    let lightingSamples: [Quick360LightingSample]
    let floor: CapturedFloorSurfaceMetadata?
}

struct Quick360PanoramaReport: Codable, Equatable {
    let candidateFrameCount: Int
    let selectedKeyframeCount: Int
    let coveragePercent: Double
    let uncoveredPercent: Double
    let maxTranslationM: Float
    let averageTranslationM: Float
    let rejectedFrames: Int
    let dynamicFrameRejects: Int
    let stitchTimeSec: Double
    let outputWidth: Int
    let outputHeight: Int
    let outputByteSize: Int64
    let alignmentRefinementApplied: Bool
    let parallaxWarpLevel: String
    let createdAt: String
    // V4 hybrid metrics
    let sphereCoveragePercent: Double
    let sphereGoodCoveragePercent: Double
    let floorDetected: Bool
    let floorTrackingConfidence: Float
    let floorCoveragePercent: Double
    let floorGoodCoveragePercent: Double
    let floorExtentM: [Float]
    let floorTextureUpdateCount: Int
    let sphereBrushUpdateCount: Int
    let captureDurationSec: Double
    // Visual refinement / keyframe stitch metrics
    let acceptedKeyframeCount: Int
    let rejectedKeyframeCount: Int
    let averageAngularSpacingDeg: Double
    let visualRefinementAttempts: Int
    let successfulRefinements: Int
    let averageMatchCount: Double
    let averageInlierRatio: Double
    let averageReprojectionError: Double
    let highParallaxFrameCount: Int
    let keyframePlacements: [PanoramaKeyframePlacementReport]
    // Full-sphere coverage (independent of live paint)
    let horizontalCoveragePercent: Double
    let upperCoveragePercent: Double
    let lowerCoveragePercent: Double
    let zenithCoveragePercent: Double
    let nadirCoveragePercent: Double
    let overallSphericalCoveragePercent: Double
    let weakCoveragePercent: Double
    let missingCoveragePercent: Double
    let peakMemoryMBEstimate: Double?
}

/// Per-keyframe ARKit initial vs visually refined spherical placement (final stitch).
struct PanoramaKeyframePlacementReport: Codable, Equatable {
    let index: Int
    let fileName: String
    let initialYawDeg: Float
    let initialPitchDeg: Float
    let refinedYawDeg: Float
    let refinedPitchDeg: Float
    let deltaYawDeg: Float
    let deltaPitchDeg: Float
    let matchCount: Int
    let inlierCount: Int
    let inlierRatio: Float
    let reprojectionError: Float
    let refinementAccepted: Bool
    let highParallax: Bool
    let rejectReason: String?
}

struct Quick360SessionSummary: Identifiable, Equatable {
    let id: UUID
    let sessionId: String
    let captureId: String
    let startedAt: Date
    let endedAt: Date
    let progressPercent: Int
    let panoramaURL: URL?
    let coverageMaskURL: URL?
    let metadataURL: URL?
    let floorTextureURL: URL?
    let report: Quick360PanoramaReport?
    let suggestedName: String

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

/// UI-facing capture state (updated on main actor).
struct Quick360CaptureUIState: Equatable {
    var phase: Quick360CapturePhase
    var progressPercent: Int
    var sphereCoveragePercent: Int
    var floorCoveragePercent: Int
    var floorDetected: Bool
    var guidance: Quick360GuidanceKind
    var translationLevel: Quick360TranslationLevel
    var canStart: Bool
    var canFinish: Bool
    var isComplete: Bool
    /// True when weighted spherical coverage meets finish-ready threshold.
    var coverageEnough: Bool
    /// Sparse-region hint for fillGaps (product copy, not debug).
    var coverageHint: String?
    var horizontalCoveragePercent: Int
    var upperCoveragePercent: Int
    var lowerCoveragePercent: Int
    var zenithCoveragePercent: Int
    var nadirCoveragePercent: Int
    /// Internal only — not shown in overlay.
    var selectedCount: Int
    var totalTargets: Int

    static let initial = Quick360CaptureUIState(
        phase: .alignFront,
        progressPercent: 0,
        sphereCoveragePercent: 0,
        floorCoveragePercent: 0,
        floorDetected: false,
        guidance: .faceForward,
        translationLevel: .safe,
        canStart: false,
        canFinish: false,
        isComplete: false,
        coverageEnough: false,
        coverageHint: nil,
        horizontalCoveragePercent: 0,
        upperCoveragePercent: 0,
        lowerCoveragePercent: 0,
        zenithCoveragePercent: 0,
        nadirCoveragePercent: 0,
        selectedCount: 0,
        totalTargets: Quick360Config.targetCount
    )
}
