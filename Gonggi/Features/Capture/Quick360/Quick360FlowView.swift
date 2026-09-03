import SwiftUI

struct Quick360FlowView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = Quick360ViewModel()
    @State private var showSummary = false
    @State private var showPanoramaViewer = false
    #if DEBUG
    @State private var sphereDisplayDebugMode: Quick360SphereDisplayDebugMode = .sphere
    #endif
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
                #if DEBUG
                if sphereDisplayDebugMode == .raw2D {
                    rawEquirectDebugOverlay
                }
                #endif
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

    #if DEBUG
    /// Same raw brush equirect as Split Debug — compare vs inside-out sphere orientation.
    private var rawEquirectDebugOverlay: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let sphere = viewModel.spherePreview {
                Image(uiImage: sphere)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(12)
            } else {
                Text("neutral gray — paint 전 (raw equirect)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
            VStack {
                Text("RAW EQUIRECT (no sphere transform)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.cyan)
                    .padding(8)
                    .background(.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 56)
                Spacer()
            }
        }
        .allowsHitTesting(false)
    }
    #endif

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
            // Floor UI off for this UX validation step (detection/atlas kept in engine).
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
            onToggleSphereDisplayDebug: debugToggleSphereDisplay,
            sphereDisplayDebugLabel: debugSphereDisplayLabel
        )
    }

    #if DEBUG
    private var debugSphereDisplayLabel: String? { sphereDisplayDebugMode.label }

    private var debugToggleSphereDisplay: (() -> Void)? {
        {
            sphereDisplayDebugMode = sphereDisplayDebugMode == .sphere ? .raw2D : .sphere
        }
    }
    #else
    private var debugSphereDisplayLabel: String? { nil }
    private var debugToggleSphereDisplay: (() -> Void)? { nil }
    #endif

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
