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
                CaptureReadyCanvasBackdrop()
                if let sphere = viewModel.spherePreview {
                    Image(uiImage: sphere)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .opacity(0.88)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                productionOverlay
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
                .ignoresSafeArea()
                #if DEBUG
                if sphereDisplayDebugMode == .raw2D {
                    rawEquirectDebugOverlay
                }
                #endif
                productionOverlay
            }

            if viewModel.isStopping || viewModel.isStitching {
                CaptureProcessingOverlay(
                    message: viewModel.isStitching ? "기록을 정리하고 있어요" : "촬영을 마무리하고 있어요",
                    detail: viewModel.isStitching
                        ? "공간 미리보기를 준비 중이에요"
                        : "잠시만 기다려 주세요"
                )
            }
        }
        .background(Color.black.ignoresSafeArea())
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
                        {
                            GonggiHaptics.light()
                            showPanoramaViewer = true
                        }
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
    private var rawEquirectDebugOverlay: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 8) {
                if let source = viewModel.cameraSourcePreview {
                    Text("brush source")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                    Image(uiImage: source)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxHeight: 120)
                        .padding(.horizontal, 12)
                }
                Text("RAW EQUIRECT")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.cyan)
                if let sphere = viewModel.spherePreview {
                    Image(uiImage: sphere)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(.horizontal, 12)
                }
            }
            .padding(.top, 52)
        }
        .allowsHitTesting(false)
    }
    #endif

    private var splitDebugStack: some View {
        ZStack {
            if viewModel.useMockCamera {
                CaptureReadyCanvasBackdrop()
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
            cameraSourcePreview: viewModel.cameraSourcePreview,
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
                #if DEBUG
                sphereDisplayDebugMode = sphereDisplayDebugMode == .sphere ? .raw2D : .sphere
                Quick360Log.stage("sphereDisplayMode → \(sphereDisplayDebugMode.label)")
                #endif
            },
            sphereDisplayDebugLabel: {
                #if DEBUG
                return sphereDisplayDebugMode.label
                #else
                return nil
                #endif
            }()
        )
    }
}

#Preview {
    Quick360FlowView(onClose: {})
        .environmentObject(AppState(isMockMode: true))
}
