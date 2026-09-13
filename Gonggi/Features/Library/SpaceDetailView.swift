import SwiftUI
import UniformTypeIdentifiers
import WebKit
#if canImport(UIKit)
import UIKit
#endif

struct SpaceDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let space: SpaceRecord
    @State private var showViewer = false
    @State private var showDeleteConfirm = false
    @State private var viewerLaunch: SpaceViewerLaunch?
    @State private var isPreparingViewer = false
    @State private var isDeleting = false
    @State private var viewerError: String?
    @State private var deleteError: String?
    @State private var showEditSheet = false
    @State private var showShareSheet = false
    @State private var showVisibilitySheet = false
    // Build 80 — space audio
    @State private var showAudioImporter = false
    @State private var showAudioRecorder = false
    @State private var showAudioDeleteConfirm = false
    @State private var showAudioReplaceOptions = false
    @State private var isUploadingAudio = false
    @State private var audioError: String?
    @ObservedObject private var spaceAudio = SpaceAudioManager.shared
    @ObservedObject private var advancedCaptureStore = AdvancedCaptureAnalysisStore.shared

    @State private var showAdvancedAnalyzeConfirm = false
    @State private var isStartingAdvancedAnalyze = false
    @State private var advancedAnalyzeError: String?
    @State private var showGuidedCapture = false
    @State private var guidedPlan: AdvancedCaptureGuidePlan?
    @State private var showGaussianViewer = false

    private var liveSpace: SpaceRecord {
        appState.spaces.first(where: { $0.id == space.id || $0.sessionId == space.id }) ?? space
    }

    private var audioSpaceKey: String {
        liveSpace.sessionId ?? liveSpace.id
    }

    private var advancedSessionKey: String {
        ThreeDExpansionSupport.sessionKey(for: liveSpace)
    }

    private var advancedRecord: AdvancedCaptureAnalysisRecord? {
        advancedCaptureStore.record(sessionId: advancedSessionKey)
    }

    var body: some View {
        detailChrome
            .onChange(of: appState.forceDismissViewerEpoch) { _, _ in
                handleAccountForcedDismiss()
            }
            .alert("공간을 불러오지 못했어요", isPresented: Binding(
                get: { viewerError != nil },
                set: { if !$0 { viewerError = nil } }
            )) {
                Button("다시 불러오기") {
                    Task { await openViewer() }
                }
                Button("닫기", role: .cancel) { viewerError = nil }
            } message: {
                Text(viewerError ?? "")
            }
            .confirmationDialog("이 공간을 삭제할까요?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("삭제", role: .destructive) {
                    Task { await performDelete() }
                }
                Button("취소", role: .cancel) {}
            }
        .alert("삭제하지 못했어요", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("확인", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .alert("공간 오디오를 삭제할까요?", isPresented: $showAudioDeleteConfirm) {
            Button("삭제", role: .destructive) {
                Task { await deleteSpaceAudio() }
            }
            Button("취소", role: .cancel) {}
        }
        .confirmationDialog("오디오 교체", isPresented: $showAudioReplaceOptions, titleVisibility: .visible) {
            Button("파일에서 선택") { showAudioImporter = true }
            Button("직접 녹음") { showAudioRecorder = true }
            Button("취소", role: .cancel) {}
        }
        .alert("오디오를 처리하지 못했어요", isPresented: Binding(
            get: { audioError != nil },
            set: { if !$0 { audioError = nil } }
        )) {
            Button("확인", role: .cancel) { audioError = nil }
        } message: {
            Text(audioError ?? "")
        }
        .alert("분석을 시작하지 못했어요", isPresented: Binding(
            get: { advancedAnalyzeError != nil },
            set: { if !$0 { advancedAnalyzeError = nil } }
        )) {
            Button("확인", role: .cancel) { advancedAnalyzeError = nil }
        } message: {
            Text(advancedAnalyzeError ?? "")
        }
        .fullScreenCover(isPresented: $showGuidedCapture) {
            if let plan = guidedPlan {
                Guided3DGSCaptureFlowView(
                    plan: plan,
                    sessionId: advancedSessionKey,
                    sourceLatLongSessionId: advancedSessionKey,
                    onClose: { showGuidedCapture = false }
                )
                .environmentObject(appState)
            }
        }
        .fullScreenCover(isPresented: $showGaussianViewer) {
            if let spaceId = advancedRecord?.linkedGaussianSpaceId {
                GaussianSplatWebViewer(spaceId: spaceId) {
                    showGaussianViewer = false
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            SpaceShareSheet(
                spaceId: liveSpace.sessionId ?? liveSpace.id,
                spaceName: liveSpace.name,
                onClose: { showShareSheet = false }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showVisibilitySheet) {
            SpaceVisibilityPickerSheet(
                spaceId: liveSpace.sessionId ?? liveSpace.id,
                onClose: { showVisibilitySheet = false }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showEditSheet) {
            SpaceDetailEditView(space: liveSpace)
                .environmentObject(appState)
                .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAudioRecorder) {
            SpaceAudioRecordingSheet(
                onCancel: { showAudioRecorder = false },
                onUse: { url, duration in
                    showAudioRecorder = false
                    Task { await uploadSpaceAudio(fileURL: url, source: .recording, durationSec: duration) }
                }
            )
            .presentationDetents([.medium, .large])
        }
        .fileImporter(
            isPresented: $showAudioImporter,
            allowedContentTypes: SpaceAudioPolicy.importContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await importAndUpload(url) }
            case .failure:
                audioError = SpaceAudioAPIError.generic.userMessage
            }
        }
    }

    private func handleAccountForcedDismiss() {
        viewerLaunch = nil
        showViewer = false
        dismiss()
    }

    private var detailChrome: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                    heroSection
                    metaSection
                    memoryNoteSection
                    spaceAudioSection
                    actionsSection
                        .id("space-detail-actions")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, GonggiSpacing.lg)
                .padding(.top, GonggiSpacing.lg)
                // Bottom: stay clear of TabView chrome without double safe-area stacking.
                .padding(.bottom, GonggiSpacing.xxl)
            }
            .contentMargins(.bottom, GonggiSpacing.md, for: .scrollContent)
            .onChange(of: showAdvancedAnalyzeConfirm) { _, show in
                guard show else { return }
                withAnimation(GonggiMotion.quick) {
                    proxy.scrollTo("space-detail-actions", anchor: .center)
                }
            }
            #if DEBUG
            .onAppear {
                guard ScreenshotLaunchConfig.screen == .spaceDetailScrolled else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo("space-detail-actions", anchor: .bottom)
                    }
                }
            }
            #endif
        }
        // Keep chrome background edge-to-edge without expanding ScrollView into tab/home unsafe areas.
        .background {
            GonggiAmbientBackground(showGlow: false)
                .ignoresSafeArea()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("공개 범위", systemImage: "eye") {
                        showVisibilitySheet = true
                    }
                    .disabled(liveSpace.status != .ready)
                    Button("공간 삭제", systemImage: "trash", role: .destructive) {
                        showDeleteConfirm = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                Button("편집") {
                    showEditSheet = true
                }
            }
        }
        .disabled(isDeleting || isUploadingAudio)
        .overlay {
            if isDeleting || isUploadingAudio {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView().tint(.white).scaleEffect(1.2)
                }
            }
        }
        .sheet(isPresented: $showViewer) {
            ViewerPlaceholderView(space: liveSpace)
        }
        .fullScreenCover(item: $viewerLaunch) { launch in
            SpaceVRNavigationHost(
                sessions: launch.sessions,
                onClose: { viewerLaunch = nil }
            )
        }
        .overlay {
            if isPreparingViewer {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView().tint(.white).scaleEffect(1.2)
                }
            }
        }
    }

    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            SpaceThumbnailView(
                space: liveSpace,
                height: 240,
                cornerRadius: GonggiRadius.xl,
                showsActivityOverlay: true
            )
            LinearGradient(
                colors: [.clear, GonggiColors.backgroundPrimary.opacity(0.7)],
                startPoint: .center,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
            statusBadge
                .padding(GonggiSpacing.md)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous)
                .stroke(GonggiColors.border, lineWidth: 1)
        )
        .accessibilityLabel("\(liveSpace.name) 미리보기")
    }

    private var metaSection: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.md) {
            Text(liveSpace.name)
                .font(GonggiTypography.title(26))
                .foregroundStyle(GonggiColors.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            detailRow(
                icon: "calendar",
                title: "생성일",
                value: liveSpace.capturedAt.formatted(
                    .dateTime.year().month().day().locale(Locale(identifier: "ko_KR"))
                )
            )
            detailRow(icon: "mappin.and.ellipse", title: "위치", value: liveSpace.locationDisplayLabel)
            detailRow(icon: "circle.fill", title: "상태", value: liveSpace.statusBadgeLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailRow(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: GonggiSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GonggiColors.textTertiary)
                .frame(width: 18)
            Text(title)
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.textTertiary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var memoryNoteSection: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            Text("메모")
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.textTertiary)
            GonggiElevatedCard {
                Text(liveSpace.memo?.isEmpty == false
                    ? liveSpace.memo!
                    : "이 공간에 대한 메모를 남겨보세요.")
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(
                        liveSpace.memo?.isEmpty == false
                            ? GonggiColors.textSecondary
                            : GonggiColors.textTertiary
                    )
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var spaceAudioSection: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            Text("공간 오디오")
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.textTertiary)

            GonggiElevatedCard {
                if liveSpace.hasSpaceAudio {
                    VStack(alignment: .leading, spacing: GonggiSpacing.md) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(liveSpace.audioFileName ?? "오디오")
                                    .font(GonggiTypography.body(15))
                                    .foregroundStyle(GonggiColors.textPrimary)
                                    .lineLimit(2)
                                Text(SpaceAudioPolicy.formatDuration(liveSpace.audioDurationSec))
                                    .font(GonggiTypography.caption(13))
                                    .foregroundStyle(GonggiColors.textTertiary)
                            }
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: GonggiSpacing.sm) {
                            SecondaryButton(title: "재생", icon: "play.fill") {
                                Task { await previewSpaceAudio() }
                            }
                            SecondaryButton(title: "교체", icon: "arrow.triangle.2.circlepath") {
                                showAudioReplaceOptions = true
                            }
                        }
                        SecondaryButton(title: "삭제", icon: "trash") {
                            showAudioDeleteConfirm = true
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: GonggiSpacing.md) {
                        Text("이 공간에 소리를 함께 남겨 둘 수 있어요.")
                            .font(GonggiTypography.body(15))
                            .foregroundStyle(GonggiColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        SecondaryButton(title: "파일 추가", icon: "doc.badge.plus") {
                            showAudioImporter = true
                        }
                        SecondaryButton(title: "직접 녹음", icon: "mic.fill") {
                            showAudioRecorder = true
                        }
                    }
                }
            }
        }
    }

    private var actionsSection: some View {
        VStack(spacing: GonggiSpacing.sm) {
            // Primary: viewer when ready
            if liveSpace.canOpenExistingVR {
                PrimaryButton(title: "360° 보기", icon: "cube.transparent") {
                    GonggiHaptics.light()
                    Task { await openViewer() }
                }
                .accessibilityLabel("360° 보기")

                advancedCaptureActions
            }

            switch liveSpace.status {
            case .ready:
                if let note = liveSpace.note, !note.isEmpty {
                    GonggiElevatedCard {
                        HStack(spacing: GonggiSpacing.md) {
                            if liveSpace.note == "공간을 불러오는 중…" {
                                ProgressView()
                                    .tint(GonggiColors.accentTeal)
                            }
                            Text(note)
                                .font(GonggiTypography.body(15))
                                .foregroundStyle(GonggiColors.textSecondary)
                            Spacer(minLength: 0)
                            if liveSpace.note != "공간을 불러오는 중…" {
                                Button("다시 시도") {
                                    Task { await openViewer() }
                                }
                                .font(GonggiTypography.caption(13))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            case .failed:
                PrimaryButton(title: "다시 시도", icon: "arrow.clockwise") {
                    GonggiHaptics.medium()
                    appState.retrySpaceGeneration(jobId: liveSpace.id)
                }
            case .processing, .uploading:
                GonggiElevatedCard {
                    HStack(spacing: GonggiSpacing.md) {
                        ProgressView()
                            .tint(GonggiColors.accentTeal)
                        Text(liveSpace.note ?? "공간을 만들고 있어요")
                            .font(GonggiTypography.body(15))
                            .foregroundStyle(GonggiColors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .draft:
                PrimaryButton(title: "이어서 보기", icon: "cube.transparent") {
                    showViewer = true
                }
            }

            SecondaryButton(title: "공유", icon: "square.and.arrow.up") {
                showShareSheet = true
            }
            .accessibilityLabel("공유")
            .disabled(liveSpace.status != .ready)
        }
        .padding(.top, GonggiSpacing.xs)
    }

    @ViewBuilder
    private var advancedCaptureActions: some View {
        let record = advancedRecord
        if let record, record.status.isInFlight {
            GonggiElevatedCard {
                HStack(spacing: GonggiSpacing.md) {
                    ProgressView()
                        .tint(GonggiColors.accentTeal)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("입체 기록을 위한 분석을 진행 중이에요")
                            .font(GonggiTypography.body(15))
                            .foregroundStyle(GonggiColors.textSecondary)
                        Text("앱을 나가도 분석은 계속됩니다")
                            .font(GonggiTypography.caption(12))
                            .foregroundStyle(GonggiColors.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let record, record.canOpenGaussianViewer {
            // 3D space already exists — show viewer only (no expand CTA).
            SecondaryButton(title: "3D 공간 보기", icon: "move.3d") {
                GonggiHaptics.medium()
                showGaussianViewer = true
            }
            .accessibilityLabel("3D 공간 보기")
        } else if let record, record.canStartGuidedCapture,
                  let plan = ThreeDExpansionSupport.cachedGuidePlan(sessionId: advancedSessionKey)
                    ?? record.guidePlan.map(AdvancedCaptureCopy.sanitize)
        {
            SecondaryButton(title: "입체 기록 시작", icon: "figure.walk") {
                GonggiHaptics.medium()
                guidedPlan = plan
                showGuidedCapture = true
            }
            .accessibilityLabel("입체 기록 시작")
        } else if let record, record.status == .failed {
            if showAdvancedAnalyzeConfirm {
                AdvancedAnalyzeConfirmCard(
                    isStarting: isStartingAdvancedAnalyze,
                    onStart: {
                        GonggiHaptics.medium()
                        showAdvancedAnalyzeConfirm = false
                        Task { await startAdvancedAnalyze() }
                    },
                    onDismiss: { showAdvancedAnalyzeConfirm = false }
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            SecondaryButton(title: "3D 공간으로 확장 다시 시도", icon: "arrow.clockwise") {
                GonggiHaptics.medium()
                withAnimation(GonggiMotion.quick) {
                    showAdvancedAnalyzeConfirm = true
                }
            }
            if let msg = record.lastErrorMessage ?? record.lastErrorCode {
                Text(msg)
                    .font(GonggiTypography.caption(12))
                    .foregroundStyle(GonggiColors.warning)
            }
        } else {
            if showAdvancedAnalyzeConfirm {
                AdvancedAnalyzeConfirmCard(
                    isStarting: isStartingAdvancedAnalyze,
                    onStart: {
                        GonggiHaptics.medium()
                        showAdvancedAnalyzeConfirm = false
                        Task { await startAdvancedAnalyze() }
                    },
                    onDismiss: { showAdvancedAnalyzeConfirm = false }
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            SecondaryButton(title: "3D 공간으로 확장", icon: "cube.transparent") {
                GonggiHaptics.medium()
                withAnimation(GonggiMotion.quick) {
                    showAdvancedAnalyzeConfirm.toggle()
                }
            }
            .accessibilityLabel("3D 공간으로 확장")
            .disabled(isStartingAdvancedAnalyze)
        }
    }

    private func openViewer() async {
        isPreparingViewer = true
        defer { isPreparingViewer = false }
        switch await appState.prepareSpaceViewer(jobId: liveSpace.id) {
        case .success(let url):
            let audioURL = liveSpace.audioURL.flatMap(URL.init(string:))
            viewerLaunch = SpaceViewerLaunch(
                single: SpaceViewerSession(
                    id: liveSpace.id,
                    fileURL: url,
                    audioURL: audioURL,
                    videoURL: AppState.preferredVideoURL(for: liveSpace.id)
                )
            )
        case .failure(let error):
            viewerError = error.userMessage
        }
    }

    private func startAdvancedAnalyze() async {
        isStartingAdvancedAnalyze = true
        defer { isStartingAdvancedAnalyze = false }
        // Same pipeline as Record → 기존 공간에서 시작 (LatLong never overwritten).
        switch await ThreeDExpansionSupport.startOrReuseAnalysis(
            sessionId: advancedSessionKey,
            useMock: appState.isMockMode
        ) {
        case .success:
            break
        case .failure(let error):
            advancedAnalyzeError = error.userMessage
        }
    }

    private func performDelete() async {
        isDeleting = true
        defer { isDeleting = false }
        viewerLaunch = nil
        switch await appState.deleteSpace(jobId: liveSpace.id) {
        case .success:
            GonggiHaptics.medium()
            dismiss()
        case .failure(let error):
            deleteError = error.userMessage
        }
    }

    private func importAndUpload(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        await uploadSpaceAudio(fileURL: url, source: .upload, durationSec: nil)
    }

    private func uploadSpaceAudio(fileURL: URL, source: SpaceAudioSource, durationSec: Double?) async {
        isUploadingAudio = true
        defer { isUploadingAudio = false }
        do {
            let meta = try await SpaceAudioStore.shared.uploadFile(
                spaceId: audioSpaceKey,
                fileURL: fileURL,
                source: source,
                durationSec: durationSec
            )
            applyAudioToLocalJob(meta)
            GonggiHaptics.light()
        } catch {
            audioError = SpaceAudioPolicy.userMessage(for: error)
        }
    }

    private func deleteSpaceAudio() async {
        isUploadingAudio = true
        defer { isUploadingAudio = false }
        do {
            try await SpaceAudioStore.shared.deleteAudio(spaceId: audioSpaceKey)
            applyAudioToLocalJob(.empty)
            if spaceAudio.currentSpaceId == audioSpaceKey || spaceAudio.currentSpaceId == liveSpace.id {
                spaceAudio.stop()
            }
            GonggiHaptics.light()
        } catch {
            audioError = SpaceAudioPolicy.userMessage(for: error)
        }
    }

    private func previewSpaceAudio() async {
        guard let raw = liveSpace.audioURL, let url = URL(string: raw) else {
            audioError = SpaceAudioAPIError.generic.userMessage
            return
        }
        await spaceAudio.play(url: url, spaceId: audioSpaceKey, fadeIn: true)
    }

    private func applyAudioToLocalJob(_ meta: SpaceAudioMetadata) {
        let store = SpaceJobStore.shared
        if let job = store.job(id: liveSpace.id)
            ?? store.jobs.first(where: { $0.sessionId == liveSpace.id || $0.sessionId == liveSpace.sessionId })
        {
            store.update(jobId: job.jobId) { $0.applyAudio(meta) }
        }
        appState.rebuildSpaces()
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(GonggiColors.statusColor(forBadge: liveSpace.repairBadge, fallback: liveSpace.status))
                .frame(width: 7, height: 7)
            Text(liveSpace.statusBadgeLabel)
        }
        .font(GonggiTypography.caption(13))
        .foregroundStyle(GonggiColors.statusColor(forBadge: liveSpace.repairBadge, fallback: liveSpace.status))
        .padding(.horizontal, GonggiSpacing.sm)
        .padding(.vertical, GonggiSpacing.xs)
        .background(GonggiColors.backgroundPrimary.opacity(0.65))
        .clipShape(Capsule())
    }
}

struct ViewerPlaceholderView: View {
    let space: SpaceRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let url = space.viewerURL {
                    WebView(url: url)
                } else {
                    VStack(spacing: GonggiSpacing.lg) {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 56, weight: .ultraLight))
                            .foregroundStyle(GonggiColors.accentTeal)
                        Text("3D 공간 뷰어")
                            .font(GonggiTypography.headline(20))
                            .foregroundStyle(GonggiColors.textPrimary)
                        Text("이 공간은 아직 뷰어를 열 수 없어요.")
                            .font(GonggiTypography.body(15))
                            .foregroundStyle(GonggiColors.textSecondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                    }
                    .padding(GonggiSpacing.xl)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GonggiAmbientBackground(showGlow: false))
            .navigationTitle(space.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                        .foregroundStyle(GonggiColors.textSecondary)
                }
            }
        }
    }
}

/// Inline confirm card anchored above the 「3D 공간으로 확장」 button (replaces broken confirmationDialog).
private struct AdvancedAnalyzeConfirmCard: View {
    var isStarting: Bool
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
                HStack(alignment: .top) {
                    Text("입체 기록을 위한 분석을 시작합니다.")
                        .font(GonggiTypography.headline(16))
                        .foregroundStyle(GonggiColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: GonggiSpacing.sm)
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(GonggiColors.textTertiary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("닫기")
                }

                Text("이미 촬영한 360° 공간을 바탕으로 걸으며 촬영할 가이드를 만들어요. 앱을 나가도 분석은 계속됩니다.")
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    guard !isStarting else { return }
                    onStart()
                } label: {
                    HStack(spacing: GonggiSpacing.xs) {
                        if isStarting {
                            ProgressView()
                                .tint(GonggiColors.accentCyan)
                        }
                        Text(isStarting ? "분석 시작 중…" : "분석 시작")
                            .font(GonggiTypography.headline(16))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(GonggiColors.accentCyan)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isStarting)
                .accessibilityLabel("분석 시작")
            }
            .padding(GonggiSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                    .fill(GonggiColors.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                    .stroke(GonggiColors.border, lineWidth: 1)
            )

            // Tip pointing down toward the expand button below.
            AdvancedAnalyzeConfirmCardTip()
                .fill(GonggiColors.surfaceElevated)
                .frame(width: 18, height: 10)
                .padding(.top, -1)
        }
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
    }
}

private struct AdvancedAnalyzeConfirmCardTip: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.isOpaque = false
        web.backgroundColor = .clear
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

#Preview {
    NavigationStack {
        SpaceDetailView(space: SpaceRecord.sampleArchive[0])
            .environmentObject(AppState(isMockMode: true))
    }
}
