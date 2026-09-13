import SwiftUI

/// Capture mode selection.
/// Production Record tab shows equal choices: 360° vs 3D space record.
/// Other modes remain for DEBUG / internal access only.
enum CaptureMode: String, Identifiable {
    case directionCapture
    case panoramaCapture
    case spaceScan3DGS
    case quick360Experimental

    var id: String { rawValue }

    /// Legacy alias — Record tab no longer auto-starts this; selection screen is first.
    static var productionDefault: CaptureMode { .directionCapture }

    /// DEBUG / internal modes listed under developer section.
    static var debugModes: [CaptureMode] {
        [.spaceScan3DGS, .panoramaCapture, .quick360Experimental]
    }

    /// Legacy alias.
    static var productionModes: [CaptureMode] {
        [.directionCapture]
    }

    var title: String {
        switch self {
        case .directionCapture: return "360° 공간 기록"
        case .panoramaCapture: return "파노라마 기록"
        case .spaceScan3DGS: return "3D 공간 스캔 (DEBUG)"
        case .quick360Experimental: return "실험 · 360 공간 기록"
        }
    }

    var subtitle: String {
        switch self {
        case .directionCapture:
            return "한 자리에서 공간을 촬영해 빠르게 둘러볼 수 있어요."
        case .panoramaCapture:
            return "제자리에서 천천히 회전하며 수평 파노라마를 만들어요"
        case .spaceScan3DGS:
            return "DEBUG: spaceScan3DGS 직접 진입 (P0.5 파이프라인)"
        case .quick360Experimental:
            return "실험용 full-sphere / OpenCV A/B (기본 경로 아님)"
        }
    }

    var secondaryCaption: String? {
        switch self {
        case .spaceScan3DGS: return "내부 전용"
        default: return nil
        }
    }

    var icon: String {
        switch self {
        case .directionCapture: return "camera.aperture"
        case .panoramaCapture: return "pano"
        case .spaceScan3DGS: return "cube.transparent"
        case .quick360Experimental: return "globe.americas.fill"
        }
    }

    var showsBetaBadge: Bool { false }

    var isExperimental: Bool {
        self == .quick360Experimental || self == .panoramaCapture
    }
}

/// Entry for Record tab — choose 360° or 3D space recording first.
struct CaptureContainerView: View {
    @EnvironmentObject private var appState: AppState

    private enum ActiveFlow: Equatable {
        case none
        case directionCapture
        case threeDSpaceRecord
        case debug(CaptureMode)
    }

    @State private var activeFlow: ActiveFlow = .none
    #if DEBUG
    @State private var showDebugModes = false
    #endif

    var body: some View {
        NavigationStack {
            ZStack {
                GonggiAmbientBackground()
                switch activeFlow {
                case .none:
                    recordModeSelection
                case .threeDSpaceRecord:
                    ThreeDSpaceRecordFlowView(onClose: { activeFlow = .none })
                        .environmentObject(appState)
                case .debug(.spaceScan3DGS):
                    CaptureFlowView(onClose: { activeFlow = .none })
                case .directionCapture, .debug(.panoramaCapture), .debug(.quick360Experimental), .debug(.directionCapture):
                    Color.clear
                }
            }
            .navigationBarHidden(true)
        }
        .fullScreenCover(isPresented: Binding(
            get: { activeFlow == .directionCapture },
            set: { presented in
                if !presented { activeFlow = .none }
            }
        )) {
            DirectionCaptureView(onClose: { activeFlow = .none })
                .environmentObject(appState)
        }
        .fullScreenCover(isPresented: Binding(
            get: {
                if case .debug(.panoramaCapture) = activeFlow { return true }
                return false
            },
            set: { presented in
                if !presented { activeFlow = .none }
            }
        )) {
            PanoramaCaptureFlowView(onClose: { activeFlow = .none })
                .environmentObject(appState)
        }
        .fullScreenCover(isPresented: Binding(
            get: {
                if case .debug(.quick360Experimental) = activeFlow { return true }
                return false
            },
            set: { presented in
                if !presented { activeFlow = .none }
            }
        )) {
            Quick360FlowView(onClose: { activeFlow = .none })
                .environmentObject(appState)
        }
    }

    // MARK: - Selection

