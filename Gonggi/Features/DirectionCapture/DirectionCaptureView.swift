import SwiftUI

/// Full-screen 10-direction auto capture (portrait, one start tap).
struct DirectionCaptureView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = DirectionCaptureViewModel()
    @State private var showResult = false
    let onClose: () -> Void

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
            if done, viewModel.result != nil {
                showResult = true
            }
        }
        .fullScreenCover(isPresented: $showResult) {
            if let result = viewModel.result {
                DirectionCaptureResultView(
                    result: result,
                    onRetake: {
                        showResult = false
                        viewModel.retake()
                    },
                    onDone: {
                        showResult = false
                        viewModel.close()
                        onClose()
                    }
                )
            }
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

            if let target = viewModel.currentTarget {
                Text("다음 촬영: \(target.displayLabel)")
                    .font(GonggiTypography.title(22))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
                    .padding(.top, 18)
            }

            Text(viewModel.guideText)
                .font(GonggiTypography.caption(14))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 8)

            Text("\(viewModel.yawDisplay) · \(viewModel.pitchDisplay)")
                .font(GonggiTypography.caption(11))
                .foregroundStyle(.white.opacity(0.65))
                .padding(.top, 6)

            Spacer()

            directionChecklist
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            bottomBar
                .padding(.bottom, 28)
        }
    }

    private var directionChecklist: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            ForEach(DirectionName.captureOrder) { dir in
                HStack(spacing: 6) {
                    Image(systemName: statusIcon(for: dir))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(statusColor(for: dir))
                    Text(dir.rawValue)
                        .font(GonggiTypography.caption(11))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
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

    private func statusIcon(for dir: DirectionName) -> String {
        if viewModel.completed.contains(dir) { return "checkmark.circle.fill" }
        if viewModel.currentTarget == dir { return "arrow.right.circle.fill" }
        return "circle"
    }

    private func statusColor(for dir: DirectionName) -> Color {
        if viewModel.completed.contains(dir) { return GonggiColors.accentTeal }
        if viewModel.currentTarget == dir { return GonggiColors.accentCyan }
        return .white.opacity(0.35)
    }
}
