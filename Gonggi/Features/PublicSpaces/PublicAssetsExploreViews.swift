import Foundation
import SwiftUI

struct PublicAssetListItem: Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var name: String
    var publisherDisplayName: String
    var publishedAt: String
    var thumbnailUrl: String?
    var usdzUrl: String?
    var availableForAR: Bool
}

struct PublicAssetListPage: Equatable, Sendable {
    var assets: [PublicAssetListItem]
    var nextCursor: String?
}

struct AssetExploreVisibilityState: Equatable, Sendable {
    var exploreListed: Bool
    var canList: Bool
    var usdzStatus: String
}

struct PublicAssetCardView: View {
    let item: PublicAssetListItem
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: GonggiSpacing.md) {
                AssetThumbnailView(urlString: item.thumbnailUrl, size: 72)
                    .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(GonggiTypography.headline(16))
                        .foregroundStyle(GonggiColors.textPrimary)
                        .lineLimit(2)
                    Text(item.publisherDisplayName)
                        .font(GonggiTypography.caption(12))
                        .foregroundStyle(GonggiColors.textTertiary)
                        .lineLimit(1)
                    Text(item.availableForAR ? "AR로 보기" : "준비 중")
                        .font(GonggiTypography.caption(12))
                        .foregroundStyle(
                            item.availableForAR ? GonggiColors.accentTeal : GonggiColors.textTertiary
                        )
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
        .disabled(!item.availableForAR)
        .opacity(item.availableForAR ? 1 : 0.55)
        .accessibilityLabel("\(item.name), \(item.publisherDisplayName)")
    }
}

/// Full-width social feed post for Explore assets.
struct PublicAssetFeedPostView: View {
    let item: PublicAssetListItem
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
                HStack(spacing: GonggiSpacing.sm) {
                    Circle()
                        .fill(GonggiColors.surfaceElevated)
                        .frame(width: 36, height: 36)
                        .overlay {
                            Text(String(item.publisherDisplayName.prefix(1)).uppercased())
                                .font(GonggiTypography.caption(13))
                                .fontWeight(.semibold)
                                .foregroundStyle(GonggiColors.textSecondary)
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.publisherDisplayName)
                            .font(GonggiTypography.headline(15))
                            .foregroundStyle(GonggiColors.textPrimary)
                            .lineLimit(1)
                        Text(PublicSpaceCardView.formatPublished(item.publishedAt))
                            .font(GonggiTypography.caption(12))
                            .foregroundStyle(GonggiColors.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, GonggiSpacing.lg)
                .padding(.top, GonggiSpacing.md)

                HStack {
                    Spacer(minLength: 0)
                    AssetThumbnailView(urlString: item.thumbnailUrl, size: 220)
                        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 240)
                .background(GonggiColors.surfaceElevated.opacity(0.35))

                HStack(alignment: .firstTextBaseline) {
                    Text(item.name)
                        .font(GonggiTypography.headline(17))
                        .foregroundStyle(GonggiColors.textPrimary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(item.availableForAR ? "AR로 보기" : "준비 중")
                        .font(GonggiTypography.caption(13))
                        .fontWeight(.semibold)
                        .foregroundStyle(
                            item.availableForAR ? GonggiColors.accentTeal : GonggiColors.textTertiary
                        )
                }
                .padding(.horizontal, GonggiSpacing.lg)
                .padding(.bottom, GonggiSpacing.md)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(GonggiPressableStyle())
        .disabled(!item.availableForAR)
        .opacity(item.availableForAR ? 1 : 0.55)
        .accessibilityLabel("\(item.name), \(item.publisherDisplayName)")
    }
}

struct PublicAssetsListView: View {
    @State private var assets: [PublicAssetListItem] = []
    @State private var nextCursor: String?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var loadError: String?
    @State private var quickLook: ExploreListIdentifiedURL?
    @State private var didInitialLoad = false

    private let api = MobilePublicSpacesAPIClient()

    var body: some View {
        Group {
            if isLoading && assets.isEmpty {
                ProgressView("불러오는 중…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError, assets.isEmpty {
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
            } else if assets.isEmpty {
                Text("아직 공개된 3D 자산이 없어요.")
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(assets) { item in
                        PublicAssetCardView(item: item) {
                            Task { await openAR(item) }
                        }
                        .listRowInsets(EdgeInsets(
                            top: GonggiSpacing.sm,
                            leading: GonggiSpacing.lg,
                            bottom: GonggiSpacing.sm,
                            trailing: GonggiSpacing.lg
                        ))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .onAppear {
                            if item.id == assets.last?.id {
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
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(GonggiAmbientBackground())
        .navigationTitle("공개 3D 자산")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !didInitialLoad else { return }
            didInitialLoad = true
            await reload()
        }
        .sheet(item: $quickLook) { item in
            AssetARQuickLookView(localUsdzURL: item.url)
        }
    }

    private func reload() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let page = try await api.listPublicAssets(
                accessToken: MobileAuthTokenStore.shared.getAccessToken(),
                limit: 20,
                cursor: nil
            )
            assets = page.assets
            nextCursor = page.nextCursor
        } catch {
            loadError = "공개 자산을 불러오지 못했어요. 잠시 후 다시 시도해주세요."
            assets = []
            nextCursor = nil
        }
    }

    private func loadMore() async {
        guard let nextCursor, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await api.listPublicAssets(
                accessToken: MobileAuthTokenStore.shared.getAccessToken(),
                limit: 20,
                cursor: nextCursor
            )
            let existing = Set(assets.map(\.id))
            assets.append(contentsOf: page.assets.filter { !existing.contains($0.id) })
            self.nextCursor = page.nextCursor
        } catch {
            // Keep current list; silent fail on pagination.
        }
    }

    private func openAR(_ item: PublicAssetListItem) async {
        guard let remoteStr = item.usdzUrl, let remote = URL(string: remoteStr) else { return }
        guard let local = await VRUsdzCache().localURL(assetId: item.id, remoteURL: remote) else {
            loadError = "AR 파일을 불러오지 못했어요"
            return
        }
        quickLook = ExploreListIdentifiedURL(url: local)
    }
}

private struct ExploreListIdentifiedURL: Identifiable {
    let id = UUID()
    let url: URL
}
