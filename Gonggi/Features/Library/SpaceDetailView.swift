import SwiftUI
import UniformTypeIdentifiers
import WebKit

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
    @State private var showAddObjectSheet = false
    // Build 80 — space audio
    @State private var showAudioImporter = false
    @State private var showAudioRecorder = false
    @State private var showAudioDeleteConfirm = false
    @State private var showAudioReplaceOptions = false
    @State private var isUploadingAudio = false
    @State private var audioError: String?
    @ObservedObject private var spaceAudio = SpaceAudioManager.shared

    private var liveSpace: SpaceRecord {
        appState.spaces.first(where: { $0.id == space.id || $0.sessionId == space.id }) ?? space
    }

    private var audioSpaceKey: String {
        liveSpace.sessionId ?? liveSpace.id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                heroSection
                metaSection
                if let note = liveSpace.note {
                    memoryNoteSection(note)
                }
                spaceAudioSection
                actionsSection
            }
            .padding(GonggiSpacing.lg)
            .padding(.bottom, GonggiSpacing.xxl)
        }
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationBarTitleDisplayMode(.inline)
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
        .alert("이 공간을 삭제할까요?", isPresented: $showDeleteConfirm) {
            Button("삭제", role: .destructive) {
                Task { await performDelete() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이 공간과 연결된 공간 이동도 함께 제거됩니다.\n다른 공간 자체는 삭제되지 않습니다.")
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
        .sheet(isPresented: $showAddObjectSheet) {
            AddObjectToSpaceSheet(onClose: { showAddObjectSheet = false })
                .presentationDetents([.medium])
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

    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            GonggiColors.backgroundElevated,
                            GonggiColors.surface,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 240)
            RadialGradient(
                colors: [GonggiColors.accentTeal.opacity(0.25), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 200
            )
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous))
            Image(systemName: liveSpace.thumbnailSystemImage)
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(GonggiColors.textPrimary.opacity(0.9))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            LinearGradient(
                colors: [.clear, GonggiColors.backgroundPrimary.opacity(0.7)],
                startPoint: .center,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous))
            statusBadge
                .padding(GonggiSpacing.md)
        }
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

            detailRow(icon: "calendar", title: "생성일", value: liveSpace.capturedAt.formatted(date: .long, time: .omitted))
            detailRow(icon: "mappin.and.ellipse", title: "위치", value: "위치 정보 없음")
            detailRow(icon: "circle.fill", title: "상태", value: liveSpace.statusBadgeLabel)
        }
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
            Spacer(minLength: 0)
        }
    }

    private func memoryNoteSection(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            Text("기억 메모")
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.textTertiary)
            GonggiElevatedCard {
                Text(note)
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textSecondary)
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
                PrimaryButton(title: "공간 보기", icon: "cube.transparent") {
                    GonggiHaptics.light()
                    Task { await openViewer() }
                }
                .accessibilityLabel("공간 보기")
            }

            switch liveSpace.status {
            case .ready:
                SecondaryButton(title: "3D 오브젝트 추가", icon: "square.stack.3d.up") {
                    GonggiHaptics.light()
                    showAddObjectSheet = true
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

            // Danger — Build 78 soft-delete (no dead share/rename/location buttons)
            SecondaryButton(title: "공간 삭제", icon: "trash") {
                showDeleteConfirm = true
            }
            .accessibilityLabel("공간 삭제")
        }
        .padding(.top, GonggiSpacing.xs)
    }

    private func openViewer() async {
        isPreparingViewer = true
        defer { isPreparingViewer = false }
        switch await appState.prepareSpaceViewer(jobId: liveSpace.id) {
        case .success(let url):
            let audioURL = liveSpace.audioURL.flatMap(URL.init(string:))
            viewerLaunch = SpaceViewerLaunch(
                single: SpaceViewerSession(id: liveSpace.id, fileURL: url, audioURL: audioURL)
            )
        case .failure(let error):
            viewerError = error.userMessage
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

/// Space → place 3D object navigation shell (picker / create wired in later phases).
struct AddObjectToSpaceSheet: View {
    var onClose: () -> Void
    @State private var showCreate = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
                Text("3D 오브젝트 추가")
                    .font(GonggiTypography.title(22))
                    .foregroundStyle(GonggiColors.textPrimary)
                Text("이 공간에 배치할 어셋을 고르거나 새로 만들 수 있어요.")
                    .font(GonggiTypography.caption(14))
                    .foregroundStyle(GonggiColors.textSecondary)

                optionRow(
                    title: "내 3D 어셋",
                    subtitle: "3D Locker에 있는 어셋에서 선택",
                    icon: "square.grid.2x2"
                ) {
                    // Phase D: asset picker linked to Locker library.
                }
                optionRow(
                    title: "새로 만들기",
                    subtitle: "사진으로 3D 어셋 생성 후 배치",
                    icon: "plus.circle"
                ) {
                    showCreate = true
                }
                Spacer()
            }
            .padding(GonggiSpacing.lg)
            .background(GonggiAmbientBackground(showGlow: false))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { onClose() }
                        .foregroundStyle(GonggiColors.textSecondary)
                }
            }
            .sheet(isPresented: $showCreate) {
                CreateAssetFlowView(onClose: { showCreate = false })
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private func optionRow(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            GonggiHaptics.medium()
            action()
        } label: {
            HStack(spacing: GonggiSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(GonggiColors.accentTeal)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(GonggiTypography.body(16))
                        .foregroundStyle(GonggiColors.textPrimary)
                    Text(subtitle)
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(GonggiColors.textTertiary)
            }
            .padding(GonggiSpacing.md)
            .background(GonggiColors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
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
                        Text("곧 이곳에서 기록한 공간을\n다시 걸어 다닐 수 있어요.")
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
