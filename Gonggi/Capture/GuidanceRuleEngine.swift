import Foundation

enum GuidancePriority: Int, Comparable {
    case low = 0
    case medium = 1
    case high = 2
    case critical = 3

    static func < (lhs: GuidancePriority, rhs: GuidancePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct GuidanceDecision: Equatable {
    let action: GuidanceAction
    let priority: GuidancePriority
    let ruleId: String

    /// Resolved via presenter — logic must not hardcode Korean.
    var message: String {
        CaptureGuidanceCopy.message(for: action)
    }
}

enum CaptureGuidanceCopy {
    static func message(for action: GuidanceAction) -> String {
        switch action {
        case .continueCapture:
            return "좋아요. 현재 움직임을 유지하세요."
        case .moveLaterally, .improveBaseline:
            return "제자리에서 돌기보다 옆으로 조금 이동해주세요."
        case .moveForward:
            return "천천히 앞으로 이동해주세요."
        case .slowDown:
            return "조금 천천히 움직여주세요."
        case .holdSteady:
            return "잠시 천천히 움직여주세요."
        case .returnToPreviousArea:
            return "조금 뒤로 돌아가주세요."
        case .scanNewArea:
            return "아직 덜 담긴 영역을 천천히 비춰주세요."
        case .trackingRecovery:
            return "카메라 위치를 다시 확인하고 있어요. 천천히 주변을 비춰주세요."
        case .lowTextureWarning:
            return "특징이 있는 가구나 모서리도 함께 촬영해주세요."
        case .captureNearlyComplete:
            return "거의 다 기록했어요."
        case .captureComplete:
            return "공간 기록을 완료할 수 있어요."
        }
    }

    static func phaseLabel(_ phase: CapturePhase) -> String {
        phase.userLabel
    }
}

/// Telemetry-driven coaching with priority + anti-spam cooldown.
/// Live measurements outrank Astra segment text (Astra = initial plan only).
struct GuidanceRuleEngine {
    var cooldownSec: TimeInterval = 2.5
    var translationSpeedThresholdMps: Double = 0.45
    var angularSpeedThresholdRadPerSec: Double = 1.2

    private var lastMessageAt: Date?
    private var lastAction: GuidanceAction = .continueCapture
    private var lastMessage: String = CaptureGuidanceCopy.message(for: .continueCapture)

    mutating func evaluate(
        quality: CaptureQualityState,
        trackingLimited: Bool,
        at date: Date = Date()
    ) -> String {
        let decision = bestDecision(quality: quality, trackingLimited: trackingLimited)
        if shouldUpdate(decision: decision, at: date) {
            lastAction = decision.action
            lastMessage = decision.message
            lastMessageAt = date
        }
        return lastMessage
    }

    mutating func evaluateDecision(
        quality: CaptureQualityState,
        trackingLimited: Bool,
        at date: Date = Date()
    ) -> GuidanceDecision {
        let decision = bestDecision(quality: quality, trackingLimited: trackingLimited)
        if shouldUpdate(decision: decision, at: date) {
            lastAction = decision.action
            lastMessage = decision.message
            lastMessageAt = date
            return decision
        }
        return GuidanceDecision(action: lastAction, priority: decision.priority, ruleId: "held")
    }

    mutating func reset() {
        lastMessageAt = nil
        lastAction = .continueCapture
        lastMessage = CaptureGuidanceCopy.message(for: .continueCapture)
    }

    var currentAction: GuidanceAction { lastAction }

    func bestDecision(quality: CaptureQualityState, trackingLimited: Bool) -> GuidanceDecision {
        var candidates: [GuidanceDecision] = []

        // 1. Tracking
        if trackingLimited || quality.trackingQuality < 0.45 {
            candidates.append(GuidanceDecision(
                action: .trackingRecovery,
                priority: .critical,
                ruleId: "tracking"
            ))
        }

        // 2. Overlap lost / weak
        if quality.overlapAvailable {
            switch quality.overlapState {
            case .lost:
                candidates.append(GuidanceDecision(
                    action: .returnToPreviousArea,
                    priority: .critical,
                    ruleId: "overlap_lost"
                ))
            case .weak:
                candidates.append(GuidanceDecision(
                    action: .returnToPreviousArea,
                    priority: .high,
                    ruleId: "overlap_weak"
                ))
            default:
                break
            }
        }

        // 3. Severe blur (actual sharpness)
        if quality.sharpnessState == .blurry {
            candidates.append(GuidanceDecision(
                action: .holdSteady,
                priority: .high,
                ruleId: "sharpness"
            ))
        }

        // 4. Movement too fast (motion ≠ sharpness)
        if quality.motionSpeed > translationSpeedThresholdMps
            || quality.angularVelocity > angularSpeedThresholdRadPerSec
        {
            candidates.append(GuidanceDecision(
                action: .slowDown,
                priority: .high,
                ruleId: "motion"
            ))
        }

        // 5. Insufficient translation baseline / in-place spin
        if quality.translationBaselineGrade == .insufficient,
           quality.observedCoverage > 0.08 || quality.overallCoverage > 0.08
        {
            candidates.append(GuidanceDecision(
                action: .improveBaseline,
                priority: .medium,
                ruleId: "baseline"
            ))
        }

        // 6. Low texture
        if quality.lowTextureScore > 0.55 {
            candidates.append(GuidanceDecision(
                action: .lowTextureWarning,
                priority: .medium,
                ruleId: "low_texture"
            ))
        }

        // 7. Coverage fill
        if quality.qualityCoverage < 0.55, quality.completionState == .notReady {
            candidates.append(GuidanceDecision(
                action: .scanNewArea,
                priority: .medium,
                ruleId: "coverage"
            ))
        }

        // 8. Completion / continue
        switch quality.completionState {
        case .ready:
            candidates.append(GuidanceDecision(
                action: .captureComplete,
                priority: .low,
                ruleId: "complete"
            ))
        case .nearlyReady:
            candidates.append(GuidanceDecision(
                action: .captureNearlyComplete,
                priority: .low,
                ruleId: "nearly"
            ))
        case .notReady:
            if quality.overlapState == .good,
               quality.translationBaselineGrade != .insufficient,
               quality.sharpnessState != .blurry,
               !trackingLimited
            {
                candidates.append(GuidanceDecision(
                    action: .continueCapture,
                    priority: .low,
                    ruleId: "good_motion"
                ))
            }
        }

        if let best = candidates.max(by: { $0.priority < $1.priority }) {
            return best
        }
        return GuidanceDecision(action: .continueCapture, priority: .low, ruleId: "default")
    }

    private func shouldUpdate(decision: GuidanceDecision, at date: Date) -> Bool {
        guard let last = lastMessageAt else { return true }
        if decision.priority >= .critical { return date.timeIntervalSince(last) >= 0.8 }
        if decision.action == lastAction { return false }
        return date.timeIntervalSince(last) >= cooldownSec
    }
}
