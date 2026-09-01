import SwiftUI

// MARK: - Buttons

struct PrimaryButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button {
            GonggiHaptics.light()
            action()
        } label: {
            HStack(spacing: GonggiSpacing.xs) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                }
                Text(title)
                    .font(GonggiTypography.headline(17))
            }
            .frame(maxWidth: .infinity, minHeight: GonggiSpacing.touchTarget + 8)
            .foregroundStyle(GonggiColors.backgroundPrimary)
            .background(
                LinearGradient(
                    colors: [GonggiColors.accentTeal, GonggiColors.accentCyan.opacity(0.85)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
            .shadow(color: GonggiColors.accentTeal.opacity(0.25), radius: 12, y: 4)
        }
        .buttonStyle(GonggiPressableStyle())
        .accessibilityLabel(title)
    }
}

struct SecondaryButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: GonggiSpacing.xs) {
                if let icon { Image(systemName: icon) }
                Text(title)
                    .font(GonggiTypography.headline(16))
            }
            .frame(maxWidth: .infinity, minHeight: GonggiSpacing.touchTarget + 8)
            .foregroundStyle(GonggiColors.textPrimary)
            .background(GonggiColors.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                    .stroke(GonggiColors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
        }
        .buttonStyle(GonggiPressableStyle())
        .accessibilityLabel(title)
    }
}

struct GonggiIconButton: View {
    let systemName: String
    var size: CGFloat = GonggiSpacing.touchTarget
    var style: IconStyle = .dimmed
    let action: () -> Void

    enum IconStyle {
        case dimmed, clear, prominent

        var background: Color {
            switch self {
            case .dimmed: return Color.black.opacity(0.42)
            case .clear: return Color.clear
            case .prominent: return GonggiColors.surfaceElevated.opacity(0.85)
            }
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(GonggiColors.textPrimary)
                .frame(width: size, height: size)
                .background(style == .clear ? nil : Circle().fill(style.background))
        }
        .buttonStyle(GonggiPressableStyle(scale: 0.94))
    }
}

// MARK: - Surfaces

struct GonggiElevatedCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(GonggiSpacing.md)
            .background(GonggiColors.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                    .stroke(GonggiColors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
    }
}

/// Legacy alias — uses elevated surface instead of heavy blur.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GonggiElevatedCard(content: content)
    }
}

struct GonggiGlassCapsule: View {
    let message: String
    var accent: Color = GonggiColors.accentTeal

    var body: some View {
        Text(message)
            .font(GonggiTypography.body(15))
            .multilineTextAlignment(.center)
            .foregroundStyle(GonggiColors.textPrimary)
            .padding(.horizontal, GonggiSpacing.lg)
            .padding(.vertical, GonggiSpacing.sm + 2)
            .background(
                Capsule()
                    .fill(GonggiColors.backgroundElevated.opacity(0.72))
                    .background(.ultraThinMaterial, in: Capsule())
            )
            .overlay(
                Capsule()
                    .stroke(accent.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
            .accessibilityLabel("촬영 안내. \(message)")
    }
}

// MARK: - Capture

struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 8
    var label: String? = nil
    var compact: Bool = false
    var emphasis: CaptureProgressEmphasis = .progressing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, progress))
                .stroke(
                    GonggiColors.progressGradient(fraction: progress, emphasis: emphasis),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : GonggiMotion.standard, value: progress)

            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(progress * 100))")
                        .font(compact ? GonggiTypography.headline(20) : GonggiTypography.display(28))
                    Text("%")
                        .font(GonggiTypography.caption(compact ? 11 : 13))
                }
                .foregroundStyle(GonggiColors.textPrimary)

                if let label {
                    Text(label)
                        .font(GonggiTypography.label(11))
                        .foregroundStyle(GonggiColors.textTertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("스캔 진행률 \(Int(progress * 100))퍼센트")
    }
}

struct CaptureFinishPillButton: View {
    let isReady: Bool
    let action: () -> Void

    var body: some View {
        Button {
            GonggiHaptics.medium()
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isReady ? "checkmark.circle.fill" : "stop.circle")
                    .font(.system(size: 15, weight: .semibold))
                Text("촬영 완료")
                    .font(GonggiTypography.headline(15))
            }
            .foregroundStyle(isReady ? GonggiColors.backgroundPrimary : GonggiColors.textPrimary)
            .padding(.horizontal, GonggiSpacing.md)
            .frame(minHeight: GonggiSpacing.touchTarget)
            .background(
                Capsule().fill(
                    isReady
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [GonggiColors.successGreen, GonggiColors.accentTeal],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        : AnyShapeStyle(GonggiColors.surfaceElevated.opacity(0.92))
                )
            )
            .overlay(
                Capsule().stroke(
                    isReady ? GonggiColors.successGreen.opacity(0.5) : GonggiColors.border,
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(GonggiPressableStyle(scale: 0.97))
        .accessibilityLabel(isReady ? "촬영 완료. 충분히 기록되었습니다" : "촬영 완료")
    }
}

struct CaptureControlBar: View {
    let progress: Double
    let emphasis: CaptureProgressEmphasis
    let isReady: Bool
    let isFlashOn: Bool
    let showGuideOverlay: Bool
    let onFlash: () -> Void
    let onFinish: () -> Void
    let onGuide: () -> Void

