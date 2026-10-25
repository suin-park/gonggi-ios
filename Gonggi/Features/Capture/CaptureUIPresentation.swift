import SwiftUI

// MARK: - UI-only presentation (does not alter capture algorithms)

enum CaptureWarningKind: Equatable {
    case fastMovement
    case trackingLimited
    case lowTexture
    case overlapWeak
    case blurryFrame
    case baselineWeak

    var icon: String {
        switch self {
        case .fastMovement: return "hare.fill"
        case .trackingLimited: return "location.slash.fill"
        case .lowTexture: return "square.dashed"
        case .overlapWeak: return "link.badge.plus"
        case .blurryFrame: return "eye.slash"
        case .baselineWeak: return "arrow.left.and.right"
        }
    }
}

enum CaptureCoachSeverity: Equatable {
    case guidance
    case good
    case warning
    case critical

    var accent: Color {
        switch self {
        case .guidance: return GonggiColors.accentTeal
        case .good: return GonggiColors.successGreen
        case .warning: return GonggiColors.warning
        case .critical: return GonggiColors.warningCritical
        }
    }

    var iconTint: Color {
        switch self {
        case .guidance: return GonggiColors.accentCyan
        case .good: return GonggiColors.successGreen
        case .warning: return GonggiColors.warning
        case .critical: return GonggiColors.warningCritical
        }
    }
}

/// Optional visual direction — only when the action implies a known glyph (never invent L/R).
enum PrimaryGuidanceDirection: Equatable {
    case none
    case forward
    case returnBack

    var glyph: String? {
        switch self {
        case .none: return nil
        case .forward: return "↑"
        case .returnBack: return "↶"
        }
    }
}

enum PrimaryGuidanceSeverity: Equatable {
    case normal
    case warning
    case critical

    var coachSeverity: CaptureCoachSeverity {
        switch self {
        case .normal: return .guidance
        case .warning: return .warning
        case .critical: return .critical
        }
    }
}

/// Tunable UI hold times (device-adjustable without touching analyzers).
enum PrimaryGuidanceUIConfig {
    static var normalMinHoldSec: TimeInterval = 2.5
    static var warningMinHoldSec: TimeInterval = 1.2
    /// Critical may interrupt immediately after this floor.
    static var criticalMinHoldSec: TimeInterval = 0.0
}

/// Single source of truth for the capture coach UI.
struct PrimaryGuidanceState: Equatable {
    var action: GuidanceAction
    var title: String
    var subtitle: String?
    var direction: PrimaryGuidanceDirection
    var severity: PrimaryGuidanceSeverity
    /// Bottom status only (not an action instruction).
    var statusLabel: String
    var finishButtonTitle: String
    var isReadyToFinish: Bool
    /// Ring fill from qualityCoverage (visual only — no user-facing %).
    var ringProgress: Double
    var ringSystemImage: String
    var source: Source

    enum Source: String, Equatable {
        case live
        case astra
        case phaseDefault
        case completion
    }

    var identityKey: String {
        "\(action.rawValue)|\(title)|\(subtitle ?? "")|\(source.rawValue)"
    }

    var coachPresentation: CaptureCoachPresentation {
        CaptureCoachPresentation(
            title: title,
            subtitle: subtitle,
            severity: isReadyToFinish ? .good : severity.coachSeverity,
            icon: ringSystemImage,
            warning: nil,
            directionGlyph: direction.glyph
        )
    }
}

struct CaptureCoachPresentation: Equatable {
    let title: String
    let subtitle: String?
    let severity: CaptureCoachSeverity
    let icon: String
    let warning: CaptureWarningKind?
    var directionGlyph: String? = nil
}

@MainActor
final class PrimaryGuidanceHoldController: ObservableObject {
    private var last: PrimaryGuidanceState?
    private var lastChangedAt: Date?

    func reset() {
        last = nil
        lastChangedAt = nil
    }

