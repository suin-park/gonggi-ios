import SwiftUI

/// Shared placement-ready asset picker (Space Detail + VR Edit).
struct AssetPickerSheet: View {
    @ObservedObject var store: AssetLibraryStore
    var title: String = L("3D Objects")
    /// When true, non-ready rows stay visible but disabled.
    var showNonReadyDisabled: Bool = true
    var isAtCapacity: Bool = false
    var onSelect: (MobileAssetDTO) -> Void
    var onClose: () -> Void

    private var rows: [MobileAssetDTO] {
        let all = store.assets
        if showNonReadyDisabled {
            return all.sorted { lhs, rhs in
                if lhs.availableForPlacement != rhs.availableForPlacement {
                    return lhs.availableForPlacement && !rhs.availableForPlacement
                }
                return (lhs.parsedCreatedAt ?? .distantPast) > (rhs.parsedCreatedAt ?? .distantPast)
            }
        }
        return all.filter(\.availableForPlacement)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch store.phase {
                case .idle, .loading:
                    ProgressView(L("Loading 3D Objects"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed:
                    ContentUnavailableView(
                        store.errorMessage ?? L("Couldn't load 3D Objects"),
                        systemImage: "exclamationmark.triangle",
                        description: Text(L("Please try again."))
                    )
                case .loaded:
                    if rows.isEmpty {
                        ContentUnavailableView(
                            L("No 3D Objects can be placed"),
                            systemImage: "cube.transparent",
                            description: Text(L("Only objects with AR and placement ready can be used"))
                        )
                    } else {
                        List(rows) { asset in
                            let selectable = asset.availableForPlacement
                                && !(asset.usdzUrl ?? "").isEmpty
                                && !isAtCapacity
                            Button {
                                guard selectable else { return }
                                GonggiHaptics.light()
                                onSelect(asset)
                            } label: {
                                HStack(spacing: GonggiSpacing.md) {
                                    AssetThumbnailView(
                                        urlString: asset.thumbUrl,
                                        size: 56,
                                        showsMissingCaption: false,
                                        debugAssetId: asset.id
                                    )
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(asset.name)
                                            .font(GonggiTypography.body(16))
                                            .foregroundStyle(GonggiColors.textPrimary)
                                            .lineLimit(2)
                                        Text(asset.libraryStatus.label)
                                            .font(GonggiTypography.caption(12))
                                            .foregroundStyle(GonggiColors.textSecondary)
                                        if let reason = asset.placementUnavailableReason {
                                            Text(reason)
                                                .font(GonggiTypography.caption(12))
                                                .foregroundStyle(GonggiColors.textTertiary)
                                        } else if isAtCapacity {
                                            Text(L("You can place up to 8 3D Objects in this space"))
                                                .font(GonggiTypography.caption(12))
                                                .foregroundStyle(GonggiColors.textTertiary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 4)
                            }
                            .disabled(!selectable)
                            .opacity(selectable ? 1 : 0.45)
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Close")) { onClose() }
                        .foregroundStyle(GonggiColors.textSecondary)
                }
                if store.phase == .failed {
                    ToolbarItem(placement: .primaryAction) {
                        Button(L("Try again")) {
                            store.refresh(force: true)
                        }
                    }
                }
            }
            .task {
                if store.phase == .idle || store.phase == .failed {
                    store.refresh()
                }
            }
        }
    }
}
