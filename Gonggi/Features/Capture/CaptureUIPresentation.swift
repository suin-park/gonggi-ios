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

struct CaptureCoachPresentation: Equatable {
    let title: String
    let subtitle: String?
    let severity: CaptureCoachSeverity
    let icon: String
    let warning: CaptureWarningKind?
}

enum CaptureUIPresenter {
    /// Highest-priority active warning for chips (problem-only).
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

    static func coachPresentation(
        quality: CaptureQualityState,
        fallbackMessage: String
    ) -> CaptureCoachPresentation {
        // Live guidance action wins over Astra fallback copy.
        let action = quality.guidanceAction
        let title = CaptureGuidanceCopy.message(for: action)

        if let warning = warningKind(for: quality) {
            let severity: CaptureCoachSeverity = (warning == .trackingLimited || warning == .overlapWeak)
                ? .critical : .warning
            return CaptureCoachPresentation(
                title: title,
                subtitle: phaseSubtitle(quality.capturePhase, fallback: fallbackMessage),
                severity: severity,
                icon: warning.icon,
                warning: warning
            )
        }

        switch quality.completionState {
        case .ready:
            return CaptureCoachPresentation(
                title: CaptureGuidanceCopy.message(for: .captureComplete),
                subtitle: "원하면 지금 마무리할 수 있어요",
                severity: .good,
                icon: "checkmark.circle.fill",
                warning: nil
            )
        case .nearlyReady:
            return CaptureCoachPresentation(
                title: CaptureGuidanceCopy.message(for: .captureNearlyComplete),
                subtitle: quality.capturePhase.userLabel,
                severity: .good,
                icon: "checkmark.circle",
                warning: nil
            )
        case .notReady:
            if action == .continueCapture {
                return CaptureCoachPresentation(
                    title: title,
                    subtitle: quality.capturePhase.userLabel,
                    severity: .guidance,
                    icon: "figure.walk",
                    warning: nil
                )
            }
            return CaptureCoachPresentation(
                title: title,
                subtitle: phaseSubtitle(quality.capturePhase, fallback: fallbackMessage),
                severity: .guidance,
                icon: "viewfinder",
                warning: nil
            )
        }
    }

    private static func phaseSubtitle(_ phase: CapturePhase, fallback: String) -> String? {
        let label = phase.userLabel
        if fallback.isEmpty || fallback == label { return label }
        return label
    }

    static func isReadyToFinish(_ quality: CaptureQualityState) -> Bool {
        // Completion gate already encodes quality floors; do not auto-stop.
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
