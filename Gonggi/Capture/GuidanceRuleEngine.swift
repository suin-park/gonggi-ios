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
        CaptureUIPresenter.liveCopy(for: action).title
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

        // 1b. Bridge / reacquisition / weak terminal (SfM continuity) — above cell-overlap alone
        switch quality.bridgeMode {
        case .reacquiring:
            candidates.append(GuidanceDecision(
                action: .reacquireView,
                priority: .critical,
                ruleId: "reacquire"
            ))
        case .bridging:
            candidates.append(GuidanceDecision(
                action: .bridgeContinuity,
                priority: .critical,
                ruleId: "bridge"
            ))
        case .idle:
            break
        }
        if quality.bridgeVerdict == .bridgeRequired {
            candidates.append(GuidanceDecision(
                action: .bridgeContinuity,
                priority: .critical,
                ruleId: "bridge_verdict"
            ))
        }
        if quality.bridgeVerdict == .reacquire {
            candidates.append(GuidanceDecision(
                action: .reacquireView,
                priority: .critical,
                ruleId: "reacquire_verdict"
            ))
        }
        if quality.completionState != .ready, quality.terminalContinuityOK == false,
           quality.reconstructionCoverage >= CaptureBridgeConfig.reconstructionCoverageNearly
        {
            candidates.append(GuidanceDecision(
                action: .finishBlockedWeakTerminal,
                priority: .high,
                ruleId: "terminal_weak"
            ))
        }

        // 2. Coverage-cell overlap (CellOverlapAnalyzer) — diagnostic / soft only.
        // Never escalate cell `.lost` to returnToPreviousArea / reacquire; normal walks enter new cells.
        if quality.overlapAvailable {
            switch quality.overlapState {
            case .lost, .weak:
                candidates.append(GuidanceDecision(
                    action: .scanNewArea,
                    priority: .low,
                    ruleId: "cell_overlap_soft"
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

        // 7. Sector / ring coverage before soft percent
        if quality.completionState != .ready {
            switch quality.guidanceStage {
            case .eyeLevelSweep:
                candidates.append(GuidanceDecision(
                    action: .needMoreYaw,
                    priority: .medium,
                    ruleId: "sector_middle"
                ))
            case .upperSweep:
                candidates.append(GuidanceDecision(
                    action: .needUpperCoverage,
                    priority: .medium,
                    ruleId: "sector_upper"
                ))
            case .lowerSweep:
                candidates.append(GuidanceDecision(
                    action: .needLowerCoverage,
                    priority: .medium,
                    ruleId: "sector_lower"
                ))
            case .fillGaps:
                candidates.append(GuidanceDecision(
                    action: .scanNewArea,
                    priority: .medium,
                    ruleId: "sector_fill"
                ))
            case .softComplete, .reconstructionReady:
                break
            }
        }

        // 8. Legacy coverage fill (fallback when sector stage not yet informative)
        if quality.qualityCoverage < 0.55,
           quality.completionState == .notReady,
           quality.guidanceStage == .eyeLevelSweep
        {
            candidates.append(GuidanceDecision(
                action: .scanNewArea,
                priority: .medium,
                ruleId: "coverage"
            ))
        }

        // 9. Completion / continue — `.ready` only when reconstructionReady
        switch quality.completionState {
        case .ready:
            candidates.append(GuidanceDecision(
                action: .captureComplete,
                priority: .low,
                ruleId: "complete"
            ))
        case .nearlyReady:
            let deficit = CaptureCompletionGate.primaryDeficit(
                reconstruction: nil,
                sectorProgress: quality.sectorRingProgress,
                baselineGrade: quality.translationBaselineGrade,
                pathLengthM: 0,
                bridgeMode: quality.bridgeMode,
                terminalContinuityOK: quality.terminalContinuityOK
            )
            candidates.append(GuidanceDecision(
                action: deficit == .scanNewArea ? .captureNearlyComplete : deficit,
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
