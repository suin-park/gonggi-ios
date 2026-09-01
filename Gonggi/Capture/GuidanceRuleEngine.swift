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
    let message: String
    let priority: GuidancePriority
    let ruleId: String
}

/// Telemetry-driven coaching with anti-spam cooldown.
struct GuidanceRuleEngine {
    var cooldownSec: TimeInterval = 2.5
    var translationSpeedThresholdMps: Double = 0.45
    var angularSpeedThresholdRadPerSec: Double = 1.2
    var fastMotionThresholdMps: Double = 0.65

    private var lastMessageAt: Date?
    private var lastMessage: String = "천천히 이동하세요"

    mutating func evaluate(
        quality: CaptureQualityState,
        trackingLimited: Bool,
        at date: Date = Date()
    ) -> String {
        let decision = bestDecision(quality: quality, trackingLimited: trackingLimited)
        if shouldUpdate(decision: decision, at: date) {
            lastMessage = decision.message
            lastMessageAt = date
        }
        return lastMessage
    }

    mutating func reset() {
        lastMessageAt = nil
        lastMessage = "천천히 이동하세요"
    }

    func bestDecision(quality: CaptureQualityState, trackingLimited: Bool) -> GuidanceDecision {
        var candidates: [GuidanceDecision] = []

        if trackingLimited || quality.trackingQuality < 0.45 {
            candidates.append(GuidanceDecision(
                message: "카메라를 천천히 움직여 위치를 다시 잡아주세요",
                priority: .critical,
                ruleId: "tracking_limited"
            ))
        }

        if quality.angularVelocity > angularSpeedThresholdRadPerSec {
            candidates.append(GuidanceDecision(
                message: "천천히 회전하세요",
                priority: .high,
                ruleId: "angular_velocity"
            ))
        }

        if quality.motionSpeed > translationSpeedThresholdMps {
            candidates.append(GuidanceDecision(
                message: "조금 더 천천히 이동하세요",
                priority: .high,
                ruleId: "translation_speed"
            ))
        }

        let insufficient = quality.areas.filter { $0.state == .insufficient || $0.state == .unseen }
        if !insufficient.isEmpty {
            candidates.append(GuidanceDecision(
                message: "이 영역을 다른 각도에서 촬영하세요",
                priority: .medium,
                ruleId: "area_observation"
            ))
        }

        let lowDiversity = quality.areas.filter { $0.angleDiversity < 0.25 && $0.observationCount > 0 }
        if !lowDiversity.isEmpty {
            candidates.append(GuidanceDecision(
                message: "옆으로 이동해 다른 각도에서 촬영하세요",
                priority: .medium,
                ruleId: "angle_diversity"
            ))
        }

        if quality.lowTextureScore > 0.55 {
            candidates.append(GuidanceDecision(
                message: "주변 가구나 모서리가 함께 보이도록 촬영하세요",
                priority: .medium,
                ruleId: "low_texture"
            ))
        }

        if quality.blurScore < 0.45 {
            candidates.append(GuidanceDecision(
                message: "카메라를 너무 빠르게 움직이고 있어요",
                priority: .high,
                ruleId: "blur_proxy"
            ))
        }

        if quality.overallCoverage > 0.85 {
            candidates.append(GuidanceDecision(
                message: "이 영역은 충분히 촬영되었습니다",
                priority: .low,
                ruleId: "coverage_good"
            ))
        }

        if let best = candidates.max(by: { $0.priority < $1.priority }) {
            return best
        }
        return GuidanceDecision(
            message: "벽면과 구석, 천장을 골고루 스캔해주세요",
            priority: .low,
            ruleId: "default"
        )
    }

    private func shouldUpdate(decision: GuidanceDecision, at date: Date) -> Bool {
        guard let last = lastMessageAt else { return true }
        if decision.priority >= .critical { return date.timeIntervalSince(last) >= 0.8 }
        if decision.message == lastMessage { return false }
        return date.timeIntervalSince(last) >= cooldownSec
    }
}