    func resolve(_ candidate: PrimaryGuidanceState, at date: Date = Date()) -> PrimaryGuidanceState {
        guard let previous = last, let changedAt = lastChangedAt else {
            last = candidate
            lastChangedAt = date
            return candidate
        }
        if candidate.identityKey == previous.identityKey {
            return previous
        }
        // Critical always wins quickly.
        if candidate.severity == .critical {
            let floor = PrimaryGuidanceUIConfig.criticalMinHoldSec
            if date.timeIntervalSince(changedAt) >= floor || previous.severity != .critical {
                last = candidate
                lastChangedAt = date
                return candidate
            }
            return previous
        }
        let minHold: TimeInterval
        switch previous.severity {
        case .critical: minHold = PrimaryGuidanceUIConfig.warningMinHoldSec
        case .warning: minHold = PrimaryGuidanceUIConfig.warningMinHoldSec
        case .normal: minHold = PrimaryGuidanceUIConfig.normalMinHoldSec
        }
        if date.timeIntervalSince(changedAt) < minHold {
            return previous
        }
        last = candidate
        lastChangedAt = date
        return candidate
    }
}

enum CaptureUIPresenter {
    /// Highest-priority active warning for chips / Astra suppression (problem-only).
    static func warningKind(for quality: CaptureQualityState) -> CaptureWarningKind? {
        if quality.trackingQuality < 0.5 { return .trackingLimited }
        if quality.overlapAvailable, quality.overlapState == .lost || quality.overlapState == .weak {
            return .overlapWeak
        }
        if quality.sharpnessState == .blurry { return .blurryFrame }
        if quality.motionSpeed > 0.7 { return .fastMovement }
        if quality.translationBaselineGrade == .insufficient, quality.observedCoverage > 0.1 {
            return .baselineWeak
        }
        if quality.lowTextureScore > 0.6 { return .lowTexture }
        return nil
    }

    /// Live correction that should suppress Astra segment UI entirely.
    static func hasLiveCorrection(quality: CaptureQualityState) -> Bool {
        if warningKind(for: quality) != nil { return true }
        switch quality.guidanceAction {
        case .trackingRecovery, .returnToPreviousArea, .reacquireView, .saveStalled, .bridgeContinuity,
             .finishBlockedWeakTerminal, .slowDown, .holdSteady,
             .improveBaseline, .moveLaterally, .lowTextureWarning:
            return true
        case .continueCapture, .moveForward, .scanNewArea,
             .needMoreYaw, .needUpperCoverage, .needLowerCoverage,
             .captureNearlyComplete, .captureComplete, .captureGap, .captureCoach:
            return false
        }
    }

    static func statusLabel(for state: CaptureCompletionState) -> String {
        switch state {
        case .notReady: return L("Capturing the space")
        case .nearlyReady: return L("Look around a bit more")
        case .ready: return L("Capture complete")
        }
    }

    static func statusLabel(for stage: CaptureGuidanceStage, completion: CaptureCompletionState) -> String {
        if completion == .ready { return CaptureGuidanceStage.reconstructionReady.statusLabel }
        return stage.statusLabel
    }

    static func finishButtonTitle(isReady: Bool) -> String {
        isReady ? L("Finish capture") : L("End capture")
    }

    /// Only the way back to an area already filmed gets a glyph (the user walked there). No arrow ever picks a new
    /// walking path: without LiDAR the app cannot tell whether that way is walkable (build 82).
    static func direction(for action: GuidanceAction) -> PrimaryGuidanceDirection {
        switch action {
        case .returnToPreviousArea, .reacquireView, .finishBlockedWeakTerminal: return .returnBack
        default: return .none
        }
    }

    static func severity(for action: GuidanceAction, warning: CaptureWarningKind?) -> PrimaryGuidanceSeverity {
        if warning == .trackingLimited || warning == .overlapWeak { return .critical }
        switch action {
        case .trackingRecovery, .returnToPreviousArea, .reacquireView, .saveStalled, .finishBlockedWeakTerminal:
            return .critical
        case .bridgeContinuity, .slowDown, .holdSteady, .lowTextureWarning, .improveBaseline, .moveLaterally,
             .scanNewArea, .needMoreYaw, .needUpperCoverage, .needLowerCoverage:
            return .warning
        default:
            return .normal
        }
    }

    /// Ring shows sector/ring fill — not raw qualityCoverage percent.
    static func ringSystemImage(for state: CaptureCompletionState, action: GuidanceAction) -> String {
        _ = action
        switch state {
        case .ready:
            return "checkmark"
        case .nearlyReady:
            return "checkmark.circle"
        case .notReady:
            return "viewfinder"
        }
    }

