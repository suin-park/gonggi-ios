import Foundation

/// Sparse guidance timeline (action changes only) for post-capture calibration.
struct CaptureGuidanceHistoryEvent: Codable, Equatable, Sendable {
    var t: Double
    var action: String
    var phase: String?
    var overlap: Double?
    var overlapState: String?
    var qualityCoverage: Double?
    var translationBaseline: String?
    var sharpness: String?
    var tracking: Double?
    var motion: Double?
}

/// Accumulates guidance changes + lightweight metric rollups during one session.
final class CaptureDiagnosticsAccumulator {
    private(set) var events: [CaptureGuidanceHistoryEvent] = []
    private var lastAction: GuidanceAction?
    private var sessionStart: Date?

    // Overlap rollup (time-weighted by sample count)
    private var overlapMin: Double = 1
    private var overlapSum: Double = 0
    private var overlapSamples: Int = 0
    private var overlapGood: Int = 0
    private var overlapWeak: Int = 0
    private var overlapLost: Int = 0
    private var overlapNA: Int = 0

    // Sharpness
    private var sharpnessSum: Double = 0
    private var sharpnessMin: Double = 1
    private var sharpnessSamples: Int = 0

    // Tracking
    private var trackingNormal: Int = 0
    private var trackingLimited: Int = 0
    private var trackingUnavailable: Int = 0

    func reset(at date: Date = Date()) {
        events = []
        lastAction = nil
        sessionStart = date
        overlapMin = 1
        overlapSum = 0
        overlapSamples = 0
        overlapGood = 0
        overlapWeak = 0
        overlapLost = 0
        overlapNA = 0
        sharpnessSum = 0
        sharpnessMin = 1
        sharpnessSamples = 0
        trackingNormal = 0
        trackingLimited = 0
        trackingUnavailable = 0
    }

    func ingest(
        action: GuidanceAction,
        phase: CapturePhase,
        quality: CaptureQualityState,
        trackingNormal: Bool,
        at date: Date = Date()
    ) {
        if sessionStart == nil { sessionStart = date }
        let t = date.timeIntervalSince(sessionStart ?? date)

        // Metric rollups every tick (caller should throttle to guidance cadence).
        if quality.overlapAvailable {
            overlapSum += quality.overlapScore
            overlapSamples += 1
            overlapMin = min(overlapMin, quality.overlapScore)
            switch quality.overlapState {
            case .good: overlapGood += 1
            case .weak: overlapWeak += 1
            case .lost: overlapLost += 1
            case .notAvailable: overlapNA += 1
            }
        } else {
            overlapNA += 1
        }

        if quality.sharpnessScore > 0 {
            sharpnessSum += quality.sharpnessScore
            sharpnessSamples += 1
            sharpnessMin = min(sharpnessMin, quality.sharpnessScore)
        }

        if trackingNormal {
            trackingNormal += 1
        } else if quality.trackingQuality < 0.15 {
            trackingUnavailable += 1
        } else {
            trackingLimited += 1
        }

        guard action != lastAction else { return }
        lastAction = action
        events.append(
            CaptureGuidanceHistoryEvent(
                t: (t * 10).rounded() / 10,
                action: action.rawValue,
                phase: phase.rawValue,
                overlap: quality.overlapAvailable ? quality.overlapScore : nil,
                overlapState: quality.overlapAvailable ? quality.overlapState.rawValue : nil,
                qualityCoverage: quality.qualityCoverage,
                translationBaseline: quality.translationBaselineGrade.rawValue,
                sharpness: quality.sharpnessState.rawValue,
                tracking: quality.trackingQuality,
                motion: quality.motionSpeed
            )
        )
    }

    func overlapStats(sessionDurationSec: Double? = nil) -> CaptureSessionOverlapStats {
        let total = max(1, overlapGood + overlapWeak + overlapLost + overlapNA)
        let goodR = Double(overlapGood) / Double(total)
        let weakR = Double(overlapWeak) / Double(total)
        let lostR = Double(overlapLost) / Double(total)
        let duration = sessionDurationSec
        return CaptureSessionOverlapStats(
            min: overlapSamples > 0 ? overlapMin : nil,
            average: overlapSamples > 0 ? overlapSum / Double(overlapSamples) : nil,
            goodRatio: goodR,
            weakRatio: weakR,
            lostRatio: lostR,
            goodDurationSec: duration.map { $0 * goodR },
            weakDurationSec: duration.map { $0 * weakR },
            lostDurationSec: duration.map { $0 * lostR }
        )
    }

    func sharpnessStats(blurryFraction: Double) -> CaptureSessionSharpnessStats {
        CaptureSessionSharpnessStats(
            average: sharpnessSamples > 0 ? sharpnessSum / Double(sharpnessSamples) : nil,
            min: sharpnessSamples > 0 ? sharpnessMin : nil,
            blurryFraction: blurryFraction
        )
    }

    func trackingStats() -> CaptureSessionTrackingStats {
        let total = max(1, trackingNormal + trackingLimited + trackingUnavailable)
        return CaptureSessionTrackingStats(
            normalRatio: Double(trackingNormal) / Double(total),
            limitedRatio: Double(trackingLimited) / Double(total),
            unavailableRatio: Double(trackingUnavailable) / Double(total)
        )
    }
}

struct CaptureSessionOverlapStats: Codable, Equatable, Sendable {
    var min: Double?
    var average: Double?
    var goodRatio: Double
    var weakRatio: Double
    var lostRatio: Double
    /// Approximate time spent in each overlap bucket (sample-count weighted).
    var goodDurationSec: Double?
    var weakDurationSec: Double?
    var lostDurationSec: Double?
}

struct CaptureSessionSharpnessStats: Codable, Equatable, Sendable {
    var average: Double?
    var min: Double?
    var blurryFraction: Double
}

struct CaptureSessionTrackingStats: Codable, Equatable, Sendable {
    var normalRatio: Double
    var limitedRatio: Double
    var unavailableRatio: Double
}

enum CaptureFinishedBy: String, Codable, Sendable {
    case readyCompletion
    case manualEarlyFinish
}

struct CaptureGenerationDiagnostics: Codable, Equatable, Sendable {
    var createRequestProfile: String?
    var createStatus: Int?
    var uploadStarted: Bool
    var uploadFinished: Bool
    var generationStarted: Bool
    var backendErrorCode: String?
    var idempotencyKey: String?

    static let empty = CaptureGenerationDiagnostics(
        createRequestProfile: nil,
        createStatus: nil,
        uploadStarted: false,
        uploadFinished: false,
        generationStarted: false,
        backendErrorCode: nil,
        idempotencyKey: nil
    )
}

struct CaptureSessionSummaryDiagnostics: Codable, Equatable, Sendable {
    var sessionId: String
    var captureId: String
    var durationSec: Double
    var videoFramesWritten: Int
    var poseSamples: Int
    var droppedFrames: Int
    var acceptedKeyframes: Int
    var totalTravelDistanceM: Double
    var maxTranslationBaselineM: Double
    var observedCoverageFinal: Double
    var qualityCoverageFinal: Double
    var overlap: CaptureSessionOverlapStats
    var sharpness: CaptureSessionSharpnessStats
    var tracking: CaptureSessionTrackingStats
    var poseJumpCount: Int
    var completionStateAtFinish: String
    var finishedBy: String
    var generation: CaptureGenerationDiagnostics
    var appVersion: String
    var buildNumber: String
}
