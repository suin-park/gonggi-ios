import SwiftUI

struct PanoramaCaptureOverlayView: View {
    @ObservedObject var viewModel: PanoramaCaptureViewModel
    let onClose: () -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                Spacer()
                guideCluster
                Spacer()
                bottomChrome
            }
            .padding(.horizontal, GonggiSpacing.md)
            .padding(.top, GonggiSpacing.sm)
            .padding(.bottom, GonggiSpacing.lg)

            #if DEBUG
            if PanoramaCaptureConfig.showDebugStripOverlay {
                debugStripBounds
                    .allowsHitTesting(false)
            }
            #endif
        }
    }

    #if DEBUG
    /// Internal compositor strip region — DEBUG only, never shown in Release/TestFlight.
    private var debugStripBounds: some View {
        GeometryReader { geo in
            let stripW = max(2, geo.size.width * 0.04)
            Rectangle()
                .strokeBorder(Color.yellow.opacity(0.55), lineWidth: 1)
                .frame(width: stripW)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .frame(height: geo.size.height * 0.7)
        }
    }
    #endif


    private var topBar: some View {
        HStack {
            Button {
                GonggiHaptics.light()
                viewModel.close()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(GonggiColors.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            }
            Spacer()
            Text("파노라마 기록")
                .font(GonggiTypography.caption(12))
                .foregroundStyle(GonggiColors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
    }

    private var guideCluster: some View {
        VStack(spacing: GonggiSpacing.md) {
            // Horizon guide line
            ZStack {
                Rectangle()
                    .fill(GonggiColors.accentTeal.opacity(0.85))
                    .frame(height: 2)
                    .shadow(color: GonggiColors.accentTeal.opacity(0.5), radius: 6)

                HStack {
                    if viewModel.direction == .left {
                        directionChip
                        Spacer()
                    } else {
                        Spacer()
                        directionChip
                    }
                }
            }
            .frame(height: 28)
            .padding(.horizontal, GonggiSpacing.sm)

            Text(viewModel.feedback.message)
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, GonggiSpacing.lg)
                .padding(.vertical, GonggiSpacing.sm)
                .background(Color.black.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.sm))
        }
    }

    private var directionChip: some View {
        HStack(spacing: 4) {
            Image(systemName: viewModel.direction.arrowSystemImage)
            Text(viewModel.direction.label)
        }
        .font(GonggiTypography.caption(12))
        .foregroundStyle(GonggiColors.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(GonggiColors.accentTeal.opacity(0.85))
        .clipShape(Capsule())
    }

    private var bottomChrome: some View {
        VStack(spacing: GonggiSpacing.md) {
            // Progress
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule()
                            .fill(GonggiColors.accentTeal)
                            .frame(width: max(8, geo.size.width * viewModel.progress))
                    }
                }
                .frame(height: 6)
                HStack {
                    Text(String(format: "회전 %.0f°", viewModel.yawSpanDeg))
                    Spacer()
                    Text(viewModel.phase == .capturing ? "기록 중" : "준비")
                }
                .font(GonggiTypography.caption(11))
                .foregroundStyle(GonggiColors.textSecondary)
            }
            .padding(.horizontal, GonggiSpacing.sm)

            if case .capturing = viewModel.phase, viewModel.enoughForFinish {
                Button {
                    Task { await viewModel.finishCapture() }
                } label: {
                    Text("완료")
                        .font(GonggiTypography.body(15))
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(GonggiColors.accentTeal))
                }
            }

            Button {
                viewModel.toggleCapture()
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.85), lineWidth: 4)
                        .frame(width: 76, height: 76)
                    Circle()
                        .fill(captureButtonFill)
                        .frame(width: 62, height: 62)
                }
            }
            .disabled({
                if case .composing = viewModel.phase { return true }
                if case .preview = viewModel.phase { return true }
                return false
            }())

            Text(bottomHint)
                .font(GonggiTypography.caption(12))
                .foregroundStyle(GonggiColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, GonggiSpacing.md)
        .padding(.bottom, GonggiSpacing.sm)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [.clear, Color.black.opacity(0.55), Color.black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private var captureButtonFill: Color {
        switch viewModel.phase {
        case .capturing: return GonggiColors.error
        case .composing: return GonggiColors.textTertiary
        default: return GonggiColors.accentTeal
        }
    }

    private var bottomHint: String {
        switch viewModel.phase {
        case .capturing:
            return "제자리에서 천천히 회전 · 다시 누르면 생성"
        case .composing:
            return "파노라마 생성 중…"
        default:
            return "가이드 선을 유지하면 더 자연스럽게 이어져요"
        }
    }
}