    /// Build the single primary guidance state (no competing action cards).
    /// Priority: critical/warning live correction → completion ready → Astra → phase default.
    static func primaryGuidance(
        quality: CaptureQualityState,
        astraSegmentInstruction: String? = nil
    ) -> PrimaryGuidanceState {
        let action = quality.guidanceAction
        let warning = warningKind(for: quality)
        let ready = quality.completionState == .ready || quality.reconstructionReady
        let ring = min(1, max(0, max(quality.sectorRingProgress.fillRatio, quality.qualityCoverage * 0.35)))
        let status = statusLabel(for: quality.guidanceStage, completion: quality.completionState)

        // Live correction always outranks completion copy — even if gate still reports ready
        // (e.g. severe motion / weak overlap do not always clear ready in the same snapshot).
        if hasLiveCorrection(quality: quality) {
            let copy = liveCopy(for: action)
            let sev = severity(for: action, warning: warning)
            return PrimaryGuidanceState(
                action: action,
                title: copy.title,
                subtitle: copy.subtitle,
                direction: direction(for: action),
                severity: sev,
                statusLabel: statusLabel(for: .notReady),
                finishButtonTitle: finishButtonTitle(isReady: false),
                isReadyToFinish: false,
                ringProgress: ring,
                ringSystemImage: ringSystemImage(for: .notReady, action: action),
                source: .live
            )
        }

        // Guide v4 motion coach (guidance only): one short line, finishing stays as the gate says.
        if action == .captureCoach, let coach = quality.coachPrompt {
            let copy = coachCopy(coach)
            return PrimaryGuidanceState(
                action: action,
                title: copy.title,
                subtitle: copy.subtitle,
                direction: .none,
                severity: .normal,
                statusLabel: status,
                finishButtonTitle: finishButtonTitle(isReady: ready),
                isReadyToFinish: ready,
                ringProgress: ready ? 1 : ring,
                ringSystemImage: ready ? "checkmark" : ringSystemImage(for: quality.completionState, action: action),
                source: .live
            )
        }

        // Guide v3 gap prompt (guidance only): shown before "촬영이 충분합니다", finishing stays as the gate says.
        if action == .captureGap, let gap = quality.gapPrompt {
            let copy = gapCopy(gap)
            return PrimaryGuidanceState(
                action: action,
                title: copy.title,
                subtitle: copy.subtitle,
                direction: .none,
                severity: .normal,
                statusLabel: status,
                finishButtonTitle: finishButtonTitle(isReady: ready),
                isReadyToFinish: ready,
                ringProgress: ready ? 1 : ring,
                ringSystemImage: ready ? "checkmark" : ringSystemImage(for: quality.completionState, action: action),
                source: .live
            )
        }

        // Completion ready — only when reconstructionReady (strict gate).
        if ready {
            return PrimaryGuidanceState(
                action: .captureComplete,
                title: completionTitle(quality: quality),
                subtitle: completionSubtitle(quality: quality),
                direction: .none,
                severity: .normal,
                statusLabel: status,
                finishButtonTitle: finishButtonTitle(isReady: true),
                isReadyToFinish: true,
                ringProgress: 1,
                ringSystemImage: "checkmark",
                source: .completion
            )
        }

        // Calm path: prefer Astra segment as the single action hint when available.
        if let astra = astraSegmentInstruction?.trimmingCharacters(in: .whitespacesAndNewlines),
           !astra.isEmpty
        {
            let subtitle: String? = {
                if quality.completionState == .nearlyReady { return status }
                return secondaryHint(for: action)
            }()
            return PrimaryGuidanceState(
                action: action,
                title: astra,
                subtitle: subtitle,
                direction: .none,
                severity: .normal,
                statusLabel: status,
                finishButtonTitle: finishButtonTitle(isReady: false),
                isReadyToFinish: false,
                ringProgress: ring,
                ringSystemImage: ringSystemImage(for: quality.completionState, action: action),
                source: .astra
            )
        }

        // Sector / soft-complete coaching — prefer concrete missing coverage over percent.
        if quality.completionState == .nearlyReady
            || [.needMoreYaw, .needUpperCoverage, .needLowerCoverage, .captureNearlyComplete].contains(action)
        {
            let copy = liveCopy(for: action == .continueCapture ? .captureNearlyComplete : action)
            return PrimaryGuidanceState(
                action: action,
                title: copy.title,
                subtitle: copy.subtitle,
                direction: .none,
                severity: .normal,
                statusLabel: status,
                finishButtonTitle: finishButtonTitle(isReady: false),
                isReadyToFinish: false,
                ringProgress: ring,
                ringSystemImage: "checkmark.circle",
                source: .completion
            )
        }

        let copy = liveCopy(for: action == .continueCapture ? .continueCapture : action)
        return PrimaryGuidanceState(
            action: action,
            title: copy.title,
            subtitle: copy.subtitle,
            direction: direction(for: action),
            severity: .normal,
            statusLabel: status,
            finishButtonTitle: finishButtonTitle(isReady: false),
            isReadyToFinish: false,
            ringProgress: ring,
            ringSystemImage: ringSystemImage(for: quality.completionState, action: action),
            source: action == .continueCapture ? .phaseDefault : .live
        )
    }

