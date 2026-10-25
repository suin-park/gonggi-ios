import SwiftUI

/// Full-screen 3D view of a photo-made 3D Object from the Library (Objects), opened straight from the tile like a
/// space viewer. The AR detail page (`AssetDetailView`) is not reachable from the WHIK shell while AR is unused.
/// The list snapshot often lacks the model URL, so the viewer fetches the asset once before showing the model.
struct WhikObjectViewer: View {
    let snapshot: MobileAssetDTO
    let onClose: () -> Void

    @State private var asset: MobileAssetDTO?
    @State private var loadFailed = false

    private var current: MobileAssetDTO { asset ?? snapshot }

    var body: some View {
        ZStack {
            WhikColors.background.ignoresSafeArea()
            content
                .ignoresSafeArea()
            VStack {
                HStack(alignment: .center, spacing: 12) {
                    WhikCircleButton(systemImage: "xmark", label: L("Close"), action: onClose)
                    Text(current.name)
                        .font(WhikFont.title(20))
                        .foregroundStyle(WhikColors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, WhikLayout.sideInset)
                .padding(.top, 8)
                Spacer()
                if current.canPreviewUSDZ {
                    Text(L("Drag to rotate, pinch to zoom"))
                        .font(.system(.footnote))
                        .foregroundStyle(WhikColors.textSecondary)
                        .padding(.bottom, 24)
                        .accessibilityHidden(true)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if current.canPreviewUSDZ, let raw = current.usdzUrl, let url = URL(string: raw) {
            AssetUSDZPreviewHost(assetId: current.id, remoteURL: url, thumbUrl: current.thumbUrl)
        } else if asset == nil, !loadFailed {
            ProgressView().tint(WhikColors.mint)
        } else {
            VStack(spacing: 16) {
                AssetThumbnailView(urlString: current.thumbUrl, size: 160, showsMissingCaption: false, debugAssetId: current.id)
                Text(loadFailed ? L("Couldn't load the 3D Object details") : L("3D preview isn't ready yet"))
                    .font(.system(.body))
                    .foregroundStyle(WhikColors.textSecondary)
                    .multilineTextAlignment(.center)
                if loadFailed {
                    Button(L("Try again")) { Task { await load() } }
                        .buttonStyle(.bordered)
                        .tint(WhikColors.mint)
                }
            }
            .padding(.horizontal, 32)
        }
    }

    private func load() async {
        loadFailed = false
        do {
            let fresh = try await MobileAssetsAPIClient().fetchAsset(id: snapshot.id)
            asset = fresh
            AssetLibraryStore.shared.upsertAsset(fresh)
        } catch {
            // A list snapshot that already carries a model URL still shows; otherwise offer a retry.
            loadFailed = !snapshot.canPreviewUSDZ
        }
    }
}
