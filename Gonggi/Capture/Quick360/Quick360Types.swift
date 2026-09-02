import Foundation
import simd

/// Configuration for Quick 360 Hybrid Space Capture (V4).
enum Quick360Config {
    // Final offline panorama (unchanged)
    static let outputWidth = 2048
    static let outputHeight = 1024

    /// Internal sector layout for keyframe selection (not shown in UI).
    static let yawStepCount = 8
    static let pitchBandsDeg: [Float] = [0, 30, -30]
    static let targetAngularToleranceDeg: Float = 18
    static let candidateWindowSec: Double = 0.65
    static let maxCandidatesPerTarget = 10
    static let minCandidatesBeforeSelect = 3
    static let keyframeJPEGQuality: CGFloat = 0.82
    static let keyframeMaxPixelWidth = 1920

    // Live sphere brush proxy (separate from final panorama)
    /// Keep 512×256; clarity comes from dense FOV fill + bilinear display, not resolution jump.
    static let livePreviewWidth = 512
    static let livePreviewHeight = 256
    static let liveBrushMinIntervalSec: Double = 0.2 // ~5 Hz
    /// Slightly sharper source for FOV sampling (not a proxy resolution increase).
    static let brushThumbMaxWidth = 256
    /// Fade-in for newly painted pixels; settles to full opacity (not persistent translucency).
    static let brushRevealFadeSec: Double = 0.22
    /// FOV edge-only feather band (normalized |nx|/|ny| beyond this gets soft blend).
    static let brushBoundaryFeatherStart: Float = 0.88
    static let unseenNeutralGray: UInt8 = 168
    /// Subtle veil on weak confidence (does not desaturate/blur captured content).
    static let weakConfidenceVeil: Float = 0.12
    static let sphereWeakConfidence: Float = 0.35
    static let sphereGoodConfidence: Float = 0.65
    static let sphereCoverageCompletePercent: Int = 55
    static let sphereLookUpPitchDeg: Float = 35
    static let sphereCeilingSparsePercent: Int = 25

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

    static var targetCount: Int { yawStepCount * pitchBandsDeg.count }
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
    case lookDownFloor
    case lookUp
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
            return "준비가 됐어요"
        case .lookAround, .rotateRight, .rotateLeft:
            return "카메라를 천천히 주변에 비춰보세요"
        case .lookDownFloor:
            return "바닥도 조금 비춰주세요"
        case .lookUp:
            return "위쪽도 조금 담아주세요"
        case .floorRecorded:
            return "좋아요. 바닥도 기록됐어요"
        case .spaceReady:
            return "공간과 바닥이 충분히 기록됐어요"
        case .spaceReadyNoFloor:
            return "공간 기록은 완료됐어요. 바닥 정보는 충분하지 않아요"
        case .stayInPlace, .returnToOrigin, .holdStill:
            return "가능하면 같은 자리에서 촬영해 주세요"
        case .waitForClear:
            return "잠시 기다렸다 다시 비춰주세요"
        case .success:
            return "좋아요"
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
        selectedCount: 0,
        totalTargets: Quick360Config.targetCount
    )
}
