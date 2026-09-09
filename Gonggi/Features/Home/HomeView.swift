import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedSpace: SpaceRecord?
    @State private var viewerLaunch: SpaceViewerLaunch?
    @State private var isPreparingViewer = false
    @State private var viewerError: String?

    private var recentSpaces: [SpaceRecord] {
        Array(appState.spaces.prefix(5))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GonggiSpacing.xl) {
                    header
                    actions
                    recentSection
                }
                .padding(GonggiSpacing.lg)
                .padding(.bottom, GonggiSpacing.xxl)
            }
            .background(GonggiAmbientBackground())
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $selectedSpace) { space in
                SpaceDetailView(space: space)
            }
            .fullScreenCover(item: $viewerLaunch) { launch in
                SpaceVRNavigationHost(
                    sessions: launch.sessions,
                    onClose: { viewerLaunch = nil }
                )
            }
            .onChange(of: appState.forceDismissViewerEpoch) { _, _ in
                viewerLaunch = nil
                selectedSpace = nil
            }
            .overlay {
                if isPreparingViewer {
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea()
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.2)
                    }
                }
            }
            .alert("공간을 불러오지 못했어요", isPresented: Binding(
                get: { viewerError != nil || appState.pendingViewerError != nil },
                set: {
                    if !$0 {
                        viewerError = nil
                        appState.pendingViewerError = nil
                    }
                }
            )) {
                Button("다시 불러오기") {
                    if let id = appState.pendingViewerJobId ?? selectedSpace?.id ?? recentSpaces.first?.id {
                        Task { await openViewer(jobId: id) }
                    }
                }
                Button("닫기", role: .cancel) {
                    viewerError = nil
                    appState.pendingViewerError = nil
                }
            } message: {
                Text(viewerError ?? appState.pendingViewerError ?? "")
            }
            .onChange(of: appState.pendingViewerJobId) { _, jobId in
                guard let jobId else { return }
                Task {
                    await openViewer(jobId: jobId)
                    appState.pendingViewerJobId = nil
                }
            }
            .onChange(of: appState.pendingViewerLaunch) { _, launch in
                guard let launch else { return }
                viewerLaunch = launch
                appState.pendingViewerLaunch = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .gonggiSpaceDidDelete)) { note in
                let sessionId = note.userInfo?["sessionId"] as? String
                let jobId = note.userInfo?["jobId"] as? String
                guard let launch = viewerLaunch else { return }
                let hit = launch.sessions.contains {
                    $0.id == sessionId || $0.id == jobId
                }
                if hit {
                    viewerLaunch = nil
                }
                if selectedSpace?.id == jobId || selectedSpace?.sessionId == sessionId {
                    selectedSpace = nil
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            GonggiBrandMark()
            Text("무엇을 시작할까요?")
                .font(GonggiTypography.title(24))
                .foregroundStyle(GonggiColors.textPrimary)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var actions: some View {
        VStack(spacing: GonggiSpacing.sm) {
            PrimaryButton(title: "새 공간 촬영", icon: "camera.aperture") {
                appState.selectTab(.record)
            }
            SecondaryButton(title: "공간 관리", icon: "archivebox") {
                appState.selectTab(.library)
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            Text("최근 작업")
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.textTertiary)

            if recentSpaces.isEmpty {
                Text("아직 만든 공간이 없어요.")
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, GonggiSpacing.xs)
            } else {
                ForEach(recentSpaces) { space in
                    Button {
                        handleSpaceTap(space)
                    } label: {
                        HStack(spacing: GonggiSpacing.md) {
                            SpaceThumbnailView(
                                space: space,
                                height: 56,
                                width: 56,
                                cornerRadius: GonggiRadius.sm,
                                showsActivityOverlay: true
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(space.name)
                                    .font(GonggiTypography.headline(16))
                                    .foregroundStyle(GonggiColors.textPrimary)
                                    .lineLimit(1)
                                Text(recentSubtitle(for: space))
                                    .font(GonggiTypography.caption(12))
                                    .foregroundStyle(
                                        space.repairBadge == .repairFailed || space.status == .failed
                                            ? GonggiColors.error
                                            : GonggiColors.textTertiary
                                    )
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
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
                    .buttonStyle(GonggiPressableStyle())
                    .accessibilityLabel("\(space.name), 상세 보기")
                }
            }
        }
    }

    private func recentSubtitle(for space: SpaceRecord) -> String {
        if space.status == .ready {
            return space.capturedAt.formatted(date: .abbreviated, time: .omitted)
        }
        if let note = space.note, !note.isEmpty {
            return note
        }
        return space.statusBadgeLabel
    }

    private func handleSpaceTap(_ space: SpaceRecord) {
        selectedSpace = space
    }

    private func openViewer(jobId: String) async {
        isPreparingViewer = true
        defer { isPreparingViewer = false }
        let result = await appState.prepareSpaceViewer(jobId: jobId)
        switch result {
        case .success(let url):
            viewerLaunch = SpaceViewerLaunch(
                single: SpaceViewerSession(
                    id: jobId,
                    fileURL: url,
                    audioURL: AppState.preferredAudioURL(for: jobId)
                )
            )
        case .failure(let error):
            viewerError = error.userMessage
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState(isMockMode: true))
}
