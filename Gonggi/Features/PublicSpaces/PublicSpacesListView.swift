import SwiftUI

struct PublicSpacesListView: View {
    @State private var spaces: [PublicSpaceListItem] = []
    @State private var nextCursor: String?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var loadError: String?
    @State private var selectedRoute: PublicSpaceSlugRoute?
    @State private var didInitialLoad = false
    @EnvironmentObject private var appState: AppState

    private let api = MobilePublicSpacesAPIClient()

    var body: some View {
        Group {
            if isLoading && spaces.isEmpty {
                ProgressView("불러오는 중…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError, spaces.isEmpty {
                VStack(spacing: GonggiSpacing.md) {
                    Text(loadError)
                        .font(GonggiTypography.body(15))
                        .foregroundStyle(GonggiColors.textSecondary)
                        .multilineTextAlignment(.center)
                    SecondaryButton(title: "다시 시도", icon: "arrow.clockwise") {
                        Task { await reload() }
                    }
                    .frame(maxWidth: 220)
                }
                .padding(GonggiSpacing.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if spaces.isEmpty {
                Text("아직 공개된 공간이 없어요.")
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(spaces) { item in
                        Button {
                            selectedRoute = PublicSpaceSlugRoute(slug: item.publicSlug)
                        } label: {
                            HStack(alignment: .top, spacing: GonggiSpacing.md) {
                                PublicSpaceRemoteThumbnail(
                                    thumbnailUrl: item.thumbnailUrl,
                                    width: 88,
                                    height: 66
                                )
                                .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous))

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(item.title)
                                            .font(GonggiTypography.headline(16))
                                            .foregroundStyle(GonggiColors.textPrimary)
                                            .lineLimit(2)
                                        Spacer(minLength: 0)
                                        Image(systemName: "pano.fill")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(GonggiColors.textTertiary)
                                    }
                                    Text(item.publisherDisplayName)
                                        .font(GonggiTypography.caption(13))
                                        .foregroundStyle(GonggiColors.textSecondary)
                                    if PublicSpacesPolicy.shouldShowEngagementCountsOnCard() {
                                        HStack(spacing: GonggiSpacing.sm) {
                                            Label(
                                                PublicSpacesPolicy.engagementCountLabel(item.likeCount),
                                                systemImage: "heart"
                                            )
                                            Label(
                                                PublicSpacesPolicy.engagementCountLabel(item.commentCount),
                                                systemImage: "bubble.right"
                                            )
                                        }
                                        .font(GonggiTypography.caption(12))
                                        .foregroundStyle(GonggiColors.textTertiary)
                                        .labelStyle(.titleAndIcon)
                                    }
                                    Text(PublicSpaceCardView.formatPublished(item.publishedAt))
                                        .font(GonggiTypography.caption(12))
                                        .foregroundStyle(GonggiColors.textTertiary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if item.publicSlug == spaces.last?.publicSlug {
                                Task { await loadMore() }
                            }
                        }
                    }

                    if isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .refreshable { await reload() }
            }
        }
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle("공개 공간")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $selectedRoute) { route in
            PublicSpaceViewerLoader(slug: route.slug)
                .environmentObject(appState)
        }
        .task {
            guard !didInitialLoad else { return }
            didInitialLoad = true
            await reload()
        }
    }

    private func reload() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let page = try await api.listPublicSpaces(
                accessToken: MobileAuthTokenStore.shared.getAccessToken(),
                limit: 20,
                cursor: nil
            )
            let merged = PublicSpacesPolicy.mergePaginatedPage(existing: [], page: page, replacing: true)
            spaces = merged.spaces
            nextCursor = merged.nextCursor
            if let userId = AuthSessionController.shared.profile?.id
                ?? AuthSessionController.shared.currentUser?.userId
            {
                PublicSpacesAccountStore.saveHomePreviewSlugs(
                    Array(merged.spaces.prefix(4).map(\.publicSlug)),
                    userId: userId
                )
                PublicSpacesAccountStore.saveListCursor(merged.nextCursor, userId: userId)
            }
        } catch let err as MobileAuthAPIError {
            loadError = err.publicSpacesMessage
        } catch {
            loadError = "공개 공간을 불러오지 못했어요. 잠시 후 다시 시도해주세요."
        }
    }

    private func loadMore() async {
        guard let nextCursor, !nextCursor.isEmpty, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await api.listPublicSpaces(
                accessToken: MobileAuthTokenStore.shared.getAccessToken(),
                limit: 20,
                cursor: nextCursor
            )
            let merged = PublicSpacesPolicy.mergePaginatedPage(existing: spaces, page: page, replacing: false)
            spaces = merged.spaces
            self.nextCursor = merged.nextCursor
            if let userId = AuthSessionController.shared.profile?.id ?? AuthSessionController.shared.currentUser?.userId {
                PublicSpacesAccountStore.saveListCursor(merged.nextCursor, userId: userId)
            }
        } catch {
            // Keep existing list; silent fail on pagination.
        }
    }
}

private extension MobileAuthAPIError {
    var publicSpacesMessage: String {
        switch self {
        case .network:
            return "네트워크에 연결할 수 없습니다."
        case .invalidResponse:
            return "공개 공간을 불러오지 못했어요. 잠시 후 다시 시도해주세요."
        case .server(_, let message, _):
            return PublicSpacesAPIMessageSanitizer.safeMessage(
                message,
                fallback: "공개 공간을 불러오지 못했어요. 잠시 후 다시 시도해주세요."
            )
        }
    }
}

/// Loads public detail + panorama, then presents read-only VR.
struct PublicSpaceViewerLoader: View {
    let slug: String
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var detail: PublicSpaceDetail?
    @State private var localPanoramaURL: URL?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let api = MobilePublicSpacesAPIClient()

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    var body: some View {
        Group {
            if isLoading {
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView("공간을 불러오는 중…")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            } else if let errorMessage {
                ZStack {
                    GonggiAmbientBackground(showGlow: false).ignoresSafeArea()
                    VStack(spacing: GonggiSpacing.md) {
                        Text(errorMessage)
                            .font(GonggiTypography.body(15))
                            .foregroundStyle(GonggiColors.textSecondary)
                            .multilineTextAlignment(.center)
                        SecondaryButton(title: "다시 시도", icon: "arrow.clockwise") {
                            Task { await load() }
                        }
                        .frame(maxWidth: 220)
                        SecondaryButton(title: "닫기", icon: "xmark") {
                            close()
                        }
                        .frame(maxWidth: 220)
                    }
                    .padding()
                }
            } else if let detail, let localPanoramaURL {
                PublicSpaceViewerHost(
                    detail: detail,
                    panoramaFileURL: localPanoramaURL,
                    onDismissToList: { close() }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let token = MobileAuthTokenStore.shared.getAccessToken()
            let detail = try await api.getPublicSpace(accessToken: token, slug: slug)
            let file = try await api.downloadPanorama(
                accessToken: token,
                panoramaUrl: detail.panoramaUrl,
                cacheKey: detail.publicSlug
            )
            self.detail = detail
            self.localPanoramaURL = file
        } catch let err as MobileAuthAPIError {
            errorMessage = err.publicSpacesMessage
        } catch {
            errorMessage = "공개 공간을 불러오지 못했어요."
        }
    }
}
