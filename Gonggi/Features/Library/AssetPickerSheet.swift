import SwiftUI

/// Shared placement-ready asset picker (Space Detail + VR Edit).
struct AssetPickerSheet: View {
    @ObservedObject var store: AssetLibraryStore
    var title: String = "3D 오브젝트"
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
                    ProgressView("3D 오브젝트를 불러오는 중")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed:
                    ContentUnavailableView(
                        store.errorMessage ?? "3D 어셋을 불러오지 못했어요",
                        systemImage: "exclamationmark.triangle",
                        description: Text("다시 시도해 주세요.")
                    )
                case .loaded:
                    if rows.isEmpty {
                        ContentUnavailableView(
                            "배치할 수 있는 3D 어셋이 없어요",
                            systemImage: "cube.transparent",
                            description: Text("AR/배치 준비가 완료된 어셋만 사용할 수 있어요")
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
                                    AssetThumbnailView(urlString: asset.thumbUrl, size: 56)
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
                                            Text("이 공간에는 최대 8개의 3D 오브젝트를 배치할 수 있어요")
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
                    Button("닫기") { onClose() }
                        .foregroundStyle(GonggiColors.textSecondary)
                }
                if store.phase == .failed {
                    ToolbarItem(placement: .primaryAction) {
                        Button("다시 시도") {
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
