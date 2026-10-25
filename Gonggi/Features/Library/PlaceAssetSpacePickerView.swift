import SwiftUI

/// Asset Detail → pick owned ready GonggiSpace for placement.
struct PlaceAssetSpacePickerView: View {
    let spaces: [SpaceRecord]
    var onSelect: (SpaceRecord) -> Void
    var onClose: () -> Void

    private var candidates: [SpaceRecord] {
        spaces.filter { space in
            guard space.canOpenExistingVR else { return false }
            let hasLocal = SpaceLatLongStore.isValidLocalFile(at: space.localLatLongPath)
            let hasRemote = !(space.remoteImageURL ?? space.viewerURL?.absoluteString ?? "").isEmpty
            return hasLocal || hasRemote
        }
        .sorted { $0.capturedAt > $1.capturedAt }
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        L("No spaces available for placement"),
                        systemImage: "cube.transparent",
                        description: Text(L("Make a finished space first."))
                    )
                } else {
                    List(candidates) { space in
                        Button {
                            GonggiHaptics.light()
                            onSelect(space)
                        } label: {
                            HStack(spacing: GonggiSpacing.md) {
                                SpaceThumbnailView(
                                    space: space,
                                    height: 56,
                                    width: 56,
                                    cornerRadius: GonggiRadius.sm,
                                    showsActivityOverlay: false
                                )
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(space.name)
                                        .font(GonggiTypography.body(16))
                                        .foregroundStyle(GonggiColors.textPrimary)
                                    Text(WhikDate.short(space.capturedAt))
                                        .font(GonggiTypography.caption(12))
                                        .foregroundStyle(GonggiColors.textSecondary)
                                    Text(space.statusBadgeLabel)
                                        .font(GonggiTypography.caption(12))
                                        .foregroundStyle(GonggiColors.textTertiary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(GonggiColors.textTertiary)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(L("Choose a space to place in"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(GonggiColors.backgroundPrimary, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .background(GonggiColors.backgroundPrimary)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { onClose() }
                        .foregroundStyle(GonggiColors.textSecondary)
                }
            }
        }
    }
}
