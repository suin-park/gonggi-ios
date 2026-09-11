import SwiftUI

/// Home tab: public Explore (spaces + 3D assets). Own recent work lives in Library.
struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var exploreSegment: ExploreSegment = .spaces
    @State private var publicSpaces: [PublicSpaceListItem] = []
    @State private var publicAssets: [PublicAssetListItem] = []
    @State private var publicViewerRoute: PublicSpaceSlugRoute?
    @State private var assetQuickLook: ExploreIdentifiedURL?
    @State private var isLoadingExplore = false
    @State private var exploreError: String?
    @State private var viewerLaunch: SpaceViewerLaunch?
    @State private var isPreparingViewer = false
    @State private var viewerError: String?

    private let publicAPI = MobilePublicSpacesAPIClient()

    private var homePublicSpaces: [PublicSpaceListItem] {
        PublicSpacesPolicy.homePreviewLimit(publicSpaces, max: 8)
    }

    private var homePublicAssets: [PublicAssetListItem] {
        Array(publicAssets.prefix(8))
    }

    private func homeTopPadding(for usableHeight: CGFloat) -> CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return GonggiSpacing.md }
        let extra = usableHeight * 0.045
        return GonggiSpacing.lg + min(48, max(24, extra))
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                            .padding(.bottom, GonggiSpacing.lg)

                        actions
                            .padding(.bottom, GonggiSpacing.lg)

                        Picker("둘러보기", selection: $exploreSegment) {
                            ForEach(ExploreSegment.allCases) { segment in
                                Text(segment.title).tag(segment)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.bottom, GonggiSpacing.md)

                        exploreContent
                    }
                    .padding(.horizontal, GonggiSpacing.lg)
                    .padding(.top, homeTopPadding(for: geo.size.height))
                    .padding(.bottom, GonggiSpacing.xxl)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .contentMargins(.bottom, GonggiSpacing.lg, for: .scrollContent)
            }
            .background(GonggiAmbientBackground())
            .navigationBarTitleDisplayMode(.inline)
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
            .task { await loadExplore() }
            .onChange(of: exploreSegment) { _, _ in
                Task { await loadExplore() }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.md) {
            GonggiBrandMark()
            Text("둘러보기")
                .font(GonggiTypography.title(24))
                .foregroundStyle(GonggiColors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("다른 사람이 공개한 공간과 3D 자산을 살펴보세요.")
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textSecondary)
        }
    }

    private var actions: some View {
        VStack(spacing: GonggiSpacing.sm) {
            PrimaryButton(title: "새 공간 촬영", icon: "camera.aperture") {
                appState.selectTab(.record)
            }
            SecondaryButton(title: "보관함", icon: "archivebox") {
                appState.selectTab(.library)
            }
        }
    }

    @ViewBuilder
    private var exploreContent: some View {
        if isLoadingExplore && exploreSegment == .spaces && homePublicSpaces.isEmpty {
            ProgressView("불러오는 중…")
                .frame(maxWidth: .infinity)
                .padding(.top, GonggiSpacing.lg)
        } else if isLoadingExplore && exploreSegment == .assets && homePublicAssets.isEmpty {
            ProgressView("불러오는 중…")
                .frame(maxWidth: .infinity)
                .padding(.top, GonggiSpacing.lg)
        } else {
            switch exploreSegment {
            case .spaces:
                spacesExploreSection
            case .assets:
                assetsExploreSection
            }
        }
    }

    private var spacesExploreSection: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            HStack {
                Text("공간")
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

            if let exploreError, homePublicSpaces.isEmpty {
                Text(exploreError)
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textSecondary)
            } else if homePublicSpaces.isEmpty {
                Text("아직 공개된 공간이 없어요.\n보관함에서 공간 공개 범위를 ‘전체 공개’로 바꾸면 여기에 나타나요.")
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVStack(spacing: GonggiSpacing.md) {
                    ForEach(homePublicSpaces) { item in
                        Button {
                            publicViewerRoute = PublicSpaceSlugRoute(slug: item.publicSlug)
                        } label: {
                            PublicSpaceCardView(item: item)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(GonggiPressableStyle())
                    }
                }
            }
        }
    }

    private var assetsExploreSection: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            HStack {
                Text("3D 자산")
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.textTertiary)
                Spacer(minLength: 0)
                NavigationLink {
                    PublicAssetsListView()
                } label: {
                    Text("전체 보기")
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.accentTeal)
                }
            }

            if let exploreError, homePublicAssets.isEmpty {
                Text(exploreError)
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textSecondary)
            } else if homePublicAssets.isEmpty {
                Text("아직 공개된 3D 자산이 없어요.\n보관함 자산 상세에서 둘러보기에 공개할 수 있어요.")
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVStack(spacing: GonggiSpacing.md) {
                    ForEach(homePublicAssets) { item in
                        PublicAssetCardView(item: item) {
                            Task { await openPublicAssetAR(item) }
                        }
                    }
                }
            }
        }
    }

    private func loadExplore() async {
        isLoadingExplore = true
        exploreError = nil
        defer { isLoadingExplore = false }
        let token = MobileAuthTokenStore.shared.getAccessToken()
        do {
            switch exploreSegment {
            case .spaces:
                let page = try await publicAPI.listPublicSpaces(
                    accessToken: token,
                    limit: 8,
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
            case .assets:
                let page = try await publicAPI.listPublicAssets(
                    accessToken: token,
                    limit: 8,
                    cursor: nil
                )
                publicAssets = page.assets
            }
        } catch {
            exploreError = "공개 목록을 불러오지 못했어요. 잠시 후 다시 시도해 주세요."
            if exploreSegment == .spaces { publicSpaces = [] }
            else { publicAssets = [] }
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