    /// User-facing copy for a live action (single primary + optional supporting line).
    static func liveCopy(for action: GuidanceAction) -> (title: String, subtitle: String?) {
        switch action {
        case .continueCapture:
            return (
                L("Walk slowly along the walls while capturing"),
                L("Let each view overlap the last, and capture the same things from other spots too")
            )
        case .moveLaterally, .improveBaseline:
            return (
                L("Take a step or two where you can walk"),
                L("Seeing the same spot from other positions makes the 3D Space more accurate")
            )
        case .moveForward:
            return (L("Move slowly where you can walk"), nil)
        case .slowDown:
            return (L("Please move a little more slowly"), nil)
        case .holdSteady:
            return (L("Move slowly for a moment"), nil)
        case .returnToPreviousArea:
            // True spatial revisit (separate from reacquireView screen-overlap recovery).
            return (L("Move until the spot you just captured is visible again"), L("Finding the connection again"))
        case .reacquireView:
            return (
                L("Move slowly until this view appears again"),
                L("Turning sharply can break the 3D connection")
            )
        case .bridgeContinuity:
            return (
                L("Keep turning a little more slowly"),
                L("Capturing in-between views to keep the connection")
            )
        case .saveStalled:
            return (
                L("Photos aren't being saved"),
                L("Pause and point at one spot to start saving again. Turn slowly")
            )
        case .finishBlockedWeakTerminal:
            return (
                L("Slowly reconnect the last direction"),
                L("The last view is too weak to finish. Turn little by little so it connects to what you just saw")
            )
        case .scanNewArea:
            return (L("Slowly point at areas not captured yet"), L("Moving a little at a time makes a more accurate 3D Space"))
        case .needMoreYaw:
            return (
                L("Walk and capture other directions too"),
                L("Keep what you see on screen and slowly turn while moving where you can walk")
            )
        case .needUpperCoverage:
            return (
                L("Include where the wall meets the ceiling"),
                L("Raise the phone a little and move slowly where you can walk. Don't point only at the ceiling")
            )
        case .needLowerCoverage:
            return (
                L("Include where the wall meets the floor"),
                L("Lower the phone a little so furniture legs or the edge of a mat are visible")
            )
        case .trackingRecovery:
            return (L("Slowly point around you"), L("Checking the camera position again"))
        case .lowTextureWarning:
            return (L("Include furniture or corners in the frame too"), nil)
        case .captureNearlyComplete:
            return (L("Almost done"), L("Walk and capture a bit more of the ceiling and floor edges and the opposite side"))
        case .captureGap:
            return (L("Capture the missing directions a bit more"), L("Move slowly so photos keep saving"))
        case .captureCoach:
            return (L("Take a step or two where you can walk"), nil)
        case .captureComplete:
            return (L("You have enough"), L("You've captured enough of the space. You can finish"))
        }
    }

    /// Guide v3 copy. Turns are slow and continuous so photos keep saving on the way; the direction is only
    /// where to end up facing.
    static func gapCopy(_ gap: CaptureGapModel.Prompt) -> (title: String, subtitle: String?) {
        let side: String = {
            switch gap.turn {
            case .ahead: return L("Ahead")
            case .left: return L("Left")
            case .right: return L("Right")
            case .behind: return L("Back")
            }
        }()
        switch gap.kind {
        case .up:
            return (L("Capture the ceiling edge too"), L("Raise the phone a little so the wall-ceiling line or lights are visible"))
        case .opposite:
            // The side is where to end up *facing* (the missing view), not a walking path.
            return (gap.turn == .ahead ? L("Capture a bit more of the direction you're facing") : L("Capture the %@ direction too", "\(side)"),
                    L("Take a few steps where you can walk and turn slowly so the photos keep connecting"))
        case .tops:
            return (L("Capture the tops of the furniture %@ too", "\(side)"), L("If you can, step closer and point down from above"))
        case .farEnd:
            return (L("The %@ side was only captured from far away", "\(side)"), L("If you can walk there, step a few steps closer. If not, you can keep going"))
        }
    }

