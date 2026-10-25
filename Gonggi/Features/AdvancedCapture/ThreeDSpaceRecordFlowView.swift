import SwiftUI

/// Record-tab 3D flow:
/// 1) Existing 360 → Astra/cached → Guided 3DGS
/// 2) New 360 → LatLong → Astra → Guided 3DGS
/// 3) Direct 3D → defaultP1Plan → Guided 3DGS (no 360 / Astra)
struct ThreeDSpaceRecordFlowView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var analysisStore = AdvancedCaptureAnalysisStore.shared
    @ObservedObject private var analysisRuntime = AdvancedCaptureAnalysisRuntime.shared
    let onClose: () -> Void

    private enum Phase: Equatable {
        case chooseEntry
        case pickExisting
        case introStep1
        case directionCapture
        case preparingSpace(sessionId: String)
        case analyzing(sessionId: String, startedAt: Date)
        case analysisRecovery(sessionId: String, message: String)
        /// `sourceLatLongSessionId` nil = Direct 3D (no LatLong link / Astra).
        case introStep2(sessionId: String, plan: AdvancedCaptureGuidePlan, sourceLatLongSessionId: String?)
        case guidedCapture(sessionId: String, plan: AdvancedCaptureGuidePlan, sourceLatLongSessionId: String?)
        case failed(String)
    }

    @State private var phase: Phase = .chooseEntry
    @State private var waitTask: Task<Void, Never>?
    /// Prevents duplicate transition into introStep2 / guidedCapture for the same completion event.
    @State private var didPromoteReadySessionIds = Set<String>()
    @State private var didAutoStartDirect3D = false

    /// Production hides legacy entry cards; keep code for Space Detail expansion / DEBUG.
    private static var showLegacyEntryChoices: Bool {
        #if DEBUG
        false
        #else
        false
        #endif
    }

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
                    title: L("Let's check the space first"),
                    body: L("Capture several directions to understand the space, then continue to the 3D capture."),
                    primaryTitle: L("Get started"),
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
                    title: L("Preparing the space"),
                    detail: L("Your capture is saved. The 3D capture continues when it's ready."),
                    allowsLeaveToHome: true,
                    recovery: nil
                )

            case .analyzing(let sessionId, let startedAt):
                analyzingPanel(sessionId: sessionId, startedAt: startedAt)

            case .analysisRecovery(let sessionId, let message):
                recoveryPanel(sessionId: sessionId, message: message)

            case .introStep2(_, let plan, let sourceLatLong):
                stepIntro(
                    stepLabel: sourceLatLong == nil ? L("Direct 3D") : "2 / 2",
                    title: L("Ready to capture."),
                    body: sourceLatLong == nil
                        ? L("Start capturing right away with the standard guide, without space analysis.")
                        : (AdvancedCaptureCopy.serverCopy(plan.globalTips.first)
                            ?? L("A capture guide for this space is ready.")),
                    primaryTitle: L("Start 3D capture"),
                    primaryIcon: "figure.walk",
                    showsBack: false,
                    onBack: nil
                ) {
                    GonggiHaptics.medium()
                    if case .introStep2(let sessionId, let plan, let sourceLatLong) = phase {
                        phase = .guidedCapture(
                            sessionId: sessionId,
                            plan: plan,
                            sourceLatLongSessionId: sourceLatLong
                        )
                    }
                }

            case .guidedCapture(let sessionId, let plan, let sourceLatLong):
                Guided3DGSCaptureFlowView(
                    plan: plan,
                    sessionId: sessionId,
                    sourceLatLongSessionId: sourceLatLong,
                    skipsIntro: sourceLatLong == nil,
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
                    PrimaryButton(title: L("Capture again"), icon: "camera.aperture") {
                        waitTask?.cancel()
                        startDirect3DCapture()
                    }
                    .padding(.horizontal, GonggiSpacing.lg)
                    Text(L("Your existing 360° space stays in Library."))
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
        .onAppear {
            guard !didAutoStartDirect3D else { return }
            if case .chooseEntry = phase {
                didAutoStartDirect3D = true
                startDirect3DCapture()
            }
        }
        .onChange(of: analysisRuntime.analysisCompleteEpoch) { _, _ in
            handleAnalysisCompleteSignal()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gonggiAdvancedCaptureAnalysisComplete)) { note in
            let sid = note.userInfo?["sessionId"] as? String
            let jid = note.userInfo?["jobId"] as? String
            handleAnalysisCompleteSignal(preferredSessionId: sid, preferredJobId: jid)
        }
        .onDisappear {
            waitTask?.cancel()
        }
    }

    // MARK: - Entry choice

    private var chooseEntryPanel: some View {
        VStack(spacing: 0) {
            flowChrome(title: L("3D Space capture"), onBack: nil, onClose: {
                waitTask?.cancel()
                onClose()
            })

            if Self.showLegacyEntryChoices {
                ScrollView {
                    VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                        Text(L("How do you want to start?"))
                            .font(GonggiTypography.body(16))
                            .foregroundStyle(GonggiColors.textSecondary)
                            .padding(.top, GonggiSpacing.md)

                        entryChoiceCard(
                            icon: "rectangle.stack",
                            title: L("Start from an existing space"),
                            subtitle: L("Turn a saved 360° space\ninto a 3D Space")
                        ) {
                            GonggiHaptics.medium()
                            phase = .pickExisting
                        }

                        entryChoiceCard(
                            icon: "camera.aperture",
                            title: L("New space"),
                            subtitle: L("Check the space first,\nthen capture 3D with a tailored guide")
                        ) {
                            GonggiHaptics.medium()
                            phase = .introStep1
                        }

                        entryChoiceCard(
                            icon: "figure.walk",
                            title: L("Capture 3D now"),
                            subtitle: L("Start a 3D capture right away\nwithout space analysis")
                        ) {
                            GonggiHaptics.medium()
                            startDirect3DCapture()
                        }
                    }
                    .padding(.horizontal, GonggiSpacing.lg)
                    .padding(.bottom, GonggiSpacing.xxl)
                }
            } else {
                Spacer()
                ProgressView()
                    .tint(GonggiColors.accentCyan)
                Text(L("Preparing the capture"))
                    .font(GonggiTypography.caption(14))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .padding(.top, GonggiSpacing.sm)
                Spacer()
            }
        }
    }

    private var pickExistingPanel: some View {
        VStack(spacing: 0) {
            flowChrome(
                title: L("Choose a space to extend to 3D"),
                onBack: {
                    waitTask?.cancel()
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
                            .accessibilityLabel("\(space.name), \(WhikDate.short(space.capturedAt))")
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
            Text(L("You don't have a 360° space to use yet."))
                .font(GonggiTypography.title(20))
                .foregroundStyle(GonggiColors.textPrimary)
                .multilineTextAlignment(.center)
            Text(L("Capture a space first."))
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textSecondary)
            PrimaryButton(title: L("New space"), icon: "camera.aperture") {
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
                    Text(WhikDate.short(space.capturedAt))
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
            return (L("Checking the space"), L("Preparing the 3D capture path."))
        }
        if elapsed < ThreeDExpansionSupport.PrepareConfig.softTimeoutSec {
            return (L("Preparing the capture path"), L("Just a moment."))
        }
        return (
            L("Analysis is taking longer than expected."),
            L("Try again, or start capturing now with the standard guide.")
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
            Text(L("You can also start the 3D capture with the standard guide."))
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, GonggiSpacing.lg)
            PrimaryButton(title: L("Try again"), icon: "arrow.clockwise") {
                retryAnalysis(sessionId: sessionId)
            }
            .padding(.horizontal, GonggiSpacing.lg)
            SecondaryButton(title: L("Capture 3D now"), icon: "figure.walk") {
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
                .accessibilityLabel(L("Back"))
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
            .accessibilityLabel(L("Close"))
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
                PrimaryButton(title: L("Try again"), icon: "arrow.clockwise", action: recovery.onRetry)
                    .padding(.horizontal, GonggiSpacing.lg)
                SecondaryButton(title: L("Capture 3D now"), icon: "figure.walk", action: recovery.onSkipToDefault)
                    .padding(.horizontal, GonggiSpacing.lg)
            }
            Spacer()
        }
    }

    // MARK: - Pipelines

    /// Independent Direct 3D session — no 360 picker, LatLong, Astra, or cachedGuidePlan.
    /// Skips entry chooser + intro; opens guided capture immediately.
    private func startDirect3DCapture() {
        waitTask?.cancel()
        let sessionId = "direct3d-\(UUID().uuidString)"
        let plan = AdvancedCaptureCopy.sanitize(.defaultP1Plan(sessionId: sessionId))
        phase = .guidedCapture(sessionId: sessionId, plan: plan, sourceLatLongSessionId: nil)
    }

    private func beginExpansion(from space: SpaceRecord) {
        let sessionId = ThreeDExpansionSupport.sessionKey(for: space)
        if let plan = ThreeDExpansionSupport.cachedGuidePlan(sessionId: sessionId, store: analysisStore) {
            promoteToReady(sessionId: sessionId, plan: plan, sourceLatLongSessionId: sessionId)
            return
        }
        let started = Date()
        phase = .analyzing(sessionId: sessionId, startedAt: started)
        startExistingExpansionPipeline(sessionId: sessionId)
    }

    /// Recovery / soft-timeout skip: keep LatLong identity, use default plan (not Direct 3D entry).
    private func enterWithDefaultPlan(sessionId: String) {
        waitTask?.cancel()
        let plan = AdvancedCaptureCopy.sanitize(.defaultP1Plan(sessionId: sessionId))
        promoteToReady(sessionId: sessionId, plan: plan, sourceLatLongSessionId: sessionId)
    }

    private func promoteToReady(
        sessionId: String,
        plan: AdvancedCaptureGuidePlan,
        sourceLatLongSessionId: String?
    ) {
        didPromoteReadySessionIds.insert(sessionId)
        phase = .introStep2(
            sessionId: sessionId,
            plan: plan,
            sourceLatLongSessionId: sourceLatLongSessionId
        )
    }

    private func watchingAnalysisSessionId() -> String? {
        switch phase {
        case .analyzing(let id, _), .analysisRecovery(let id, _), .preparingSpace(let id):
            return id
        default:
            return nil
        }
    }

    private func sessionMatches(_ watching: String, completedSessionId: String?, completedJobId: String?) -> Bool {
        if let completedSessionId, watching == completedSessionId { return true }
        if let completedJobId, watching == completedJobId { return true }
        if let record = analysisStore.record(sessionId: watching) {
            if let completedSessionId, record.sessionId == completedSessionId || record.jobId == completedSessionId {
                return true
            }
            if let completedJobId, record.sessionId == completedJobId || record.jobId == completedJobId {
                return true
            }
        }
        return false
    }

    /// Push-first / late poll: upgrade analyzing or recovery → ready without leaving the screen.
    private func handleAnalysisCompleteSignal(
        preferredSessionId: String? = nil,
        preferredJobId: String? = nil
    ) {
        guard let watching = watchingAnalysisSessionId() else { return }
        let completedSessionId = preferredSessionId ?? analysisRuntime.lastCompletedSessionId
        let completedJobId = preferredJobId
        // Epoch-only signal: match watching against last completed id.
        if let completedSessionId {
            guard sessionMatches(watching, completedSessionId: completedSessionId, completedJobId: completedJobId)
            else { return }
        } else if let completedJobId {
            guard sessionMatches(watching, completedSessionId: nil, completedJobId: completedJobId)
            else { return }
        } else {
            return
        }
        guard !didPromoteReadySessionIds.contains(watching) else { return }

        waitTask?.cancel()
        waitTask = Task { @MainActor in
            let plan = await analysisRuntime.refreshSession(sessionId: watching)
                ?? ThreeDExpansionSupport.cachedGuidePlan(sessionId: watching, store: analysisStore)
            guard !Task.isCancelled else { return }
            guard let plan else { return }
            guard watchingAnalysisSessionId() == watching else { return }
            promoteToReady(sessionId: watching, plan: plan, sourceLatLongSessionId: watching)
        }
    }

    private func retryAnalysis(sessionId: String) {
        waitTask?.cancel()
        didPromoteReadySessionIds.remove(sessionId)
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
        // Push may have already promoted this session.
        if didPromoteReadySessionIds.contains(sessionId) { return }
        if case .introStep2 = phase { return }
        if case .guidedCapture = phase { return }

        switch result {
        case .success(let plan):
            promoteToReady(sessionId: sessionId, plan: plan, sourceLatLongSessionId: sessionId)
        case .failure(let error):
            phase = .analysisRecovery(sessionId: sessionId, message: error.userMessage)
        }
    }

    private func startNewCapturePipeline(sessionId: String) {
        waitTask?.cancel()
        waitTask = Task { @MainActor in
            let spaceReady = await waitUntilSpaceReady(sessionId: sessionId)
            guard !Task.isCancelled else { return }
            guard spaceReady else {
                phase = .failed(L("Couldn't finish preparing the space."))
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
