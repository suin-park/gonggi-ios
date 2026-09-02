import Foundation
import simd

/// Configuration for Quick 360 Capture Prototype V2.
enum Quick360Config {
    static let outputWidth = 2048
    static let outputHeight = 1024
    /// 8 yaw × 3 pitch = 24 guidance targets (~12–24 keyframe product goal, ~30–60s capture).
    static let yawStepCount = 8
    static let pitchBandsDeg: [Float] = [0, 30, -30]
    static let targetAngularToleranceDeg: Float = 14
    static let candidateWindowSec: Double = 0.65
    static let maxCandidatesPerTarget = 10
    static let minCandidatesBeforeSelect = 3
    static let keyframeJPEGQuality: CGFloat = 0.82
    static let keyframeMaxPixelWidth = 1920

    // Translation / parallax guard (meters)
    static let translationSafeM: Float = 0.035
    static let translationWarningM: Float = 0.09
    static let translationExcessiveM: Float = 0.16

    // Quality scoring weights
    static let weightOrientation: Float = 0.35
    static let weightTranslation: Float = 0.25
    static let weightSharpness: Float = 0.25
    static let weightExposure: Float = 0.15

    static var targetCount: Int { yawStepCount * pitchBandsDeg.count }
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

    var guidanceMessage: String? {
        switch self {
        case .safe: return nil
        case .warning: return "휴대폰 위치를 유지해주세요"
        case .excessive: return "촬영 위치에서 너무 멀어졌어요"
        }
    }
}

enum Quick360GuidanceKind: Equatable {
    case alignTarget
    case rotateRight
    case rotateLeft
    case holdStill
    case waitForClear
    case success
    case returnToOrigin

    var primaryText: String {
        switch self {
        case .alignTarget: return "여기를 맞춰주세요"
        case .rotateRight: return "천천히 오른쪽으로\n돌려주세요"
        case .rotateLeft: return "천천히 왼쪽으로\n돌려주세요"
        case .holdStill: return "휴대폰 위치를 유지해주세요"
        case .waitForClear: return "잠시 기다렸다 다시 비춰주세요"
        case .success: return "좋아요 ✓"
        case .returnToOrigin: return "원래 위치로 조금 돌아와주세요"
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
    let report: Quick360PanoramaReport?
    let suggestedName: String

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

/// UI-facing capture state (updated on main actor).
struct Quick360CaptureUIState: Equatable {
    var progressPercent: Int
    var guidance: Quick360GuidanceKind
    var translationLevel: Quick360TranslationLevel
    var currentTarget: Quick360SphericalTarget?
    var selectedCount: Int
    var totalTargets: Int
    var isComplete: Bool

    static let initial = Quick360CaptureUIState(
        progressPercent: 0,
        guidance: .alignTarget,
        translationLevel: .safe,
        currentTarget: nil,
        selectedCount: 0,
        totalTargets: Quick360Config.targetCount,
        isComplete: false
    )
}
