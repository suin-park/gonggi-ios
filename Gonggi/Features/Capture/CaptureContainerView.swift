import SwiftUI

/// Capture mode selection.
/// Production Record tab opens DirectionCapture (LatLong) immediately.
/// Other modes remain for DEBUG / internal access only.
enum CaptureMode: String, Identifiable {
    case directionCapture
    case panoramaCapture
    case spaceScan3DGS
    case quick360Experimental

    var id: String { rawValue }

    /// Production default — Record tab enters this mode directly.
    static var productionDefault: CaptureMode { .directionCapture }

    /// DEBUG / internal modes listed under developer section.
    static var debugModes: [CaptureMode] {
        [.spaceScan3DGS, .panoramaCapture, .quick360Experimental]
    }

    /// Legacy alias — production no longer shows a multi-mode picker.
    static var productionModes: [CaptureMode] {
        [.directionCapture]
    }

    var title: String {
        switch self {
        case .directionCapture: return "360 공간 기록"
        case .panoramaCapture: return "파노라마 기록"
        case .spaceScan3DGS: return "3D 공간 스캔"
        case .quick360Experimental: return "실험 · 360 공간 기록"
        }
    }

    var subtitle: String {
        switch self {
        case .directionCapture:
            return "여러 방향을 촬영해 공간을 360°로 기록해요."
        case .panoramaCapture:
            return "제자리에서 천천히 회전하며 수평 파노라마를 만들어요"
        case .spaceScan3DGS:
            return "공간을 입체적으로 스캔해 자유롭게 둘러볼 수 있어요."
        case .quick360Experimental:
            return "실험용 full-sphere / OpenCV A/B (기본 경로 아님)"
        }
    }

    var secondaryCaption: String? {
        switch self {
        case .spaceScan3DGS: return "Gaussian Splatting 기반"
        default: return nil
        }
    }

    var icon: String {
        switch self {
        case .directionCapture: return "camera.aperture"
        case .panoramaCapture: return "pano"
        case .spaceScan3DGS: return "viewfinder"
        case .quick360Experimental: return "globe.americas.fill"
        }
    }

    var showsBetaBadge: Bool {
        self == .spaceScan3DGS
    }

    var isExperimental: Bool {
        self == .quick360Experimental || self == .panoramaCapture
    }
}

