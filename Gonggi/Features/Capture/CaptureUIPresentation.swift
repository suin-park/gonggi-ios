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
        case .trackingRecovery, .returnToPreviousArea, .slowDown, .holdSteady,
             .improveBaseline, .moveLaterally, .lowTextureWarning:
            return true
        case .continueCapture, .moveForward, .scanNewArea,
             .captureNearlyComplete, .captureComplete:
            return false
        }
    }

    static func statusLabel(for state: CaptureCompletionState) -> String {
        switch state {
        case .notReady: return "공간 기록 중"
        case .nearlyReady: return "거의 다 기록했어요"
        case .ready: return "3D 공간을 만들 준비가 됐어요"
        }
    }

    static func finishButtonTitle(isReady: Bool) -> String {
        isReady ? "기록 완료" : "촬영 종료"
    }

    static func direction(for action: GuidanceAction) -> PrimaryGuidanceDirection {
        switch action {
        case .moveForward: return .forward
        case .returnToPreviousArea: return .returnBack
        default: return .none
        }
    }

    static func severity(for action: GuidanceAction, warning: CaptureWarningKind?) -> PrimaryGuidanceSeverity {
        if warning == .trackingLimited || warning == .overlapWeak { return .critical }
        switch action {
        case .trackingRecovery, .returnToPreviousArea:
            return .critical
        case .slowDown, .holdSteady, .lowTextureWarning, .improveBaseline, .moveLaterally, .scanNewArea:
            return .warning
        default:
            return .normal
        }
    }

    /// Ring shows completion progress only — never repeats live action icons from the coach card.
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
        let ready = quality.completionState == .ready
        let ring = min(1, max(0, quality.qualityCoverage))

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

        let status = statusLabel(for: quality.completionState)

        // Completion ready — only when no live correction is active.
        if ready {
            return PrimaryGuidanceState(
                action: .captureComplete,
                title: "3D 공간을 만들 준비가 됐어요",
                subtitle: "원하면 지금 마무리할 수 있어요",
                direction: .none,
                severity: .normal,
                statusLabel: status,
                finishButtonTitle: finishButtonTitle(isReady: true),
                isReadyToFinish: true,
                ringProgress: ring,
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

        // Default phase / continue — one stable line.
        if quality.completionState == .nearlyReady {
            return PrimaryGuidanceState(
                action: .captureNearlyComplete,
                title: "거의 다 기록했어요",
                subtitle: "천천히 이동하며 조금 더 담아주세요",
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
            return ("천천히 이동하며 계속 촬영하세요", "같은 영역을 계속 바라봐주세요")
        case .moveLaterally, .improveBaseline:
            return ("옆으로 조금 이동해주세요", "제자리에서 돌지 마세요")
        case .moveForward:
            return ("천천히 앞으로 이동해주세요", nil)
        case .slowDown:
            return ("조금 천천히 움직여주세요", nil)
        case .holdSteady:
            return ("잠시 천천히 움직여주세요", nil)
        case .returnToPreviousArea:
            return ("방금 촬영한 곳이 다시 보이도록 이동해주세요", "연결을 다시 찾고 있어요")
        case .scanNewArea:
            return ("아직 덜 담긴 영역을 천천히 비춰주세요", nil)
        case .trackingRecovery:
            return ("천천히 주변을 비춰주세요", "카메라 위치를 다시 확인하고 있어요")
        case .lowTextureWarning:
            return ("가구나 모서리도 화면에 함께 담아주세요", nil)
        case .captureNearlyComplete:
            return ("거의 다 기록했어요", "천천히 이동하며 조금 더 담아주세요")
        case .captureComplete:
            return ("3D 공간을 만들 준비가 됐어요", "원하면 지금 마무리할 수 있어요")
        }
    }

    private static func secondaryHint(for action: GuidanceAction) -> String? {
        switch action {
        case .continueCapture, .moveLaterally, .improveBaseline:
            return "같은 영역을 계속 바라봐주세요"
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
