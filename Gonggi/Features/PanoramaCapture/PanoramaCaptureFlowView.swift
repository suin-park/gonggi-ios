import SwiftUI

/// Full-screen horizontal panorama capture flow (independent from Quick360).
struct PanoramaCaptureFlowView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = PanoramaCaptureViewModel()
    @State private var showSummary = false
    let onClose: () -> Void

    var body: some View {
        ZStack {
            if viewModel.useMockCamera {
                LinearGradient(
                    colors: [
                        Color(red: 0.12, green: 0.16, blue: 0.22),
                        Color(red: 0.05, green: 0.07, blue: 0.10)
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

            PanoramaCaptureOverlayView(viewModel: viewModel, onClose: onClose)

            if case .composing = viewModel.phase {
                Color.black.opacity(0.45).ignoresSafeArea()
                VStack(spacing: GonggiSpacing.sm) {
                    ProgressView().tint(GonggiColors.accentCyan)
                    Text("파노라마 생성 중…")
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.textSecondary)
                }
            }

            if case .failed(let msg) = viewModel.phase {
                VStack {
                    Spacer()
                    Text(msg)
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.error)
                        .padding()
                        .background(Color.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding()
                }
            }
        }
        .onAppear {
            viewModel.configure(mockMode: appState.isMockMode)
        }
        .onChange(of: viewModel.phase) { _, newValue in
            if case .preview = newValue, viewModel.result != nil {
                showSummary = true
            }
        }
        .fullScreenCover(isPresented: $showSummary) {
            if let result = viewModel.result {
                PanoramaCaptureSummaryView(
                    result: result,
                    onRetake: {
                        showSummary = false
                        viewModel.retake()
                    },
                    onDone: {
                        showSummary = false
                        viewModel.close()
                        onClose()
                    }
                )
            }
        }
        .statusBarHidden(true)
    }
}