/// Entry for Record tab — opens LatLong (DirectionCapture) immediately.
struct CaptureContainerView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedMode: CaptureMode? = .directionCapture
    @State private var isCapturing = true
    #if DEBUG
    @State private var showDebugModes = false
    #endif

    var body: some View {
        NavigationStack {
            ZStack {
                GonggiAmbientBackground()
                if isCapturing, let mode = selectedMode, mode == .spaceScan3DGS {
                    captureFlow(for: mode)
                } else if !isCapturing {
                    idlePrompt
                } else {
                    // DirectionCapture / other modes use fullScreenCover; keep ambient behind.
                    Color.clear
                }
            }
            .navigationBarHidden(true)
        }
        .fullScreenCover(isPresented: Binding(
            get: { isCapturing && selectedMode == .directionCapture },
            set: { presented in
                if !presented {
                    isCapturing = false
                    selectedMode = nil
                }
            }
        )) {
            DirectionCaptureView(onClose: {
                isCapturing = false
                selectedMode = nil
            })
            .environmentObject(appState)
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
        .onAppear {
            // Re-enter Record tab after closing: open LatLong capture again.
            if !isCapturing {
                startDirectionCapture()
            }
        }
    }

    @ViewBuilder
    private func captureFlow(for mode: CaptureMode) -> some View {
        switch mode {
        case .spaceScan3DGS:
            CaptureFlowView(onClose: { isCapturing = false; selectedMode = nil })
        case .directionCapture, .panoramaCapture, .quick360Experimental:
            EmptyView()
        }
    }

    /// Shown briefly after the user dismisses capture (before onAppear reopens, or DEBUG tools).
    private var idlePrompt: some View {
        VStack(spacing: GonggiSpacing.xl) {
            Spacer()
            Text("공간을 기록할까요?")
                .font(GonggiTypography.title(26))
                .foregroundStyle(GonggiColors.textPrimary)
                .multilineTextAlignment(.center)

            PrimaryButton(title: "촬영 시작", icon: "camera.aperture") {
                startDirectionCapture()
            }
            .padding(.horizontal, GonggiSpacing.lg)

            #if DEBUG
            debugModesSection
            #endif

            if appState.isMockMode {
                Text("Mock 모드 · 미리보기용")
                    .font(GonggiTypography.caption(11))
                    .foregroundStyle(GonggiColors.textTertiary)
            }
            Spacer()
        }
        .padding()
    }

    #if DEBUG
    private var debugModesSection: some View {
        VStack(spacing: GonggiSpacing.sm) {
            Button {
                showDebugModes.toggle()
            } label: {
                Text(showDebugModes ? "개발자 모드 숨기기" : "개발자 모드")
                    .font(GonggiTypography.caption(12))
                    .foregroundStyle(GonggiColors.textTertiary)
            }
            if showDebugModes {
                ForEach(CaptureMode.debugModes) { mode in
                    modeCard(mode)
                }
            }
        }
        .padding(.horizontal, GonggiSpacing.lg)
    }
    #endif

    private func startDirectionCapture() {
        GonggiHaptics.medium()
        selectedMode = .directionCapture
        isCapturing = true
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
                        .fill(GonggiColors.accentTeal.opacity(0.12))
                        .frame(width: 52, height: 52)
                    Image(systemName: mode.icon)
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(GonggiColors.accentTeal)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(mode.title)
                            .font(GonggiTypography.body(17))
                            .foregroundStyle(GonggiColors.textPrimary)
                        if mode.showsBetaBadge {
                            Text("BETA")
                                .font(GonggiTypography.caption(10))
                                .fontWeight(.semibold)
                                .foregroundStyle(GonggiColors.accentCyan)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(GonggiColors.accentCyan.opacity(0.15))
                                .clipShape(Capsule())
                        }
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
                    if let secondary = mode.secondaryCaption {
                        Text(secondary)
                            .font(GonggiTypography.caption(11))
                            .foregroundStyle(GonggiColors.textTertiary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(GonggiColors.textTertiary)
            }
            .padding(GonggiSpacing.md)
            .background(GonggiColors.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                    .stroke(GonggiColors.borderSubtle, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
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
    @State private var showGaussianViewer = false
    @State private var completedGaussianSpaceId: String?
    let onClose: () -> Void
    /// Optional Astra guide plan — when set, overlay shows segment coaching.
    var guidePlan: AdvancedCaptureGuidePlan? = nil
    /// LatLong space session that spawned this guided 3DGS capture.
    var sourceLatLongSessionId: String? = nil

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

            if let plan = guidePlan {
                GuidedCapturePlanBanner(plan: plan, segmentIndex: viewModel.guidedSegmentIndex)
                    .allowsHitTesting(false)
            }

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
        .onAppear {
            viewModel.configure(mockMode: appState.isMockMode)
            if let plan = guidePlan {
                viewModel.applyGuidePlan(plan)
            }
        }
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
                    onPreviewSpace: summary.texturedSpaceURL.map { _ in
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
                    qualityProfile: guidePlan?.qualityProfile ?? "capture_dense_v2",
                    sourceLatLongSessionId: sourceLatLongSessionId,
                    allowStubVideoInMock: appState.isMockMode,
                    onComplete: { jobId, spaceId in
                        if let latLongId = sourceLatLongSessionId {
                            AdvancedCaptureAnalysisStore.shared.update(sessionId: latLongId) { record in
                                record.linkedGaussianSpaceId = spaceId
                                record.linkedGaussianJobId = jobId
                            }
                        }
                        completedGaussianSpaceId = spaceId
                        showProcessing = false
                        showGaussianViewer = true
                    },
                    onDismiss: { showProcessing = false }
                )
            }
        }
        .fullScreenCover(isPresented: $showGaussianViewer) {
            if let spaceId = completedGaussianSpaceId {
                GaussianSplatWebViewer(spaceId: spaceId) {
                    showGaussianViewer = false
                    onClose()
                    appState.selectTab(.library)
                }
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
