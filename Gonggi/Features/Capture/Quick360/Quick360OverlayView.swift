import SwiftUI

/// Hybrid Space Capture overlay — coverage is shown by in-world sphere/floor paint, not a washed HUD.
struct Quick360OverlayView: View {
    let uiState: Quick360CaptureUIState
    let spherePreview: UIImage?
    let floorPreview: UIImage?
    var brushDebug: Quick360BrushDebugState? = nil
    let onClose: () -> Void
    let onStart: () -> Void
    let onFinish: () -> Void

    var body: some View {
        ZStack {
            VStack {
                topBar
                if let brushDebug {
                    HStack {
                        Text(brushDebug.overlayText)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(8)
                            .background(.black.opacity(0.55))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Spacer()
                    }
                    .padding(.horizontal, GonggiSpacing.lg)
                }
                Spacer()
                if let floorPreview, uiState.floorDetected {
                    floorStrip(floorPreview)
                }
                bottomGuidance
            }
        }
    }

    private var topBar: some View {
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
            if uiState.canFinish {
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
    }

    private func floorStrip(_ image: UIImage) -> some View {
        HStack(spacing: GonggiSpacing.sm) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text("바닥")
                    .font(GonggiTypography.caption(11))
                    .foregroundStyle(GonggiColors.textTertiary)
                Text("\(uiState.floorCoveragePercent)%")
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(.white)
            }
            Spacer()
        }
        .padding(.horizontal, GonggiSpacing.lg)
        .padding(.bottom, GonggiSpacing.sm)
        .allowsHitTesting(false)
    }

    private var bottomGuidance: some View {
        VStack(spacing: GonggiSpacing.sm) {
            Text(uiState.guidance.primaryText)
                .font(GonggiTypography.title(22))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.5), radius: 4)

            // Avoid duplicating the same sentence as title + caption.
            if let msg = uiState.translationLevel.guidanceMessage,
               msg != uiState.guidance.primaryText,
               uiState.guidance != .stayInPlace,
               uiState.guidance != .returnToOrigin,
               uiState.guidance != .holdStill {
                Text(msg)
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.warning)
            }

            if uiState.phase == .capturing || uiState.phase == .complete {
                Text("공간 \(uiState.sphereCoveragePercent)%")
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.textTertiary)
            }

            if uiState.canStart {
                Button(action: onStart) {
                    Text("촬영 시작")
                        .font(GonggiTypography.body(17))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(GonggiColors.accentTeal)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, GonggiSpacing.xl)
                .padding(.top, GonggiSpacing.sm)
            }
        }
        .padding(.bottom, GonggiSpacing.xl)
    }
}

#Preview {
    ZStack {
        Color.black
        Quick360OverlayView(
            uiState: Quick360CaptureUIState(
                phase: .readyToStart,
                progressPercent: 0,
                sphereCoveragePercent: 0,
                floorCoveragePercent: 0,
                floorDetected: false,
                guidance: .readyToStart,
                translationLevel: .safe,
                canStart: true,
                canFinish: false,
                isComplete: false,
                selectedCount: 0,
                totalTargets: 24
            ),
            spherePreview: nil,
            floorPreview: nil,
            onClose: {},
            onStart: {},
            onFinish: {}
        )
    }
}
