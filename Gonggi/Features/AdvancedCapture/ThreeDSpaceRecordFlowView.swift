import SwiftUI

/// Record-tab 3D flow: choose existing 360 vs new capture → Astra → Guided 3DGS.
/// Reuses DirectionCapture / ThreeDExpansionSupport / Guided3DGS — does not alter P0–P1 capture stack.
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
        case analyzing(sessionId: String)
        case introStep2(sessionId: String, plan: AdvancedCaptureGuidePlan)
        case guidedCapture(sessionId: String, plan: AdvancedCaptureGuidePlan)
        case failed(String)
    }

    @State private var phase: Phase = .chooseEntry
    @State private var waitTask: Task<Void, Never>?

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
                    allowsLeaveToHome: true
                )

            case .analyzing:
                waitingPanel(
                    title: "공간을 확인하고 있어요",
                    detail: "3D 촬영 경로를 준비하고 있습니다.",
                    allowsLeaveToHome: true
                )

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
                        phase = .pickExisting
                    }

                    entryChoiceCard(
                        icon: "camera.aperture",
                        title: "새 공간 기록",
                        subtitle: "공간을 먼저 촬영한 뒤\n3D로 기록해요"
                    ) {
                        GonggiHaptics.medium()
                        phase = .introStep1
                    }
                }
                .padding(.horizontal, GonggiSpacing.lg)
                .padding(.bottom, GonggiSpacing.xxl)
            }
        }
    }

    private var pickExistingPanel: some View {
        VStack(spacing: 0) {
            flowChrome(title: "3D로 확장할 공간 선택", onBack: {
                waitTask?.cancel()
                phase = .chooseEntry
            }, onClose: {
                waitTask?.cancel()
                onClose()
            })

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

    private func waitingPanel(title: String, detail: String, allowsLeaveToHome: Bool) -> some View {
        VStack(spacing: GonggiSpacing.lg) {
            flowChrome(title: "", onBack: nil, onClose: {
                // Existing LatLong is never deleted — leave and continue later from Space Detail.
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
            Text(detail)
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, GonggiSpacing.lg)
            Spacer()
        }
    }

    // MARK: - Pipelines

    private func beginExpansion(from space: SpaceRecord) {
        let sessionId = ThreeDExpansionSupport.sessionKey(for: space)
        if let plan = ThreeDExpansionSupport.cachedGuidePlan(sessionId: sessionId, store: analysisStore) {
            phase = .introStep2(sessionId: sessionId, plan: plan)
            return
        }
        phase = .analyzing(sessionId: sessionId)
        startExistingExpansionPipeline(sessionId: sessionId)
    }

    private func startExistingExpansionPipeline(sessionId: String) {
        waitTask?.cancel()
        waitTask = Task { @MainActor in
            let result = await ThreeDExpansionSupport.prepareGuidePlan(
                sessionId: sessionId,
                useMock: appState.isMockMode
            )
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let plan):
                phase = .introStep2(sessionId: sessionId, plan: plan)
            case .failure(let error):
                phase = .failed(error.userMessage)
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

            phase = .analyzing(sessionId: sessionId)
            let result = await ThreeDExpansionSupport.prepareGuidePlan(
                sessionId: sessionId,
                useMock: appState.isMockMode
            )
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let plan):
                phase = .introStep2(sessionId: sessionId, plan: plan)
            case .failure(let error):
                phase = .failed(error.userMessage)
            }
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
}
