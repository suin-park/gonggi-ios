import SwiftUI

/// Capture mode selection — panorama is the primary “공간 기록” path.
/// Quick360 / full-sphere remains available as an experimental entry only.
enum CaptureMode: String, Identifiable {
    case panoramaCapture
    case spaceScan3DGS
    case quick360Experimental

    var id: String { rawValue }

    var title: String {
        switch self {
        case .panoramaCapture: return "파노라마 기록"
        case .spaceScan3DGS: return "공간 스캔 (3DGS)"
        case .quick360Experimental: return "실험 · 360 공간 기록"
        }
    }

    var subtitle: String {
        switch self {
        case .panoramaCapture:
            return "제자리에서 천천히 회전하며 수평 파노라마를 만들어요"
        case .spaceScan3DGS:
            return "이동하며 multi-view 촬영"
        case .quick360Experimental:
            return "실험용 full-sphere / OpenCV A/B (기본 경로 아님)"
        }
    }

    var icon: String {
        switch self {
        case .panoramaCapture: return "pano"
        case .spaceScan3DGS: return "viewfinder"
        case .quick360Experimental: return "globe.americas.fill"
        }
    }

    var isExperimental: Bool {
        self == .quick360Experimental
    }
}

/// Entry for Scan tab — presents mode selection then full-screen capture flow.
struct CaptureContainerView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedMode: CaptureMode?
    @State private var isCapturing = false

    var body: some View {
        NavigationStack {
            ZStack {
                GonggiAmbientBackground()
                if isCapturing, let mode = selectedMode,
                   mode == .spaceScan3DGS {
                    captureFlow(for: mode)
                } else {
                    startPrompt
                }
            }
            .navigationBarHidden(true)
        }
        .fullScreenCover(isPresented: Binding(
            get: { isCapturing && selectedMode == .panoramaCapture },
            set: { presented in
                if !presented {
                    isCapturing = false
                    selectedMode = nil
                }
            }
        )) {
            PanoramaCaptureFlowView(onClose: {
                isCapturing = false
                selectedMode = nil
            })
            .environmentObject(appState)
        }
        // Quick360 kept as experimental full-screen path (not default).
        .fullScreenCover(isPresented: Binding(
            get: { isCapturing && selectedMode == .quick360Experimental },
            set: { presented in
                if !presented {
                    isCapturing = false
                    selectedMode = nil
                }
            }
        )) {
            Quick360FlowView(onClose: {
                isCapturing = false
                selectedMode = nil
            })
            .environmentObject(appState)
        }
    }

    @ViewBuilder
    private func captureFlow(for mode: CaptureMode) -> some View {
        switch mode {
        case .spaceScan3DGS:
            CaptureFlowView(onClose: { isCapturing = false; selectedMode = nil })
        case .panoramaCapture, .quick360Experimental:
            EmptyView()
        }
    }

    private var startPrompt: some View {
        VStack(spacing: GonggiSpacing.xl) {
            Spacer()
            Text("공간 기록")
                .font(GonggiTypography.title(26))
                .foregroundStyle(GonggiColors.textPrimary)
            Text("원하는 기록 방식을 선택하세요")
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.textSecondary)

            VStack(spacing: GonggiSpacing.md) {
                modeCard(.panoramaCapture)
                modeCard(.spaceScan3DGS)
                modeCard(.quick360Experimental)
            }
            .padding(.horizontal, GonggiSpacing.lg)

            if appState.isMockMode {
                Text("Mock 모드 · 파노라마는 합성 회전으로 생성됩니다")
                    .font(GonggiTypography.caption(11))
                    .foregroundStyle(GonggiColors.textTertiary)
            }
            Spacer()
        }
        .padding()
    }

    private func modeCard(_ mode: CaptureMode) -> some View {
        Button {
            GonggiHaptics.medium()
            selectedMode = mode
            isCapturing = true
        } label: {
            HStack(spacing: GonggiSpacing.md) {
                ZStack {
                    Circle()
                        .fill(
                            mode.isExperimental
                                ? GonggiColors.warning.opacity(0.12)
                                : GonggiColors.accentTeal.opacity(0.12)
                        )
                        .frame(width: 52, height: 52)
                    Image(systemName: mode.icon)
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(
                            mode.isExperimental ? GonggiColors.warning : GonggiColors.accentTeal
                        )
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(mode.title)
                            .font(GonggiTypography.body(17))
                            .foregroundStyle(GonggiColors.textPrimary)
                        if mode.isExperimental {
                            Text("실험")
                                .font(GonggiTypography.caption(10))
                                .foregroundStyle(GonggiColors.warning)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(GonggiColors.warning.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                    Text(mode.subtitle)
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(GonggiColors.textTertiary)
            }
            .padding(GonggiSpacing.md)
            .background(GonggiColors.surfaceElevated.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

struct CaptureFlowView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = CaptureViewModel()
    @State private var showSummary = false
    @State private var showProcessing = false
    @State private var showSpacePreview = false
    let onClose: () -> Void

    var body: some View {
        ZStack {
            if viewModel.useMockCamera {
                MockCameraBackground(quality: viewModel.guidance.quality)
            } else {
                ARCaptureViewRepresentable(
                    session: viewModel.arSession,
                    coverageSpatialIndex: viewModel.framePipeline.coverageSpatialIndex,
                    showMeshOverlay: viewModel.guidance.showGuideOverlay
                ) { frame in
                    viewModel.ingestFrame(frame)
                }
                .ignoresSafeArea()
            }

            CaptureOverlayView(
                guidance: viewModel.guidance,
                onClose: {
                    viewModel.cancelCapture()
                    onClose()
                },
                onFinish: {
                    Task {
                        await viewModel.stop()
                        showSummary = true
                    }
                },
                onFlash: { viewModel.guidance.toggleFlash() },
                onGuide: { viewModel.guidance.toggleGuide() }
            )

            if viewModel.isStopping || viewModel.isReconstructingTexturedMesh {
                Color.black.opacity(0.45).ignoresSafeArea()
                VStack(spacing: GonggiSpacing.sm) {
                    ProgressView()
                        .tint(GonggiColors.accentCyan)
                    Text(viewModel.isReconstructingTexturedMesh ? "공간 mesh 재구성 중…" : "촬영 마무리 중…")
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.textSecondary)
                }
            }
        }
        .onAppear { viewModel.configure(mockMode: appState.isMockMode) }
        .sheet(isPresented: $showSummary) {
            if let summary = viewModel.lastSummary {
                CaptureSummaryView(
                    summary: summary,
                    onContinueCapture: { showSummary = false; viewModel.start() },
                    onCreateSpace: {
                        showSummary = false
                        appState.pendingCapture = summary
                        showProcessing = true
                    },
                    onPreviewSpace: summary.texturedSpaceURL.map { url in
                        { showSpacePreview = true }
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .fullScreenCover(isPresented: $showSpacePreview) {
            if let url = viewModel.lastSummary?.texturedSpaceURL {
                SpacePreviewView(usdzURL: url)
            }
        }
        .fullScreenCover(isPresented: $showProcessing) {
            if let summary = appState.pendingCapture {
                ProcessingView(
                    summary: summary,
                    spaceService: appState.spaceService,
                    onComplete: { _, spaceId in
                        appState.addSpace(from: summary, jobId: spaceId)
                        appState.updateSpaceStatus(id: spaceId, status: .ready)
                        onClose()
                        appState.selectTab(.library)
                    },
                    onDismiss: { showProcessing = false }
                )
            }
        }
    }
}

#Preview("Start prompt") {
    CaptureContainerView()
        .environmentObject(AppState(isMockMode: true))
}

#Preview("Capture flow") {
    CaptureFlowView(onClose: {})
        .environmentObject(AppState(isMockMode: true))
}
