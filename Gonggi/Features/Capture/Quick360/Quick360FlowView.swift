import SwiftUI

struct Quick360FlowView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = Quick360ViewModel()
    @State private var showSummary = false
    @State private var showPanoramaViewer = false
    /// Release TestFlight: compare raw equirect vs inside-out sphere orientation.
    @State private var sphereDisplayDebugMode: Quick360SphereDisplayDebugMode = .sphere
    let onClose: () -> Void

    var body: some View {
        ZStack {
            if viewModel.isSplitDebugMode {
                splitDebugStack
            } else if viewModel.useMockCamera {
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
                productionOverlay
            } else {
                // Full-screen inside-out sphere paint (camera at sphere center).
                Quick360ARViewRepresentable(
                    session: viewModel.arSession,
                    engine: viewModel.engine,
                    onPayload: { payload in
                        viewModel.ingestPayload(payload)
                    },
                    onViewReady: {
                        viewModel.onARViewReady()
                    },
                    showDebugFloorMarker: false,
                    showFloorRenderer: false
                )
                .ignoresSafeArea()
                if sphereDisplayDebugMode == .raw2D {
                    rawEquirectDebugOverlay
                }
                productionOverlay
            }

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
            Quick360Log.stage("Quick360FlowView onAppear splitDebug=\(viewModel.isSplitDebugMode)")
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

    /// Same raw brush equirect pixels as applied to the sphere (no mesh/UV transform).
    private var rawEquirectDebugOverlay: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 8) {
                if let source = viewModel.cameraSourcePreview {
                    Text("brush source (oriented)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                    Image(uiImage: source)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxHeight: 120)
                        .padding(.horizontal, 12)
                }
                Text("RAW EQUIRECT (paint canvas)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.cyan)
                if let sphere = viewModel.spherePreview {
                    Image(uiImage: sphere)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(.horizontal, 12)
                } else {
                    Text("neutral gray — paint 전")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.top, 52)
        }
        .allowsHitTesting(false)
    }

    /// Hidden AR session driver + visible Split Debug panes (DEBUG toggle only).
    private var splitDebugStack: some View {
        ZStack {
            if viewModel.useMockCamera {
                mockBackground
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
                    showDebugFloorMarker: false,
                    showFloorRenderer: false
                )
                .opacity(0.001)
                .allowsHitTesting(false)
                .ignoresSafeArea()
            }

            Quick360SplitDebugView(
                testPhase: viewModel.splitDebugTestPhase,
                sphereImage: viewModel.spherePreview,
                cameraSourceImage: viewModel.cameraSourcePreview,
                brushDebug: viewModel.brushDebug,
                hasCachedFrame: viewModel.hasCachedSplitDebugFrame,
                onClose: {
                    #if DEBUG
                    viewModel.toggleSplitDebugMode()
                    #else
                    viewModel.cancelCapture()
                    onClose()
                    #endif
                },
                onStartTest: {
                    viewModel.runSplitDebugTestA()
                },
                onReset: {
                    viewModel.resetSplitDebugTest()
                },
                onPaintOne: {
                    viewModel.requestSplitDebugPaintOne()
                }
            )
        }
    }

    private var productionOverlay: some View {
        Quick360OverlayView(
            uiState: viewModel.uiState,
            spherePreview: viewModel.useMockCamera ? nil : viewModel.spherePreview,
            floorPreview: nil,
            brushDebug: viewModel.showBrushDebug ? viewModel.brushDebug : nil,
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
            },
            onToggleSplitDebug: {
                #if DEBUG
                viewModel.toggleSplitDebugMode()
                #endif
            },
            onToggleSphereDisplayDebug: {
                sphereDisplayDebugMode = sphereDisplayDebugMode == .sphere ? .raw2D : .sphere
                Quick360Log.stage("sphereDisplayMode → \(sphereDisplayDebugMode.label)")
            },
            sphereDisplayDebugLabel: sphereDisplayDebugMode.label
        )
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
