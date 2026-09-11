import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedSpace: SpaceRecord?
    @State private var viewerLaunch: SpaceViewerLaunch?
    @State private var isPreparingViewer = false
    @State private var viewerError: String?
    @State private var publicSpaces: [PublicSpaceListItem] = []
    @State private var publicViewerRoute: PublicSpaceSlugRoute?

    private let publicAPI = MobilePublicSpacesAPIClient()

    private var recentSpaces: [SpaceRecord] {
        Array(appState.spaces.prefix(5))
    }

    private var homePublicSpaces: [PublicSpaceListItem] {
        PublicSpacesPolicy.homePreviewLimit(publicSpaces, max: 4)
    }

    /// Top padding scales with usable height (~24–48pt extra on tall phones).
    private func homeTopPadding(for usableHeight: CGFloat) -> CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return GonggiSpacing.md }
        let extra = usableHeight * 0.045
        return GonggiSpacing.lg + min(48, max(24, extra))
    }

    /// Mid gap between CTAs and recent work when the list is empty or short.
    private func homeMidMin(for usableHeight: CGFloat) -> CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return GonggiSpacing.md }
        return min(80, max(GonggiSpacing.lg, usableHeight * 0.07))
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let usableHeight = geo.size.height
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                            .padding(.bottom, GonggiSpacing.lg)

                        actions
                            .padding(.bottom, GonggiSpacing.md)

                        if recentSpaces.count <= 1 {
                            Spacer(minLength: homeMidMin(for: usableHeight))
                        } else {
                            // Fixed gap only — do not expand leftover (list should continue naturally).
                            Color.clear.frame(height: GonggiSpacing.xl)
                        }

                        recentSection

                        if PublicSpacesPolicy.shouldShowHomeSection(spaces: homePublicSpaces) {
                            Color.clear.frame(height: GonggiSpacing.xl)
                            publicSpacesSection
                        }
                    }
                    .padding(.horizontal, GonggiSpacing.lg)
                    .padding(.top, homeTopPadding(for: usableHeight))
                    .padding(.bottom, GonggiSpacing.xxl)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: recentSpaces.count <= 1 ? usableHeight : nil,
                        alignment: .top
                    )
                }
                .contentMargins(.bottom, GonggiSpacing.lg, for: .scrollContent)
            }
            .background(GonggiAmbientBackground())
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $selectedSpace) { space in
                SpaceDetailView(space: space)
            }
            .fullScreenCover(item: $publicViewerRoute) { route in
                PublicSpaceViewerLoader(slug: route.slug)
                    .environmentObject(appState)
            }
            .fullScreenCover(item: $viewerLaunch) { launch in
                SpaceVRNavigationHost(
                    sessions: launch.sessions,
                    onClose: { viewerLaunch = nil }
                )
            }
            .task { await loadPublicSpaces() }
            .onChange(of: appState.forceDismissViewerEpoch) { _, _ in
                viewerLaunch = nil
                selectedSpace = nil
                publicViewerRoute = nil
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
        VStack(alignment: .leading, spacing: GonggiSpacing.md) {
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

    private var publicSpacesSection: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            HStack {
                Text("공개 공간")
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.textTertiary)
                Spacer(minLength: 0)
                NavigationLink {
                    PublicSpacesListView()
                } label: {
                    Text("전체 보기")
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.accentTeal)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: GonggiSpacing.md) {
                    ForEach(homePublicSpaces) { item in
                        Button {
                            publicViewerRoute = PublicSpaceSlugRoute(slug: item.publicSlug)
                        } label: {
                            PublicSpaceCardView(item: item)
                        }
                        .buttonStyle(GonggiPressableStyle())
                    }
                }
            }
        }
    }

    private func loadPublicSpaces() async {
        do {
            let page = try await publicAPI.listPublicSpaces(
                accessToken: MobileAuthTokenStore.shared.getAccessToken(),
                limit: 4,
                cursor: nil
            )
            publicSpaces = page.spaces
            if let userId = AuthSessionController.shared.profile?.id
                ?? AuthSessionController.shared.currentUser?.userId
            {
                PublicSpacesAccountStore.saveHomePreviewSlugs(
                    page.spaces.map(\.publicSlug),
                    userId: userId
                )
            }
        } catch {
            publicSpaces = []
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
                    audioURL: AppState.preferredAudioURL(for: jobId),
                    videoURL: AppState.preferredVideoURL(for: jobId)
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
