import SwiftUI

/// Full-screen 20-direction auto capture → enqueue async generation → home.
struct DirectionCaptureView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = DirectionCaptureViewModel()
    let onClose: () -> Void
    /// When set, caller owns generation enqueue (Build 72 Space Link).
    var onCaptureCompleted: ((DirectionCaptureResult) -> Void)? = nil

    var body: some View {
        ZStack {
            if viewModel.useMockCamera {
                LinearGradient(
                    colors: [
                        Color(red: 0.10, green: 0.14, blue: 0.18),
                        Color(red: 0.04, green: 0.06, blue: 0.08)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                Text("Mock 카메라")
                    .font(GonggiTypography.caption(12))
                    .foregroundStyle(GonggiColors.textTertiary)
            } else {
                PanoramaCaptureCameraPreview(session: viewModel.engine.session)
                    .ignoresSafeArea()
            }

            overlay

            if case .failed(let msg) = viewModel.phase {
                VStack {
                    Spacer()
                    Text(msg)
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.error)
                        .padding()
                        .background(Color.black.opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding()
                }
            }
        }
        .onAppear {
            viewModel.configure(mockMode: appState.isMockMode)
        }
        .onChange(of: viewModel.didComplete) { _, done in
            guard done, let result = viewModel.result else { return }
            if let onCaptureCompleted {
                onCaptureCompleted(result)
            } else {
                appState.startSpaceGeneration(from: result)
            }
            viewModel.close()
            onClose()
        }
        .statusBarHidden(true)
    }

    private var overlay: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    GonggiHaptics.light()
                    viewModel.close()
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Circle())
                }
                Spacer()
                Text(viewModel.progressText)
                    .font(GonggiTypography.body(16))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            guidanceBanner
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .allowsHitTesting(false)

            #if DEBUG
            Text("\(viewModel.yawDisplay) · \(viewModel.pitchDisplay)")
                .font(GonggiTypography.caption(11))
                .foregroundStyle(.white.opacity(0.65))
                .padding(.top, 6)
            #endif

            Spacer()

            bottomBar
                .padding(.bottom, 28)
        }
    }

    /// Large, high-contrast coach for phase title + live guide (TestFlight: hard to read at 14pt).
    private var guidanceBanner: some View {
        VStack(spacing: 10) {
            Text(viewModel.isPhotoPending ? "촬영 중…" : viewModel.phaseTitle)
                .font(GonggiTypography.display(28))
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.85)
                .lineLimit(2)

            if !viewModel.guideText.isEmpty, !viewModel.isPhotoPending {
                Text(viewModel.guideText)
                    .font(GonggiTypography.headline(20))
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(GonggiColors.accentTeal.opacity(0.55), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            viewModel.isPhotoPending
                ? "촬영 중"
                : "\(viewModel.phaseTitle). \(viewModel.guideText)"
        )
    }

    private var bottomBar: some View {
        Group {
            switch viewModel.phase {
            case .idle, .ready, .failed:
                Button {
                    viewModel.startCapture()
                } label: {
                    Text("공간 기록 시작")
                        .font(GonggiTypography.body(17))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(GonggiColors.accentTeal)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 24)
            default:
                Text("계속 움직여도 됩니다 · 자동 촬영 중")
                    .font(GonggiTypography.caption(12))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }
}