    private var recordModeSelection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
                    Text("공간 기록")
                        .font(GonggiTypography.title(28))
                        .foregroundStyle(GonggiColors.textPrimary)
                    Text("어떤 방식으로 기록할까요?")
                        .font(GonggiTypography.body(16))
                        .foregroundStyle(GonggiColors.textSecondary)
                }
                .padding(.top, GonggiSpacing.xl)

                productionChoiceCard(
                    icon: "arrow.triangle.2.circlepath.circle",
                    title: "360° 공간 기록",
                    subtitle: "한 자리에서 공간을 촬영해\n빠르게 둘러볼 수 있어요.",
                    badge: "빠른 기록",
                    action: {
                        GonggiHaptics.medium()
                        activeFlow = .directionCapture
                    }
                )

                productionChoiceCard(
                    icon: "figure.walk.motion",
                    title: "3D 공간 기록",
                    subtitle: "공간을 걸으며 촬영해\n자유롭게 이동할 수 있어요.",
                    badge: "입체 기록",
                    action: {
                        GonggiHaptics.medium()
                        activeFlow = .threeDSpaceRecord
                    }
                )

                #if DEBUG
                debugModesSection
                #endif

                if appState.isMockMode {
                    Text("Mock 모드 · 미리보기용")
                        .font(GonggiTypography.caption(11))
                        .foregroundStyle(GonggiColors.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, GonggiSpacing.lg)
            .padding(.bottom, GonggiSpacing.xxl)
        }
    }

    private func productionChoiceCard(
        icon: String,
        title: String,
        subtitle: String,
        badge: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: GonggiSpacing.md) {
                HStack(alignment: .top) {
                    ZStack {
                        Circle()
                            .fill(GonggiColors.accentTeal.opacity(0.12))
                            .frame(width: 52, height: 52)
                        Image(systemName: icon)
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(GonggiColors.accentTeal)
                    }
                    Spacer(minLength: 0)
                    Text(badge)
                        .font(GonggiTypography.caption(11))
                        .fontWeight(.semibold)
                        .foregroundStyle(GonggiColors.accentCyan)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(GonggiColors.accentCyan.opacity(0.14))
                        .clipShape(Capsule())
                }

                Text(title)
                    .font(GonggiTypography.headline(20))
                    .foregroundStyle(GonggiColors.textPrimary)

                Text(subtitle)
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("시작")
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.accentCyan)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(GonggiColors.accentCyan)
                }
            }
            .padding(GonggiSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GonggiColors.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                    .stroke(GonggiColors.borderSubtle, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
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
        .padding(.top, GonggiSpacing.md)
    }
    #endif

    private func modeCard(_ mode: CaptureMode) -> some View {
        Button {
            GonggiHaptics.medium()
            activeFlow = .debug(mode)
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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = CaptureViewModel()
    @State private var showSummary = false
    @State private var showProcessing = false
    @State private var showSpacePreview = false
    @State private var showGaussianViewer = false
    @State private var completedGaussianSpaceId: String?
    @State private var showEarlyFinishConfirm = false
    let onClose: () -> Void
    /// Optional Astra guide plan — when set, overlay shows segment coaching.
    var guidePlan: AdvancedCaptureGuidePlan? = nil
    /// LatLong space session that spawned this guided 3DGS capture.
    var sourceLatLongSessionId: String? = nil

    private var suppressAstraBanner: Bool {
        // Astra is folded into PrimaryGuidanceState; never show a second action card.
        true
    }

    private var astraSegmentInstruction: String? {
        guard let plan = guidePlan, !plan.segments.isEmpty else { return nil }
        let idx = min(max(0, viewModel.guidedSegmentIndex), plan.segments.count - 1)
        return AdvancedCaptureCopy.withoutMiddleDot(plan.segments[idx].instructionKo)
    }

    private func finishCapture() {
        Task {
            await viewModel.stop()
            showSummary = true
        }
    }

    var body: some View {
        ZStack {
            switch viewModel.cameraPresentation {
            case .pending:
                Color.black.ignoresSafeArea()
            case .mock:
                MockCameraBackground(quality: viewModel.guidance.quality)
            case .live:
                ARCaptureViewRepresentable(
                    session: viewModel.arSession,
                    coverageSpatialIndex: viewModel.framePipeline.coverageSpatialIndex,
                    showMeshOverlay: viewModel.guidance.showGuideOverlay,
                    onViewReady: { viewModel.onARViewReady() }
                ) { frame in
                    viewModel.ingestFrame(frame)
                }
                .ignoresSafeArea()
            }

            if viewModel.cameraPresentation == .live, !viewModel.hasReceivedFrame {
                Color.black.opacity(0.55).ignoresSafeArea()
                VStack(spacing: GonggiSpacing.sm) {
                    ProgressView()
                        .tint(GonggiColors.accentCyan)
                    Text("카메라 준비 중…")
                        .font(GonggiTypography.caption(14))
                        .foregroundStyle(GonggiColors.textSecondary)
                }
                .allowsHitTesting(false)
            }

            CaptureOverlayView(
                guidance: viewModel.guidance,
                astraSegmentInstruction: astraSegmentInstruction,
                onClose: {
                    viewModel.cancelCapture()
                    onClose()
                },
                onFinish: {
                    if viewModel.guidance.quality.completionState == .ready {
                        finishCapture()
                    } else {
                        showEarlyFinishConfirm = true
                    }
                },
                onFlash: { viewModel.guidance.toggleFlash() },
                onGuide: { viewModel.guidance.toggleGuide() }
            )

            // Kept for API compatibility / DEBUG — always suppressed in favor of PrimaryGuidance.
            if let plan = guidePlan, !suppressAstraBanner {
                GuidedCapturePlanBanner(
                    plan: plan,
                    segmentIndex: viewModel.guidedSegmentIndex,
                    suppressForLivePriority: true
                )
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                viewModel.resumeCameraIfNeeded()
            }
        }
        .confirmationDialog(
            "조금 더 촬영하면 3D 공간 품질이 좋아질 수 있어요.",
            isPresented: $showEarlyFinishConfirm,
            titleVisibility: .visible
        ) {
            Button("추가 촬영", role: .cancel) {}
            Button("이대로 완료") { finishCapture() }
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

#Preview("Record selection") {
    CaptureContainerView()
        .environmentObject(AppState(isMockMode: true))
}

#Preview("Capture flow") {
    CaptureFlowView(onClose: {})
        .environmentObject(AppState(isMockMode: true))
}
