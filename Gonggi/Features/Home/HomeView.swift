import SwiftUI

/// Home tab: social-style Explore feed (spaces + 3D assets). Own work lives in Library.
struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var exploreSegment: ExploreSegment = .spaces
    @State private var publicSpaces: [PublicSpaceListItem] = []
    @State private var publicAssets: [PublicAssetListItem] = []
    @State private var spacesNextCursor: String?
    @State private var assetsNextCursor: String?
    @State private var publicViewerRoute: PublicSpaceSlugRoute?
    @State private var assetQuickLook: ExploreIdentifiedURL?
    @State private var isLoadingExplore = false
    @State private var isLoadingMore = false
    @State private var exploreError: String?
    @State private var viewerLaunch: SpaceViewerLaunch?
    @State private var isPreparingViewer = false
    @State private var viewerError: String?

    private let publicAPI = MobilePublicSpacesAPIClient()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    feedHeader
                        .padding(.horizontal, GonggiSpacing.lg)
                        .padding(.top, GonggiSpacing.md)
                        .padding(.bottom, GonggiSpacing.sm)

                    Picker("둘러보기", selection: $exploreSegment) {
                        ForEach(ExploreSegment.allCases) { segment in
                            Text(segment.title).tag(segment)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, GonggiSpacing.lg)
                    .padding(.bottom, GonggiSpacing.md)

                    exploreFeed
                }
                .padding(.bottom, GonggiSpacing.xxl)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .refreshable {
                await loadExplore(reset: true)
                await appState.refreshNotificationUnreadCount()
            }
            .contentMargins(.bottom, GonggiSpacing.lg, for: .scrollContent)
            .background(GonggiAmbientBackground())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        NotificationsListView()
                            .environmentObject(appState)
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "bell")
                            if appState.notificationUnreadCount > 0 {
                                Text(appState.notificationUnreadCount > 99
                                      ? "99+"
                                      : "\(appState.notificationUnreadCount)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.red))
                                    .offset(x: 8, y: -8)
                            }
                        }
                    }
                    .accessibilityLabel(
                        appState.notificationUnreadCount > 0
                            ? "알림, 읽지 않음 \(appState.notificationUnreadCount)개"
                            : "알림"
                    )
                }
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
            .sheet(item: $assetQuickLook) { item in
                AssetARQuickLookView(localUsdzURL: item.url)
            }
            .task {
                await loadExplore(reset: true)
                await appState.refreshNotificationUnreadCount()
            }
            .onChange(of: exploreSegment) { _, _ in
                Task { await loadExplore(reset: true) }
            }
            .onChange(of: appState.forceDismissViewerEpoch) { _, _ in
                viewerLaunch = nil
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
                    if let id = appState.pendingViewerJobId {
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
                if hit { viewerLaunch = nil }
            }
        }
    }

    private var feedHeader: some View {
        HStack(alignment: .center, spacing: GonggiSpacing.md) {
            GonggiBrandMark()
            Spacer(minLength: 0)
            Text("둘러보기")
                .font(GonggiTypography.headline(17))
                .foregroundStyle(GonggiColors.textSecondary)
                .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private var exploreFeed: some View {
        let isEmptySpaces = exploreSegment == .spaces && publicSpaces.isEmpty
        let isEmptyAssets = exploreSegment == .assets && publicAssets.isEmpty
        if isLoadingExplore && (isEmptySpaces || isEmptyAssets) {
            ProgressView("불러오는 중…")
                .frame(maxWidth: .infinity)
                .padding(.top, GonggiSpacing.xl)
        } else {
            switch exploreSegment {
            case .spaces:
                spacesFeed
            case .assets:
                assetsFeed
            }
        }
    }

    private var spacesFeed: some View {
        LazyVStack(spacing: 0) {
            if let exploreError, publicSpaces.isEmpty {
                feedEmptyMessage(exploreError)
            } else if publicSpaces.isEmpty {
                feedEmptyMessage("아직 공개된 공간이 없어요.\n보관함에서 공간 공개 범위를 ‘전체 공개’로 바꾸면 여기에 나타나요.")
            } else {
                ForEach(publicSpaces) { item in
                    Button {
                        publicViewerRoute = PublicSpaceSlugRoute(slug: item.publicSlug)
                    } label: {
                        PublicSpaceFeedPostView(item: item)
                    }
                    .buttonStyle(GonggiPressableStyle())
                    .onAppear {
                        if item.id == publicSpaces.last?.id {
                            Task { await loadMore() }
                        }
                    }

                    Divider()
                        .overlay(GonggiColors.borderSubtle)
                        .padding(.leading, GonggiSpacing.lg)
                }

                if isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, GonggiSpacing.md)
                }
            }
        }
    }

    private var assetsFeed: some View {
        LazyVStack(spacing: 0) {
            if let exploreError, publicAssets.isEmpty {
                feedEmptyMessage(exploreError)
            } else if publicAssets.isEmpty {
                feedEmptyMessage("아직 공개된 3D 자산이 없어요.\n보관함 자산 상세에서 둘러보기에 공개할 수 있어요.")
            } else {
                ForEach(publicAssets) { item in
                    PublicAssetFeedPostView(item: item) {
                        Task { await openPublicAssetAR(item) }
                    }
                    .onAppear {
                        if item.id == publicAssets.last?.id {
                            Task { await loadMore() }
                        }
                    }

                    Divider()
                        .overlay(GonggiColors.borderSubtle)
                        .padding(.leading, GonggiSpacing.lg)
                }

                if isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, GonggiSpacing.md)
                }
            }
        }
    }

    private func feedEmptyMessage(_ text: String) -> some View {
        Text(text)
            .font(GonggiTypography.body(15))
            .foregroundStyle(GonggiColors.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, GonggiSpacing.lg)
            .padding(.top, GonggiSpacing.xxl)
    }

    private func loadExplore(reset: Bool) async {
        if reset {
            isLoadingExplore = true
            exploreError = nil
            if exploreSegment == .spaces {
                spacesNextCursor = nil
            } else {
                assetsNextCursor = nil
            }
        }
        defer { isLoadingExplore = false }
        let token = MobileAuthTokenStore.shared.getAccessToken()
        do {
            switch exploreSegment {
            case .spaces:
                let page = try await publicAPI.listPublicSpaces(
                    accessToken: token,
                    limit: 12,
                    cursor: nil
                )
                publicSpaces = page.spaces
                spacesNextCursor = page.nextCursor
                if let userId = AuthSessionController.shared.profile?.id
                    ?? AuthSessionController.shared.currentUser?.userId
                {
                    PublicSpacesAccountStore.saveHomePreviewSlugs(
                        page.spaces.map(\.publicSlug),
                        userId: userId
                    )
                }
            case .assets:
                let page = try await publicAPI.listPublicAssets(
                    accessToken: token,
                    limit: 12,
                    cursor: nil
                )
                publicAssets = page.assets
                assetsNextCursor = page.nextCursor
            }
        } catch {
            exploreError = "공개 목록을 불러오지 못했어요. 잠시 후 다시 시도해 주세요."
            if exploreSegment == .spaces { publicSpaces = [] }
            else { publicAssets = [] }
        }
    }

    private func loadMore() async {
        guard !isLoadingMore, !isLoadingExplore else { return }
        let token = MobileAuthTokenStore.shared.getAccessToken()
        switch exploreSegment {
        case .spaces:
            guard let cursor = spacesNextCursor else { return }
            isLoadingMore = true
            defer { isLoadingMore = false }
            do {
                let page = try await publicAPI.listPublicSpaces(
                    accessToken: token,
                    limit: 12,
                    cursor: cursor
                )
                let merged = PublicSpacesPolicy.mergePaginatedPage(
                    existing: publicSpaces,
                    page: page,
                    replacing: false
                )
                publicSpaces = merged.spaces
                spacesNextCursor = merged.nextCursor
            } catch {
                // Keep current feed on pagination failure.
            }
        case .assets:
            guard let cursor = assetsNextCursor else { return }
            isLoadingMore = true
            defer { isLoadingMore = false }
            do {
                let page = try await publicAPI.listPublicAssets(
                    accessToken: token,
                    limit: 12,
                    cursor: cursor
                )
                let existing = Set(publicAssets.map(\.id))
                publicAssets.append(contentsOf: page.assets.filter { !existing.contains($0.id) })
                assetsNextCursor = page.nextCursor
            } catch {
                // Keep current feed on pagination failure.
            }
        }
    }

    private func openPublicAssetAR(_ item: PublicAssetListItem) async {
        guard item.availableForAR,
              let remoteStr = item.usdzUrl,
              let remote = URL(string: remoteStr)
        else {
            exploreError = "AR을 준비할 수 없어요."
            return
        }
        guard let local = await VRUsdzCache().localURL(assetId: item.id, remoteURL: remote) else {
            exploreError = "AR 파일을 불러오지 못했어요."
            return
        }
        assetQuickLook = ExploreIdentifiedURL(url: local)
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

enum ExploreSegment: String, CaseIterable, Identifiable {
    case spaces
    case assets

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spaces: return "공간"
        case .assets: return "3D 자산"
        }
    }
}

private struct ExploreIdentifiedURL: Identifiable {
    let id = UUID()
    let url: URL
}

#Preview {
    HomeView()
        .environmentObject(AppState(isMockMode: true))
}
