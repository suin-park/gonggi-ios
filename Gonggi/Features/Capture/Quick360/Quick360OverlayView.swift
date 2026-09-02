import SwiftUI

/// Minimal overlay for guided Quick 360 capture.
struct Quick360OverlayView: View {
    let uiState: Quick360CaptureUIState
    let onClose: () -> Void
    let onFinish: () -> Void

    var body: some View {
        ZStack {
            VStack {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.45))
                            .clipShape(Circle())
                    }
                    Spacer()
                    if uiState.isComplete || uiState.progressPercent >= 80 {
                        Button(action: onFinish) {
                            Text("완료")
                                .font(GonggiTypography.body(15))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(GonggiColors.accentTeal)
                                .clipShape(Capsule())
                        }
                    }
                }
                .padding(.horizontal, GonggiSpacing.lg)
                .padding(.top, GonggiSpacing.md)

                Spacer()

                targetIndicator

                VStack(spacing: GonggiSpacing.sm) {
                    Text(uiState.guidance.primaryText)
                        .font(GonggiTypography.title(22))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black.opacity(0.5), radius: 4)

                    if let msg = uiState.translationLevel.guidanceMessage {
                        Text(msg)
                            .font(GonggiTypography.caption(13))
                            .foregroundStyle(GonggiColors.warning)
                    }

                    Text("\(uiState.progressPercent)% 완료")
                        .font(GonggiTypography.body(16))
                        .foregroundStyle(GonggiColors.accentCyan)

                    Text("\(uiState.selectedCount) / \(uiState.totalTargets) 타겟")
                        .font(GonggiTypography.caption(12))
                        .foregroundStyle(GonggiColors.textTertiary)
                }
                .padding(.bottom, GonggiSpacing.xl)
            }
        }
    }

    private var targetIndicator: some View {
        ZStack {
            Circle()
                .strokeBorder(.white.opacity(0.35), lineWidth: 2)
                .frame(width: 88, height: 88)
            Circle()
                .fill(GonggiColors.accentCyan.opacity(0.25))
                .frame(width: 16, height: 16)
            if uiState.guidance == .success {
                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(GonggiColors.accentTeal)
            }
        }
        .padding(.bottom, GonggiSpacing.lg)
    }
}

#Preview {
    ZStack {
        Color.black
        Quick360OverlayView(
            uiState: Quick360CaptureUIState(
                progressPercent: 38,
                guidance: .rotateRight,
                translationLevel: .safe,
                currentTarget: Quick360SphericalTarget(id: 0, yawDeg: 90, pitchDeg: 0, state: .accumulating),
                selectedCount: 10,
                totalTargets: 24,
                isComplete: false
            ),
            onClose: {},
            onFinish: {}
        )
    }
}
