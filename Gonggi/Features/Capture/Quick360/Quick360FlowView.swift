import SwiftUI

struct Quick360FlowView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = Quick360ViewModel()
    @State private var showSummary = false
    @State private var showPanoramaViewer = false
    let onClose: () -> Void

    var body: some View {
        ZStack {
            if viewModel.useMockCamera {
                mockBackground
                if let sphere = viewModel.spherePreview {
                    Image(uiImage: sphere)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .opacity(0.92)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            } else {
                Quick360ARViewRepresentable(
                    session: viewModel.arSession,
                    engine: viewModel.engine,
                    onPayload: { payload in
                        viewModel.ingestPayload(payload)
                    },
                    onViewReady: {
                        viewModel.onARViewReady()
                    },
                    showDebugFloorMarker: false
                )
                .ignoresSafeArea()
            }

            Quick360OverlayView(
                uiState: viewModel.uiState,
                spherePreview: viewModel.useMockCamera ? nil : viewModel.spherePreview,
                floorPreview: viewModel.floorPreview,
                onClose: {
                    viewModel.cancelCapture()
                    onClose()
                },
                onStart: {
                    viewModel.beginCapture()
                },
                onFinish: {
                    Task {
                        await viewModel.stop()
                        showSummary = true
                    }
                }
            )

            if viewModel.isStopping || viewModel.isStitching {
                Color.black.opacity(0.45).ignoresSafeArea()
                VStack(spacing: GonggiSpacing.sm) {
                    ProgressView()
                        .tint(GonggiColors.accentCyan)
                    Text(viewModel.isStitching ? "파노라마 생성 중…" : "촬영 마무리 중…")
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.textSecondary)
                }
            }
        }
        .onAppear {
            Quick360Log.stage("Quick360FlowView onAppear")
            viewModel.configure(mockMode: appState.isMockMode)
        }
        .sheet(isPresented: $showSummary) {
            if let summary = viewModel.lastSummary {
                Quick360SummaryView(
                    summary: summary,
                    onRetry: {
                        showSummary = false
                        viewModel.start()
                    },
                    onPreview360: summary.panoramaURL.map { _ in
                        { showPanoramaViewer = true }
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .fullScreenCover(isPresented: $showPanoramaViewer) {
            if let url = viewModel.lastSummary?.panoramaURL {
                Panorama360ViewerView(imageURL: url)
            }
        }
    }

    private var mockBackground: some View {
        LinearGradient(
            colors: [Color(white: 0.18), Color(white: 0.08)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

#Preview {
    Quick360FlowView(onClose: {})
        .environmentObject(AppState(isMockMode: true))
}
