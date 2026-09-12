import SwiftUI

/// Record-tab multi-step flow: LatLong (space grasp) → Astra guide → Guided 3DGS capture.
/// Reuses existing DirectionCapture / analysis / Guided3DGS — does not alter P0.5 capture stack.
struct ThreeDSpaceRecordFlowView: View {
    @EnvironmentObject private var appState: AppState
    let onClose: () -> Void

    private enum Phase: Equatable {
        case introStep1
        case directionCapture
        case preparingSpace(sessionId: String)
        case analyzing(sessionId: String)
        case introStep2(sessionId: String, plan: AdvancedCaptureGuidePlan)
        case guidedCapture(sessionId: String, plan: AdvancedCaptureGuidePlan)
        case failed(String)
    }

    @State private var phase: Phase = .introStep1
    @State private var waitTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            GonggiAmbientBackground()

            switch phase {
            case .introStep1:
                stepIntro(
                    stepLabel: "1 / 2",
                    title: "공간을 먼저 확인할게요",
                    body: "여러 방향을 촬영해 공간을 파악한 뒤, 이어서 입체 기록을 진행해요.",
                    primaryTitle: "시작하기",
                    primaryIcon: "camera.aperture"
                ) {
                    GonggiHaptics.medium()
                    phase = .directionCapture
                }

            case .directionCapture:
                Color.clear

            case .preparingSpace:
                waitingPanel(
                    stepLabel: "1 / 2",
                    title: "공간을 준비하고 있어요",
                    detail: "촬영본은 저장됐어요. 준비가 끝나면 입체 기록으로 이어집니다."
                )

            case .analyzing:
                waitingPanel(
                    stepLabel: "2 / 2",
                    title: "입체 기록을 준비하고 있어요",
                    detail: "앱을 나가도 분석은 계속됩니다. 잠시만 기다려 주세요."
                )

            case .introStep2(_, let plan):
                stepIntro(
                    stepLabel: "2 / 2",
                    title: "공간을 입체적으로 기록할게요",
                    body: plan.globalTips.first.map(AdvancedCaptureCopy.withoutMiddleDot)
                        ?? "공간을 걸으며 촬영해 자유롭게 이동할 수 있어요.",
                    primaryTitle: "입체 기록 시작",
                    primaryIcon: "figure.walk"
                ) {
                    GonggiHaptics.medium()
                    if case .introStep2(let sessionId, let plan) = phase {
                        phase = .guidedCapture(sessionId: sessionId, plan: plan)
                    }
                }

            case .guidedCapture(let sessionId, let plan):
                Guided3DGSCaptureFlowView(
                    plan: plan,
                    sessionId: sessionId,
                    onClose: {
                        waitTask?.cancel()
                        onClose()
                    }
                )
                .environmentObject(appState)

            case .failed(let message):
                VStack(spacing: GonggiSpacing.lg) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(GonggiColors.warning)
                    Text(message)
                        .font(GonggiTypography.body(16))
                        .foregroundStyle(GonggiColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, GonggiSpacing.lg)
                    PrimaryButton(title: "선택 화면으로", icon: "arrow.uturn.backward") {
                        waitTask?.cancel()
                        onClose()
                    }
                    .padding(.horizontal, GonggiSpacing.lg)
                    Text("촬영본은 보관함에 남아 있어요. 공간 상세에서 이어서 입체 기록을 할 수 있어요.")
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, GonggiSpacing.lg)
                    Spacer()
                }
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: {
                if case .directionCapture = phase { return true }
                return false
            },
            set: { presented in
                if !presented, case .directionCapture = phase {
                    // User dismissed without completing — no LatLong job created.
                    onClose()
                }
            }
        )) {
            DirectionCaptureView(
                onClose: {
                    // Cancel before LatLong enqueue — return to Record selection.
                    if case .directionCapture = phase {
                        onClose()
                    }
                },
                onCaptureCompleted: { result in
                    appState.enqueueSpaceGeneration(from: result, switchToHome: false)
                    phase = .preparingSpace(sessionId: result.sessionId)
                    startWaitPipeline(sessionId: result.sessionId)
                }
            )
            .environmentObject(appState)
        }
        .onDisappear {
            waitTask?.cancel()
        }
    }

    // MARK: - Panels

    private func stepIntro(
        stepLabel: String,
        title: String,
        body: String,
        primaryTitle: String,
        primaryIcon: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: GonggiSpacing.xl) {
            HStack {
                Button {
                    waitTask?.cancel()
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(GonggiColors.textSecondary)
                        .frame(width: 40, height: 40)
                        .background(GonggiColors.surfaceElevated)
                        .clipShape(Circle())
                }
                Spacer()
            }
            .padding(.horizontal, GonggiSpacing.lg)
            .padding(.top, GonggiSpacing.md)

            Spacer()

            Text(stepLabel)
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.accentCyan)

            Text(title)
                .font(GonggiTypography.title(26))
                .foregroundStyle(GonggiColors.textPrimary)
                .multilineTextAlignment(.center)

            Text(body)
                .font(GonggiTypography.body(16))
                .foregroundStyle(GonggiColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, GonggiSpacing.lg)

            Spacer()

            PrimaryButton(title: primaryTitle, icon: primaryIcon, action: action)
                .padding(.horizontal, GonggiSpacing.lg)
                .padding(.bottom, GonggiSpacing.xl)
        }
    }

    private func waitingPanel(stepLabel: String, title: String, detail: String) -> some View {
        VStack(spacing: GonggiSpacing.lg) {
            HStack {
                Button {
                    // LatLong already enqueued — safe to leave; continue later from Space Detail.
                    waitTask?.cancel()
                    onClose()
                    appState.selectTab(.home)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(GonggiColors.textSecondary)
                        .frame(width: 40, height: 40)
                        .background(GonggiColors.surfaceElevated)
                        .clipShape(Circle())
                }
                Spacer()
            }
            .padding(.horizontal, GonggiSpacing.lg)
            .padding(.top, GonggiSpacing.md)

            Spacer()
            ProgressView()
                .tint(GonggiColors.accentCyan)
                .scaleEffect(1.2)
            Text(stepLabel)
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.accentCyan)
            Text(title)
                .font(GonggiTypography.title(22))
                .foregroundStyle(GonggiColors.textPrimary)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, GonggiSpacing.lg)
            Spacer()
        }
    }

    // MARK: - Pipeline

    private func startWaitPipeline(sessionId: String) {
        waitTask?.cancel()
        waitTask = Task { @MainActor in
            // Wait until LatLong generation completes (or fails).
            let spaceReady = await waitUntilSpaceReady(sessionId: sessionId)
            guard !Task.isCancelled else { return }
            guard spaceReady else {
                phase = .failed("공간 준비를 마치지 못했어요.")
                return
            }

            phase = .analyzing(sessionId: sessionId)
            AdvancedCaptureAnalysisRuntime.shared.configure(useMock: appState.isMockMode)
            let start = await AdvancedCaptureAnalysisRuntime.shared.startAnalysis(sessionId: sessionId)
            guard !Task.isCancelled else { return }
            if case .failure(let error) = start {
                phase = .failed(error.userMessage)
                return
            }

            let planReady = await waitUntilGuideReady(sessionId: sessionId)
            guard !Task.isCancelled else { return }
            guard let plan = planReady else {
                phase = .failed("입체 기록 준비를 마치지 못했어요. 보관함 공간 상세에서 이어서 진행할 수 있어요.")
                return
            }
            phase = .introStep2(sessionId: sessionId, plan: plan)
        }
    }

    private func waitUntilSpaceReady(sessionId: String) async -> Bool {
        for _ in 0..<180 {
            if Task.isCancelled { return false }
            if let job = appState.jobStore.jobs.first(where: {
                $0.sessionId == sessionId || $0.jobId == sessionId
            }) {
                let status = job.serverStatus.lowercased()
                if status == "completed" { return true }
                if status == "failed" { return false }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return false
    }

    private func waitUntilGuideReady(sessionId: String) async -> AdvancedCaptureGuidePlan? {
        for _ in 0..<120 {
            if Task.isCancelled { return nil }
            await AdvancedCaptureAnalysisRuntime.shared.syncActiveOnce()
            if let record = AdvancedCaptureAnalysisStore.shared.record(sessionId: sessionId) {
                if record.canStartGuidedCapture, let plan = record.guidePlan {
                    return AdvancedCaptureCopy.sanitize(plan)
                }
                if record.status == .failed {
                    return nil
                }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return nil
    }
}
