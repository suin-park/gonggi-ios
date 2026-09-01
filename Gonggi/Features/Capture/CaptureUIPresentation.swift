import SwiftUI

// MARK: - UI-only presentation (does not alter capture algorithms)

enum CaptureWarningKind: Equatable {
    case fastMovement
    case trackingLimited
    case lowTexture

    var icon: String {
        switch self {
        case .fastMovement: return "hare.fill"
        case .trackingLimited: return "location.slash.fill"
        case .lowTexture: return "square.dashed"
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
    /// Highest-priority active warning for UI semantics (reads existing quality fields only).
    static func warningKind(for quality: CaptureQualityState) -> CaptureWarningKind? {
        if quality.trackingQuality < 0.5 { return .trackingLimited }
        if quality.motionSpeed > 0.7 || quality.blurScore < 0.45 { return .fastMovement }
        if quality.lowTextureScore > 0.6 { return .lowTexture }
        return nil
    }

    static func coachPresentation(
        quality: CaptureQualityState,
        fallbackMessage: String
    ) -> CaptureCoachPresentation {
        if let warning = warningKind(for: quality) {
            switch warning {
            case .fastMovement:
                return CaptureCoachPresentation(
                    title: "조금 천천히 움직여주세요",
                    subtitle: nil,
                    severity: .warning,
                    icon: warning.icon,
                    warning: warning
                )
            case .trackingLimited:
                return CaptureCoachPresentation(
                    title: "카메라 위치를 다시 잡고 있어요",
                    subtitle: "주변의 특징이 보이는 곳을 천천히 비춰주세요",
                    severity: .critical,
                    icon: warning.icon,
                    warning: warning
                )
            case .lowTexture:
                return CaptureCoachPresentation(
                    title: "이 벽은 특징이 적어요",
                    subtitle: "주변 가구나 모서리도 함께 담아주세요",
                    severity: .warning,
                    icon: warning.icon,
                    warning: warning
                )
            }
        }

        let coverage = quality.overallCoverage
        if coverage >= 0.88 {
            return CaptureCoachPresentation(
                title: "거의 다 기록했어요",
                subtitle: "원하면 지금 마무리할 수 있어요",
                severity: .good,
                icon: "checkmark.circle.fill",
                warning: nil
            )
        }
        if coverage >= 0.55 {
            return CaptureCoachPresentation(
                title: "좋아요. 조금만 더 둘러보세요",
                subtitle: "청록 표시 영역을 다른 각도에서 비춰주세요",
                severity: .guidance,
                icon: "arrow.triangle.2.circlepath",
                warning: nil
            )
        }
        if coverage >= 0.35 {
            return CaptureCoachPresentation(
                title: "촬영이 진행 중이에요",
                subtitle: fallbackMessage.isEmpty ? "천천히 움직이며 공간을 더 둘러보세요" : fallbackMessage,
                severity: .guidance,
                icon: "viewfinder",
                warning: nil
            )
        }
        return CaptureCoachPresentation(
            title: "아직 촬영이 부족해요",
            subtitle: "천천히 움직이며 공간을 더 둘러보세요",
            severity: .guidance,
            icon: "viewfinder",
            warning: nil
        )
    }

    static func isReadyToFinish(_ quality: CaptureQualityState) -> Bool {
        quality.overallCoverage >= 0.88 && warningKind(for: quality) == nil
    }

    static func progressEmphasis(for quality: CaptureQualityState) -> CaptureProgressEmphasis {
        if isReadyToFinish(quality) { return .ready }
        if quality.overallCoverage >= 0.55 { return .progressing }
        return .needsWork
    }

    /// Overlay confidence reduction when tracking is limited (visual only).
    static func overlayDimming(for quality: CaptureQualityState) -> Double {
        quality.trackingQuality < 0.5 ? 0.28 : 0
    }
}
