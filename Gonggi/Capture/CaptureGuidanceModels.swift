import Foundation

// MARK: - Overlap

enum CaptureOverlapState: String, Codable, Equatable, Sendable {
    case good
    case weak
    case lost
    case notAvailable
}

enum OverlapConfig {
    /// Intersection / reference ≥ this → good.
    static var goodMin: Double = 0.55
    /// Below this → lost (force return).
    static var lostMax: Double = 0.22
    /// Between lostMax and goodMin → weak.
    static var referenceWindowSize: Int = 12
    static var pathBufferSize: Int = 28
}

// MARK: - Sharpness

enum CaptureSharpnessState: String, Codable, Equatable, Sendable {
    case sharp
    case acceptable
    case blurry
    case unknown
}

enum SharpnessConfig {
    /// Minimum seconds between Laplacian samples (~5 Hz).
    static var sampleIntervalSec: Double = 0.2
    /// Laplacian variance thresholds (downsampled luma).
    static var sharpMinVariance: Double = 45
    static var acceptableMinVariance: Double = 18
    /// EMA alpha for hysteresis.
    static var emaAlpha: Double = 0.35
    /// Consecutive blurry samples before guidance fires.
    static var blurryConfirmCount: Int = 3
}

// MARK: - Completion

enum CaptureCompletionState: String, Codable, Equatable, Sendable {
    case notReady
    case nearlyReady
    case ready
}

enum CaptureCompletionConfig {
    static var minimumDurationSec: Double = 25
    static var minimumKeyframes: Int = 8
    static var minimumPathLengthM: Double = 1.2
    static var qualityCoverageReady: Double = 0.72
    static var qualityCoverageNearly: Double = 0.55
    static var maxBlurryFraction: Double = 0.35
    static var requireOverlapNotLost: Bool = true
    static var requireTrackingNormal: Bool = true
    static var requireBaselineAtLeastAcceptable: Bool = true
}

// MARK: - Phase

enum CapturePhase: String, Codable, Equatable, Sendable {
    case stabilizing
    case perimeter
    case parallaxPass
    case coverageFill
    case readyToFinish

    var userLabel: String {
        switch self {
        case .stabilizing: return "공간을 확인하고 있어요"
        case .perimeter: return "벽을 따라 천천히 이동하세요"
        case .parallaxPass: return "공간 안쪽도 천천히 이동해주세요"
        case .coverageFill: return "촬영이 부족한 영역을 확인하고 있어요"
        case .readyToFinish: return "공간 기록을 완료할 수 있어요"
        }
    }
}

enum CapturePhaseConfig {
    static var stabilizingSec: Double = 3.0
}

// MARK: - Guidance actions (logic → copy via Presenter)

enum GuidanceAction: String, Codable, Equatable, Sendable {
    case continueCapture
    case moveLaterally
    case moveForward
    case slowDown
    case holdSteady
    case returnToPreviousArea
    case scanNewArea
    case improveBaseline
    case trackingRecovery
    case lowTextureWarning
    case captureNearlyComplete
    case captureComplete
}

/// Normalized Astra initial plan (no API schema change required).
struct CapturePlan: Equatable, Sendable {
    var startHint: String?
    var preferredMovement: String?
    var regionLabels: [String]
    var riskFlags: [String]
    var estimatedTotalSec: Double?
    var segmentCount: Int

    static let empty = CapturePlan(
        startHint: nil,
        preferredMovement: nil,
        regionLabels: [],
        riskFlags: [],
        estimatedTotalSec: nil,
        segmentCount: 0
    )

    /// Best-effort normalize from existing Astra guide plan JSON.
    static func normalize(from plan: AdvancedCaptureGuidePlan) -> CapturePlan {
        let flags = plan.riskFlags.map { $0.lowercased() }
        let preferred = plan.segments.first?.pathHint
        return CapturePlan(
            startHint: plan.segments.first.map { AdvancedCaptureCopy.withoutMiddleDot($0.instructionKo) },
            preferredMovement: preferred,
            regionLabels: plan.segments.compactMap(\.coverageGoal),
            riskFlags: flags,
            estimatedTotalSec: plan.estimatedTotalSec,
            segmentCount: plan.segments.count
        )
    }
}