    var body: some View {
        HStack(spacing: GonggiSpacing.sm) {
            GonggiIconButton(
                systemName: isFlashOn ? "bolt.fill" : "bolt.slash.fill",
                size: 40,
                style: .dimmed,
                action: onFlash
            )
            .accessibilityLabel(isFlashOn ? "플래시 끄기" : "플래시 켜기")

            ProgressRing(
                progress: progress,
                lineWidth: 5,
                label: nil,
                compact: true,
                emphasis: emphasis
            )
            .frame(width: 56, height: 56)

            CaptureFinishPillButton(isReady: isReady, action: onFinish)

            GonggiIconButton(
                systemName: showGuideOverlay ? "map.fill" : "map",
                size: 40,
                style: .dimmed,
                action: onGuide
            )
            .accessibilityLabel("가이드 오버레이")
        }
        .padding(.horizontal, GonggiSpacing.sm)
        .padding(.vertical, GonggiSpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: GonggiRadius.lg, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GonggiRadius.lg, style: .continuous)
                .stroke(GonggiColors.borderSubtle, lineWidth: 1)
        )
    }
}

struct CaptureFinishButton: View {
    let action: () -> Void

    var body: some View {
        Button {
            GonggiHaptics.medium()
            action()
        } label: {
            ZStack {
                Circle()
                    .stroke(GonggiColors.textPrimary.opacity(0.9), lineWidth: 3)
                    .frame(width: 72, height: 72)
                Circle()
                    .fill(GonggiColors.accentTeal)
                    .frame(width: 58, height: 58)
                Text("완료")
                    .font(GonggiTypography.headline(15))
                    .foregroundStyle(GonggiColors.backgroundPrimary)
            }
        }
        .buttonStyle(GonggiPressableStyle(scale: 0.95))
        .accessibilityLabel("촬영 완료")
    }
}

struct CoverageLegend: View {
    var compact: Bool = false

    var body: some View {
        HStack(spacing: compact ? GonggiSpacing.xs : GonggiSpacing.sm) {
            legendDot(color: GonggiColors.successGreen, text: "충분")
            legendDot(color: GonggiColors.accentCyan, text: "보강")
        }
        .padding(.horizontal, GonggiSpacing.sm)
        .padding(.vertical, GonggiSpacing.xs)
        .background(GonggiColors.backgroundElevated.opacity(0.75))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(GonggiColors.borderSubtle, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("커버리지 범례. 초록 충분, 청록 보강 필요")
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(GonggiTypography.label(compact ? 10 : 11))
                .foregroundStyle(GonggiColors.textSecondary)
        }
    }
}

struct CaptureCoachBubble: View {
    let presentation: CaptureCoachPresentation

    init(presentation: CaptureCoachPresentation) {
        self.presentation = presentation
    }