    /// Guide v4 motion-coach copy. The feet prompt is based on pitch only, so it says feet *may* be in the photo.
    static func coachCopy(_ c: CaptureMotionCoach.Prompt) -> (title: String, subtitle: String?) {
        switch c.kind {
        case .sideStep:
            return (L("Take a step or two where you can walk"), L("Seeing the same spot from other positions makes the 3D Space more accurate"))
        case .ceilingContext:
            return (L("Lower it a little to include the edge"), L("Only the ceiling makes it hard to track. Include the wall-ceiling line or lights"))
        case .floorFeet:
            return (L("Point at the floor a little ahead"), L("Pointing at your feet too long may put your feet in the photos"))
        case .floorContext:
            return (L("Capture the floor along with its edges"), L("Show furniture legs, mat edges and where walls meet the floor"))
        case .targetStep:
            return (L("Keep what you see on screen and take two or three steps where you can walk"), L("If that's hard, you can keep capturing as is"))
        }
    }

    /// "충분" only when nothing is open. Open items (not asked yet, asked and still missing, photo limit) keep the
    /// finish button as it is but never read as enough.
    static func completionTitle(quality: CaptureQualityState) -> String {
        completionLines(quality).isEmpty ? L("You have enough") : L("You can finish the capture")
    }

    /// Completion copy with the open items and their status (never a finish gate).
    static func completionSubtitle(quality: CaptureQualityState) -> String {
        let lines = completionLines(quality)
        guard !lines.isEmpty else { return L("You've captured enough of the space. You can finish") }
        return L("You can finish now. Remaining: ") + lines.prefix(3).joined(separator: ", ")
    }

    private static func completionLines(_ quality: CaptureQualityState) -> [String] {
        quality.captureRemaining.isEmpty ? quality.captureRecommendations : quality.captureRemaining.map(\.shortLine)
    }

    private static func secondaryHint(for action: GuidanceAction) -> String? {
        switch action {
        case .continueCapture, .moveLaterally, .improveBaseline, .needMoreYaw:
            return L("Capture while moving a little at a time")
        default:
            return nil
        }
    }

    // MARK: - Legacy coachPresentation (tests / previews)

    static func coachPresentation(
        quality: CaptureQualityState,
        fallbackMessage: String
    ) -> CaptureCoachPresentation {
        _ = fallbackMessage
        return primaryGuidance(quality: quality).coachPresentation
    }

    static func isReadyToFinish(_ quality: CaptureQualityState) -> Bool {
        quality.completionState == .ready
    }

    static func progressEmphasis(for quality: CaptureQualityState) -> CaptureProgressEmphasis {
        if isReadyToFinish(quality) { return .ready }
        if quality.qualityCoverage >= 0.55 { return .progressing }
        return .needsWork
    }

    static func overlayDimming(for quality: CaptureQualityState) -> Double {
        quality.trackingQuality < 0.5 ? 0.28 : 0
    }

    static func userGradeLabel(_ kind: String, quality: CaptureQualityState) -> String {
        switch kind {
        case "coverage":
            if quality.qualityCoverage >= 0.72 { return L("Enough") }
            if quality.qualityCoverage >= 0.45 { return L("Fair") }
            return L("More photos recommended")
        case "baseline":
            switch quality.translationBaselineGrade {
            case .good: return L("Good")
            case .acceptable: return L("Fair")
            case .insufficient: return L("More photos recommended")
            }
        case "overlap":
            switch quality.overlapState {
            case .good: return L("Stable")
            case .weak: return L("Fair")
            case .lost: return L("More photos recommended")
            case .notAvailable: return "—"
            }
        case "sharpness":
            switch quality.sharpnessState {
            case .sharp: return L("Good")
            case .acceptable: return L("Fair")
            case .blurry: return L("More photos recommended")
            case .unknown: return "—"
            }
        case "tracking":
            return quality.trackingQuality >= 0.7 ? L("Stable") : L("More photos recommended")
        default:
            return "—"
        }
    }
}
