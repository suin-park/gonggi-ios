import SwiftUI

/// Record-tab 3D flow: choose existing 360 vs new capture → optional Astra → Guided 3DGS.
/// Astra is not required — DefaultP1 plan + P1 live guidance can proceed alone.
struct ThreeDSpaceRecordFlowView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var analysisStore = AdvancedCaptureAnalysisStore.shared
    let onClose: () -> Void

    private enum Phase: Equatable {
        case chooseEntry
        case pickExisting
        case introStep1
        case directionCapture
        case preparingSpace(sessionId: String)
        case analyzing(sessionId: String, startedAt: Date)
        case analysisRecovery(sessionId: String, message: String)
        case introStep2(sessionId: String, plan: AdvancedCaptureGuidePlan)
        case guidedCapture(sessionId: String, plan: AdvancedCaptureGuidePlan)
        case failed(String)
    }

    @State private var phase: Phase = .chooseEntry
    @State private var waitTask: Task<Void, Never>?
    /// When true, selecting an existing space skips Astra and uses DefaultP1 plan.
    @State private var preferDefaultPlan = false

    private var expandableSpaces: [SpaceRecord] {
        ThreeDExpansionSupport.expandableSpaces(from: appState.spaces, store: analysisStore)
    }

    var body: some View {
        ZStack {
            GonggiAmbientBackground()

            switch phase {
            case .chooseEntry:
                chooseEntryPanel

            case .pickExisting:
                pickExistingPanel

            case .introStep1:
                stepIntro(
                    stepLabel: "1 / 2",
                    title: "공간을 먼저 확인할게요",
                    body: "여러 방향을 촬영해 공간을 파악한 뒤, 이어서 입체 기록을 진행해요.",
                    primaryTitle: "시작하기",
                    primaryIcon: "camera.aperture",
                    showsBack: true,
                    onBack: { phase = .chooseEntry }
                ) {
                    GonggiHaptics.medium()
                    phase = .directionCapture
                }

            case .directionCapture:
                Color.clear

            case .preparingSpace:
                waitingPanel(
                    title: "공간을 준비하고 있어요",
                    detail: "촬영본은 저장됐어요. 준비가 끝나면 입체 기록으로 이어집니다.",
                    allowsLeaveToHome: true,
                    recovery: nil
                )

            case .analyzing(let sessionId, let startedAt):
                analyzingPanel(sessionId: sessionId, startedAt: startedAt)

            case .analysisRecovery(let sessionId, let message):
                recoveryPanel(sessionId: sessionId, message: message)

            case .introStep2(_, let plan):
                stepIntro(
                    stepLabel: "2 / 2",
                    title: "입체 기록 준비가 완료됐어요",
                    body: plan.globalTips.first.map(AdvancedCaptureCopy.withoutMiddleDot)
                        ?? "공간을 걸으며 촬영해 자유롭게 이동할 수 있어요.",
                    primaryTitle: "입체 기록 시작",
                    primaryIcon: "figure.walk",
                    showsBack: false,
                    onBack: nil
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
                    PrimaryButton(title: "시작 방식으로", icon: "arrow.uturn.backward") {
                        waitTask?.cancel()
                        preferDefaultPlan = false
                        phase = .chooseEntry
                    }
                    .padding(.horizontal, GonggiSpacing.lg)
                    Text("기존 360° 공간은 그대로 보관함에 남아 있어요.")
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
                    phase = .introStep1
                }
            }
        )) {
            DirectionCaptureView(
                onClose: {
                    if case .directionCapture = phase {
                        phase = .introStep1
                    }
                },
                onCaptureCompleted: { result in
                    appState.enqueueSpaceGeneration(from: result, switchToHome: false)
                    phase = .preparingSpace(sessionId: result.sessionId)
                    startNewCapturePipeline(sessionId: result.sessionId)
                }
            )
            .environmentObject(appState)
        }
        .onDisappear {
            waitTask?.cancel()
        }
    }

    // MARK: - Entry choice

    private var chooseEntryPanel: some View {
        VStack(spacing: 0) {
            flowChrome(title: "3D 공간 기록", onBack: nil, onClose: {
                waitTask?.cancel()
                onClose()
            })

            ScrollView {
                VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                    Text("어떻게 시작할까요?")
                        .font(GonggiTypography.body(16))
                        .foregroundStyle(GonggiColors.textSecondary)
                        .padding(.top, GonggiSpacing.md)

                    entryChoiceCard(
                        icon: "rectangle.stack",
                        title: "기존 공간에서 시작",
                        subtitle: "기록해둔 360° 공간을\n3D 공간으로 확장해요"
                    ) {
                        GonggiHaptics.medium()
                        preferDefaultPlan = false
                        phase = .pickExisting
                    }

                    entryChoiceCard(
                        icon: "camera.aperture",
                        title: "새 공간 기록",
                        subtitle: "공간을 먼저 촬영한 뒤\n3D로 기록해요"
                    ) {
                        GonggiHaptics.medium()
                        preferDefaultPlan = false
                        phase = .introStep1
                    }

                    entryChoiceCard(
                        icon: "figure.walk",
                        title: "바로 3D 촬영",
                        subtitle: "기본 안내로 바로 이어가요\n(기존 360° 공간 선택)"
                    ) {
                        GonggiHaptics.medium()
                        preferDefaultPlan = true
                        phase = .pickExisting
                    }
                }
                .padding(.horizontal, GonggiSpacing.lg)
                .padding(.bottom, GonggiSpacing.xxl)
            }
        }
    }

    private var pickExistingPanel: some View {
        VStack(spacing: 0) {
            flowChrome(
                title: preferDefaultPlan ? "바로 촬영할 공간 선택" : "3D로 확장할 공간 선택",
                onBack: {
                    waitTask?.cancel()
                    preferDefaultPlan = false
                    phase = .chooseEntry
                },
                onClose: {
                    waitTask?.cancel()
                    onClose()
                }
            )

            if expandableSpaces.isEmpty {
                emptyExistingPanel
            } else {
                ScrollView {
                    LazyVStack(spacing: GonggiSpacing.md) {
                        ForEach(expandableSpaces) { space in
                            Button {
                                GonggiHaptics.medium()
                                beginExpansion(from: space)
                            } label: {
                                existingSpaceCard(space)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(space.name), \(space.capturedAt.formatted(date: .abbreviated, time: .omitted))")
                        }
                    }
                    .padding(.horizontal, GonggiSpacing.lg)
                    .padding(.top, GonggiSpacing.md)
                    .padding(.bottom, GonggiSpacing.xxl)
                }
            }
        }
    }

    private var emptyExistingPanel: some View {
        VStack(spacing: GonggiSpacing.lg) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(GonggiColors.textTertiary)
            Text("아직 사용할 수 있는 360° 공간이 없어요.")
                .font(GonggiTypography.title(20))
                .foregroundStyle(GonggiColors.textPrimary)
                .multilineTextAlignment(.center)
            Text("먼저 공간을 기록해주세요.")
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textSecondary)
            PrimaryButton(title: "새 공간 기록", icon: "camera.aperture") {
                GonggiHaptics.medium()
                preferDefaultPlan = false
                phase = .introStep1
            }
            .padding(.horizontal, GonggiSpacing.lg)
            Spacer()
        }
        .padding(.horizontal, GonggiSpacing.lg)
    }

    private func existingSpaceCard(_ space: SpaceRecord) -> some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            SpaceThumbnailView(
                space: space,
                height: 140,
                cornerRadius: GonggiRadius.md,
                showsActivityOverlay: false
            )
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(space.name)
                        .font(GonggiTypography.headline(17))
                        .foregroundStyle(GonggiColors.textPrimary)
                        .lineLimit(2)
                    Text(space.capturedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(GonggiTypography.caption(12))
                        .foregroundStyle(GonggiColors.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(GonggiColors.textTertiary)
            }
            .padding(.horizontal, GonggiSpacing.xs)
        }
        .padding(GonggiSpacing.sm)
        .background(GonggiColors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                .stroke(GonggiColors.borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
    }

    private func entryChoiceCard(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: GonggiSpacing.md) {
                ZStack {
                    Circle()
                        .fill(GonggiColors.accentTeal.opacity(0.12))
                        .frame(width: 52, height: 52)
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(GonggiColors.accentTeal)
                }
                Text(title)
                    .font(GonggiTypography.headline(20))
                    .foregroundStyle(GonggiColors.textPrimary)
                Text(subtitle)
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
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

    // MARK: - Analyzing / recovery

    private func analyzingPanel(sessionId: String, startedAt: Date) -> some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            let copy = analyzingCopy(elapsed: elapsed)
            waitingPanel(
                title: copy.title,
                detail: copy.detail,
                allowsLeaveToHome: true,
                recovery: elapsed >= ThreeDExpansionSupport.PrepareConfig.softTimeoutSec
                    ? AnalyzingRecoveryActions(
                        onRetry: { retryAnalysis(sessionId: sessionId) },
                        onSkipToDefault: { enterWithDefaultPlan(sessionId: sessionId) }
                    )
                    : nil
            )
        }
    }

    private func analyzingCopy(elapsed: TimeInterval) -> (title: String, detail: String) {
        if elapsed < 15 {
            return ("공간을 확인하고 있어요", "3D 촬영 경로를 준비하고 있습니다.")
        }
        if elapsed < ThreeDExpansionSupport.PrepareConfig.softTimeoutSec {
            return ("촬영 경로를 준비하고 있어요", "조금만 기다려 주세요.")
        }
        return (
            "분석이 예상보다 오래 걸리고 있어요.",
            "다시 시도하거나, 기본 안내로 바로 촬영을 시작할 수 있어요."
        )
    }

    private struct AnalyzingRecoveryActions {
        var onRetry: () -> Void
        var onSkipToDefault: () -> Void
    }

    private func recoveryPanel(sessionId: String, message: String) -> some View {
        VStack(spacing: GonggiSpacing.lg) {
            flowChrome(title: "", onBack: {
                waitTask?.cancel()
                phase = .pickExisting
            }, onClose: {
                waitTask?.cancel()
                onClose()
            })
            Spacer()
            ProgressView()
                .tint(GonggiColors.accentCyan)
            Text(message)
                .font(GonggiTypography.title(20))
                .foregroundStyle(GonggiColors.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, GonggiSpacing.lg)
            Text("기본 안내로도 입체 기록을 시작할 수 있어요.")
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, GonggiSpacing.lg)
            PrimaryButton(title: "다시 시도", icon: "arrow.clockwise") {
                retryAnalysis(sessionId: sessionId)
            }
            .padding(.horizontal, GonggiSpacing.lg)
            SecondaryButton(title: "바로 3D 촬영", icon: "figure.walk") {
                enterWithDefaultPlan(sessionId: sessionId)
            }
            .padding(.horizontal, GonggiSpacing.lg)
            Spacer()
        }
    }

    // MARK: - Shared chrome / panels

    private func flowChrome(title: String, onBack: (() -> Void)?, onClose: @escaping () -> Void) -> some View {
        HStack {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(GonggiColors.textSecondary)
                        .frame(width: 40, height: 40)
                        .background(GonggiColors.surfaceElevated)
                        .clipShape(Circle())
                }
                .accessibilityLabel("뒤로")
            } else {
                Color.clear.frame(width: 40, height: 40)
            }
            Spacer()
            Text(title)
                .font(GonggiTypography.headline(17))
                .foregroundStyle(GonggiColors.textPrimary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .frame(width: 40, height: 40)
                    .background(GonggiColors.surfaceElevated)
                    .clipShape(Circle())
            }
            .accessibilityLabel("닫기")
        }
        .padding(.horizontal, GonggiSpacing.lg)
        .padding(.top, GonggiSpacing.md)
        .padding(.bottom, GonggiSpacing.sm)
    }

    private func stepIntro(
        stepLabel: String,
        title: String,
        body: String,
        primaryTitle: String,
        primaryIcon: String,
        showsBack: Bool,
        onBack: (() -> Void)?,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: GonggiSpacing.xl) {
            flowChrome(
                title: stepLabel,
                onBack: showsBack ? onBack : nil,
                onClose: {
                    waitTask?.cancel()
                    onClose()
                }
            )

            Spacer()

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

    private func waitingPanel(
        title: String,
        detail: String,
        allowsLeaveToHome: Bool,
        recovery: AnalyzingRecoveryActions?
    ) -> some View {
        VStack(spacing: GonggiSpacing.lg) {
            flowChrome(title: "", onBack: nil, onClose: {
                waitTask?.cancel()
                onClose()
                if allowsLeaveToHome {
                    appState.selectTab(.home)
                }
            })

            Spacer()
            ProgressView()
                .tint(GonggiColors.accentCyan)
                .scaleEffect(1.2)
            Text(title)
                .font(GonggiTypography.title(22))
                .foregroundStyle(GonggiColors.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, GonggiSpacing.md)
            Text(detail)
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, GonggiSpacing.lg)

            if let recovery {
                PrimaryButton(title: "다시 시도", icon: "arrow.clockwise", action: recovery.onRetry)
                    .padding(.horizontal, GonggiSpacing.lg)
                SecondaryButton(title: "바로 3D 촬영", icon: "figure.walk", action: recovery.onSkipToDefault)
                    .padding(.horizontal, GonggiSpacing.lg)
            }
            Spacer()
        }
    }

    // MARK: - Pipelines

    private func beginExpansion(from space: SpaceRecord) {
        let sessionId = ThreeDExpansionSupport.sessionKey(for: space)
        if preferDefaultPlan {
            enterWithDefaultPlan(sessionId: sessionId)
            return
        }
        if let plan = ThreeDExpansionSupport.cachedGuidePlan(sessionId: sessionId, store: analysisStore) {
            phase = .introStep2(sessionId: sessionId, plan: plan)
            return
        }
        let started = Date()
        phase = .analyzing(sessionId: sessionId, startedAt: started)
        startExistingExpansionPipeline(sessionId: sessionId)
    }

    private func enterWithDefaultPlan(sessionId: String) {
        waitTask?.cancel()
        preferDefaultPlan = false
        let plan = AdvancedCaptureCopy.sanitize(.defaultP1Plan(sessionId: sessionId))
        phase = .introStep2(sessionId: sessionId, plan: plan)
    }

    private func retryAnalysis(sessionId: String) {
        waitTask?.cancel()
        let started = Date()
        phase = .analyzing(sessionId: sessionId, startedAt: started)
        waitTask = Task { @MainActor in
            // Force a fresh analyze attempt (stale / failed recovery).
            _ = await ThreeDExpansionSupport.startOrReuseAnalysis(
                sessionId: sessionId,
                useMock: appState.isMockMode,
                force: true
            )
            guard !Task.isCancelled else { return }
            await finishPrepare(sessionId: sessionId)
        }
    }

    private func startExistingExpansionPipeline(sessionId: String) {
        waitTask?.cancel()
        waitTask = Task { @MainActor in
            await finishPrepare(sessionId: sessionId)
        }
    }

    private func finishPrepare(sessionId: String) async {
        let result = await ThreeDExpansionSupport.prepareGuidePlan(
            sessionId: sessionId,
            useMock: appState.isMockMode
        )
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let plan):
            phase = .introStep2(sessionId: sessionId, plan: plan)
        case .failure(let error):
            if error == .timedOut || error == .notReady {
                phase = .analysisRecovery(sessionId: sessionId, message: error.userMessage)
            } else {
                // Still offer default path via recovery for network/server errors.
                phase = .analysisRecovery(sessionId: sessionId, message: error.userMessage)
            }
        }
    }

    private func startNewCapturePipeline(sessionId: String) {
        waitTask?.cancel()
        waitTask = Task { @MainActor in
            let spaceReady = await waitUntilSpaceReady(sessionId: sessionId)
            guard !Task.isCancelled else { return }
            guard spaceReady else {
                phase = .failed("공간 준비를 마치지 못했어요.")
                return
            }

            let started = Date()
            phase = .analyzing(sessionId: sessionId, startedAt: started)
            await finishPrepare(sessionId: sessionId)
        }
    }

    private func waitUntilSpaceReady(sessionId: String) async -> Bool {
        // Cap wait: do not block for minutes on LatLong generation from this foreground flow.
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
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
}