    /// Legacy single-line message — mapped to guidance severity.
    init(message: String) {
        self.presentation = CaptureCoachPresentation(
            title: message,
            subtitle: nil,
            severity: .guidance,
            icon: "viewfinder",
            warning: nil
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: GonggiSpacing.sm) {
            Image(systemName: presentation.icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(presentation.severity.iconTint)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(GonggiTypography.headline(16))
                    .foregroundStyle(GonggiColors.textPrimary)
                if let subtitle = presentation.subtitle {
                    Text(subtitle)
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.textSecondary)
                        .lineSpacing(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, GonggiSpacing.md)
        .padding(.vertical, GonggiSpacing.sm + 2)
        .background(
            RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                .fill(Color.black.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                .stroke(presentation.severity.accent.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if let subtitle = presentation.subtitle {
            return "\(presentation.title). \(subtitle)"
        }
        return presentation.title
    }
}

// MARK: - Processing

struct StatusStepRow: View {
    let step: ProcessingStepState
    var isLast: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: GonggiSpacing.md) {
            stepperRail
            VStack(alignment: .leading, spacing: GonggiSpacing.xxs) {
                Text(step.kind.friendlyTitle)
                    .font(GonggiTypography.headline(16))
                    .foregroundStyle(isActive ? GonggiColors.textPrimary : GonggiColors.textSecondary)
                Text(statusText)
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.kind.friendlyTitle), \(statusText)")
    }

    private var isActive: Bool {
        if case .active = step.status { return true }
        if case .completed = step.status { return true }
        return false
    }

    @ViewBuilder
    private var stepperRail: some View {
        VStack(spacing: 0) {
            statusIcon
                .frame(width: 28, height: 28)
            if !isLast {
                Rectangle()
                    .fill(stepConnectorColor)
                    .frame(width: 2, height: 28)
            }
        }
    }

    private var stepConnectorColor: Color {
        if case .completed = step.status { return GonggiColors.accentTeal.opacity(0.5) }
        return GonggiColors.borderSubtle
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch step.status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(GonggiColors.successGreen)
                .font(.system(size: 22))
        case .active:
            ZStack {
                Circle().stroke(GonggiColors.accentTeal, lineWidth: 2)
                Circle().fill(GonggiColors.accentTeal).frame(width: 8, height: 8)
            }
            .frame(width: 22, height: 22)
        case .waiting:
            Circle()
                .stroke(GonggiColors.border, lineWidth: 2)
                .frame(width: 22, height: 22)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(GonggiColors.error)
                .font(.system(size: 22))
        }
    }

    private var statusText: String {
        switch step.status {
        case .waiting: return "곧 시작됩니다"
        case .completed: return "완료"
        case .failed(let msg): return msg
        case .active(let p):
            if let p { return "\(Int(p * 100))% 진행 중" }
            return "진행 중"
        }
    }
}

// MARK: - Library

struct MemoryArchiveCard: View {
    let space: SpaceRecord
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                thumbnailHero
                VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
                    HStack {
                        Text(space.name)
                            .font(GonggiTypography.headline(18))
                            .foregroundStyle(GonggiColors.textPrimary)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        statusChip
                    }
                    Text(space.capturedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.textTertiary)
                    if let note = space.note, !note.isEmpty {
                        Text(note)
                            .font(GonggiTypography.caption(13))
                            .foregroundStyle(GonggiColors.textSecondary)
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                    HStack {
                        Text("공간 보기")
                            .font(GonggiTypography.caption(14))
                            .foregroundStyle(GonggiColors.accentTeal)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(GonggiColors.accentTeal)
                    }
                    .padding(.top, GonggiSpacing.xs)
                }
                .padding(GonggiSpacing.md)
            }
            .background(GonggiColors.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: GonggiRadius.lg, style: .continuous)
                    .stroke(GonggiColors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.lg, style: .continuous))
        }
        .buttonStyle(GonggiPressableStyle(scale: 0.98))
        .accessibilityLabel("\(space.name), \(space.capturedAt.formatted(date: .abbreviated, time: .omitted)), \(space.status.label)")
    }

    private var thumbnailHero: some View {
        ZStack {
            LinearGradient(
                colors: [
                    GonggiColors.backgroundElevated,
                    GonggiColors.surface,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [GonggiColors.accentCyan.opacity(0.2), .clear],
                center: .center,
                startRadius: 10,
                endRadius: 120
            )
            Image(systemName: space.thumbnailSystemImage)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(GonggiColors.textPrimary.opacity(0.85))
        }
        .frame(height: 160)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private var statusChip: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(GonggiColors.statusColor(for: space.status))
                .frame(width: 6, height: 6)
            Text(space.status.label)
                .font(GonggiTypography.label(11))
                .foregroundStyle(GonggiColors.statusColor(for: space.status))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(GonggiColors.backgroundPrimary.opacity(0.5))
        .clipShape(Capsule())
    }
}

/// Legacy list card — redirects to memory style in new library.
struct SpaceCard: View {
    let space: SpaceRecord
    var onOpen: () -> Void
    var onMore: () -> Void

    var body: some View {
        MemoryArchiveCard(space: space, onOpen: onOpen)
    }
}

// MARK: - Summary metrics

struct GonggiMetricTile: View {
    let icon: String
    let title: String
    let value: String
    var accent: Color = GonggiColors.accentTeal
    var warning: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(warning ? GonggiColors.warning : accent)
            Text(title)
                .font(GonggiTypography.label(11))
                .foregroundStyle(GonggiColors.textTertiary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Text(value)
                .font(GonggiTypography.headline(18))
                .foregroundStyle(GonggiColors.textPrimary)
                .minimumScaleFactor(0.8)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(GonggiSpacing.md)
        .background(GonggiColors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                .stroke(GonggiColors.borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)")
    }
}

struct GonggiSummaryHero: View {
    let coveragePercent: Int
    let qualityLabel: String
    let duration: String

    var body: some View {
        HStack(spacing: GonggiSpacing.lg) {
            ProgressRing(progress: Double(coveragePercent) / 100, lineWidth: 7, compact: true)
                .frame(width: 88, height: 88)
            VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
                Label("촬영이 완료되었어요", systemImage: "checkmark.seal.fill")
                    .font(GonggiTypography.headline(17))
                    .foregroundStyle(GonggiColors.successGreen)
                Text("품질 \(qualityLabel) · \(duration)")
                    .font(GonggiTypography.caption(14))
                    .foregroundStyle(GonggiColors.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(GonggiSpacing.md)
        .background(GonggiColors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: GonggiRadius.lg, style: .continuous)
                .stroke(GonggiColors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.lg, style: .continuous))
    }
}
