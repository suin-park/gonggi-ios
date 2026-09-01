import SwiftUI

struct PrimaryButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: GonggiSpacing.xs) {
                if let icon { Image(systemName: icon) }
                Text(title)
                    .font(GonggiTypography.headline(17))
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(GonggiColors.backgroundPrimary)
            .background(
                LinearGradient(
                    colors: [GonggiColors.accentCyan, GonggiColors.accentTeal],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
        }
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
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(GonggiColors.textPrimary)
            .background(GonggiColors.surface.opacity(0.6))
            .overlay(
                RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                    .stroke(GonggiColors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
        }
        .accessibilityLabel(title)
    }
}

struct GlassCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(GonggiSpacing.md)
            .background(.ultraThinMaterial)
            .background(GonggiColors.surface.opacity(0.55))
            .overlay(
                RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                    .stroke(GonggiColors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
    }
}

struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 10
    var label: String? = nil

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, progress))
                .stroke(
                    GonggiColors.progressGradient(fraction: progress),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.35), value: progress)
            VStack(spacing: 2) {
                Text("\(Int(progress * 100))%")
                    .font(GonggiTypography.headline(22))
                    .foregroundStyle(GonggiColors.textPrimary)
                if let label {
                    Text(label)
                        .font(GonggiTypography.caption(12))
                        .foregroundStyle(GonggiColors.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("스캔 진행률 \(Int(progress * 100))퍼센트")
    }
}

struct StatusStepRow: View {
    let step: ProcessingStepState

    var body: some View {
        HStack(spacing: GonggiSpacing.sm) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(step.kind.title)
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textPrimary)
                Text(statusText)
                    .font(GonggiTypography.caption(12))
                    .foregroundStyle(GonggiColors.textSecondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.kind.title), \(statusText)")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch step.status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(GonggiColors.successGreen)
        case .active:
            ProgressView()
                .tint(GonggiColors.accentCyan)
        case .waiting:
            Image(systemName: "circle")
                .foregroundStyle(GonggiColors.textSecondary)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(GonggiColors.error)
        }
    }

    private var statusText: String {
        switch step.status {
        case .waiting: return "대기 중"
        case .completed: return "완료"
        case .failed(let msg): return msg
        case .active(let p):
            if let p { return "\(Int(p * 100))%" }
            return "진행 중"
        }
    }
}

struct CoverageLegend: View {
    var body: some View {
        HStack(spacing: GonggiSpacing.sm) {
            legendItem(state: .good, text: "충분")
            legendItem(state: .insufficient, text: "보강")
        }
        .padding(.horizontal, GonggiSpacing.sm)
        .padding(.vertical, GonggiSpacing.xs)
        .background(Color.black.opacity(0.45))
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("커버리지 범례. 초록색 충분, 청록색 보강 필요")
    }

    private func legendItem(state: CoverageState, text: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(GonggiColors.coverageColor(for: state))
                .frame(width: 8, height: 8)
            Text(text)
                .font(GonggiTypography.caption(11))
                .foregroundStyle(GonggiColors.textPrimary)
        }
    }
}

struct CaptureCoachBubble: View {
    let message: String

    var body: some View {
        Text(message)
            .font(GonggiTypography.body(15))
            .multilineTextAlignment(.center)
            .foregroundStyle(GonggiColors.textPrimary)
            .padding(.horizontal, GonggiSpacing.lg)
            .padding(.vertical, GonggiSpacing.sm)
            .background(.ultraThinMaterial)
            .background(GonggiColors.backgroundElevated.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: GonggiRadius.lg, style: .continuous)
                    .stroke(GonggiColors.accentCyan.opacity(0.35), lineWidth: 1)
            )
            .accessibilityLabel("촬영 안내. \(message)")
    }
}

struct SpaceCard: View {
    let space: SpaceRecord
    var onOpen: () -> Void
    var onMore: () -> Void

    var body: some View {
        GlassCard {
            HStack(alignment: .top, spacing: GonggiSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous)
                        .fill(GonggiColors.backgroundElevated)
                        .frame(width: 72, height: 72)
                    Image(systemName: space.thumbnailSystemImage)
                        .font(.system(size: 28))
                        .foregroundStyle(GonggiColors.accentCyan)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
                    Text(space.name)
                        .font(GonggiTypography.headline(17))
                        .foregroundStyle(GonggiColors.textPrimary)
                    Text(space.capturedAt, style: .date)
                        .font(GonggiTypography.caption(12))
                        .foregroundStyle(GonggiColors.textSecondary)
                    HStack(spacing: 4) {
                        Image(systemName: statusIcon)
                        Text(space.status.label)
                    }
                    .font(GonggiTypography.caption(12))
                    .foregroundStyle(statusColor)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: GonggiSpacing.sm) {
                Button("공간 보기", action: onOpen)
                    .font(GonggiTypography.caption(14))
                    .foregroundStyle(GonggiColors.accentCyan)
                    .frame(minHeight: 44)
                Spacer()
                Button(action: onMore) {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                }
                .foregroundStyle(GonggiColors.textSecondary)
                .accessibilityLabel("더보기")
            }
        }
    }

    private var statusIcon: String {
        switch space.status {
        case .ready: return "checkmark.circle.fill"
        case .processing, .uploading: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        case .draft: return "clock"
        }
    }

    private var statusColor: Color {
        switch space.status {
        case .ready: return GonggiColors.successGreen
        case .failed: return GonggiColors.error
        default: return GonggiColors.accentCyan
        }
    }
}
