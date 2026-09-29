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
        case .notReady: return "공간 기록 중"
        case .nearlyReady: return "조금 더 둘러봐 주세요"
        case .ready: return "촬영 완료"
        }
    }

    static func statusLabel(for stage: CaptureGuidanceStage, completion: CaptureCompletionState) -> String {
        if completion == .ready { return CaptureGuidanceStage.reconstructionReady.statusLabel }
        return stage.statusLabel
    }

    static func finishButtonTitle(isReady: Bool) -> String {
        isReady ? "기록 완료" : "촬영 종료"
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
                "벽을 따라 천천히 걸으며 담아 주세요",
                "앞 장면이 조금씩 겹치게 이어 가며, 같은 물건을 다른 위치에서도 비춰 주세요"
            )
        case .moveLaterally, .improveBaseline:
            return (
                "걸을 수 있는 쪽으로 한두 걸음 옮겨 주세요",
                "같은 곳을 다른 위치에서 보면 3D 공간이 더 정확해져요"
            )
        case .moveForward:
            return ("걸을 수 있는 쪽으로 천천히 옮겨 주세요", nil)
        case .slowDown:
            return ("조금 천천히 움직여주세요", nil)
        case .holdSteady:
            return ("잠시 천천히 움직여주세요", nil)
        case .returnToPreviousArea:
            // True spatial revisit (separate from reacquireView screen-overlap recovery).
            return ("방금 촬영한 곳이 다시 보이도록 이동해주세요", "연결을 다시 찾고 있어요")
        case .reacquireView:
            return (
                "이 장면이 다시 보이도록 천천히 움직여주세요",
                "갑자기 크게 돌리면 3D 연결이 끊길 수 있어요"
            )
        case .bridgeContinuity:
            return (
                "방향을 조금 더 천천히 이어가 주세요",
                "중간 장면을 담아 연결을 유지하고 있어요"
            )
        case .saveStalled:
            return (
                "사진이 저장되지 않고 있어요",
                "잠시 멈춰 한 곳을 비추면 다시 저장돼요. 방향은 천천히 바꿔 주세요"
            )
        case .finishBlockedWeakTerminal:
            return (
                "마지막 방향을 천천히 다시 연결해 주세요",
                "끝난 직전 장면이 약해 완료할 수 없어요. 방금 본 곳과 이어지게 조금씩 돌려 촬영해 주세요"
            )
        case .scanNewArea:
            return ("아직 덜 담긴 영역을 천천히 비춰주세요", "조금씩 위치를 옮기면 더 정확한 3D 공간을 만들 수 있어요")
        case .needMoreYaw:
            return (
                "걸으며 다른 방향도 담아 주세요",
                "지금 보이는 곳을 화면에 둔 채, 걸을 수 있는 쪽으로 옮기며 천천히 방향을 바꿔 주세요"
            )
        case .needUpperCoverage:
            return (
                "벽과 천장이 만나는 선을 함께 담아 주세요",
                "휴대폰을 조금 들고 걸을 수 있는 쪽으로 천천히 옮겨 주세요. 천장만 비추지는 말아 주세요"
            )
        case .needLowerCoverage:
            return (
                "벽과 바닥이 만나는 곳을 함께 담아 주세요",
                "휴대폰을 조금 내려 가구 다리나 매트 끝이 보이게 해 주세요"
            )
        case .trackingRecovery:
            return ("천천히 주변을 비춰주세요", "카메라 위치를 다시 확인하고 있어요")
        case .lowTextureWarning:
            return ("가구나 모서리도 화면에 함께 담아주세요", nil)
        case .captureNearlyComplete:
            return ("거의 다 담았어요", "천장·바닥 경계와 반대쪽도 걸으며 조금 더 담아 주세요")
        case .captureGap:
            return ("부족한 방향을 조금 더 담아 주세요", "사진이 계속 저장되도록 천천히 움직여 주세요")
        case .captureCoach:
            return ("걸을 수 있는 쪽으로 한두 걸음 옮겨 주세요", nil)
        case .captureComplete:
            return ("촬영이 충분합니다", "공간을 충분히 담았어요. 기록을 완료할 수 있어요")
        }
    }

    /// Guide v3 copy. Turns are slow and continuous so photos keep saving on the way; the direction is only
    /// where to end up facing.
    static func gapCopy(_ gap: CaptureGapModel.Prompt) -> (title: String, subtitle: String?) {
        let side: String = {
            switch gap.turn {
            case .ahead: return "앞쪽"
            case .left: return "왼쪽"
            case .right: return "오른쪽"
            case .behind: return "뒤쪽"
            }
        }()
        switch gap.kind {
        case .up:
            return ("천장 경계도 담아 주세요", "벽과 천장이 만나는 선이나 조명이 보이게 휴대폰을 조금 들어 주세요")
        case .opposite:
            // The side is where to end up *facing* (the missing view), not a walking path.
            return (gap.turn == .ahead ? "지금 보는 방향을 조금 더 담아 주세요" : "\(side) 방향도 담아 주세요",
                    "걸을 수 있는 쪽으로 몇 걸음 옮기며 천천히 방향을 바꾸면 사진이 끊기지 않고 이어져요")
        case .tops:
            return ("\(side) 가구 윗면도 담아 주세요", "다가갈 수 있으면 한 걸음 가까이 가서 위에서 비춰 주세요")
        case .farEnd:
            return ("\(side) 쪽은 멀리서만 담겼어요", "걸어갈 수 있으면 몇 걸음 가까이 가서 담아 주세요. 어려우면 그대로 계속해도 돼요")
        }
    }

    /// Guide v4 motion-coach copy. The feet prompt is based on pitch only, so it says feet *may* be in the photo.
    static func coachCopy(_ c: CaptureMotionCoach.Prompt) -> (title: String, subtitle: String?) {
        switch c.kind {
        case .sideStep:
            return ("걸을 수 있는 쪽으로 한두 걸음 옮겨 주세요", "같은 곳을 다른 위치에서 보면 3D 공간이 더 정확해져요")
        case .ceilingContext:
            return ("조금 내려 경계를 함께 담아 주세요", "천장만 보이면 위치를 잡기 어려워요. 벽과 천장이 만나는 선이나 조명을 함께 담아 주세요")
        case .floorFeet:
            return ("조금 앞쪽 바닥을 비춰 주세요", "발밑을 오래 비추면 발이 사진에 찍힐 수 있어요")
        case .floorContext:
            return ("바닥은 경계와 함께 담아 주세요", "가구 다리, 매트 끝, 벽과 바닥이 만나는 곳이 보이게 해 주세요")
        case .targetStep:
            return ("지금 보이는 곳을 화면에 둔 채 걸을 수 있는 쪽으로 두세 걸음 옮겨 주세요", "어려우면 그대로 계속 찍어도 돼요")
        }
    }

    /// "충분" only when nothing is open. Open items (not asked yet, asked and still missing, photo limit) keep the
    /// finish button as it is but never read as enough.
    static func completionTitle(quality: CaptureQualityState) -> String {
        completionLines(quality).isEmpty ? "촬영이 충분합니다" : "촬영을 마칠 수 있어요"
    }

    /// Completion copy with the open items and their status (never a finish gate).
    static func completionSubtitle(quality: CaptureQualityState) -> String {
        let lines = completionLines(quality)
        guard !lines.isEmpty else { return "공간을 충분히 담았어요. 기록을 완료할 수 있어요" }
        return "지금 완료해도 돼요. 남은 곳: " + lines.prefix(3).joined(separator: " · ")
    }

    private static func completionLines(_ quality: CaptureQualityState) -> [String] {
        quality.captureRemaining.isEmpty ? quality.captureRecommendations : quality.captureRemaining.map(\.shortLine)
    }

    private static func secondaryHint(for action: GuidanceAction) -> String? {
        switch action {
        case .continueCapture, .moveLaterally, .improveBaseline, .needMoreYaw:
            return "조금씩 위치를 옮기면서 촬영해 주세요"
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
            if quality.qualityCoverage >= 0.72 { return "충분" }
            if quality.qualityCoverage >= 0.45 { return "보통" }
            return "추가 촬영 권장"
        case "baseline":
            switch quality.translationBaselineGrade {
            case .good: return "좋음"
            case .acceptable: return "보통"
            case .insufficient: return "추가 촬영 권장"
            }
        case "overlap":
            switch quality.overlapState {
            case .good: return "안정적"
            case .weak: return "보통"
            case .lost: return "추가 촬영 권장"
            case .notAvailable: return "—"
            }
        case "sharpness":
            switch quality.sharpnessState {
            case .sharp: return "좋음"
            case .acceptable: return "보통"
            case .blurry: return "추가 촬영 권장"
            case .unknown: return "—"
            }
        case "tracking":
            return quality.trackingQuality >= 0.7 ? "안정적" : "추가 촬영 권장"
        default:
            return "—"
        }
    }
}
