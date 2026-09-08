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
                        "배치할 수 있는 공간이 없어요",
                        systemImage: "cube.transparent",
                        description: Text("준비가 끝난 공간을 먼저 만들어 주세요.")
                    )
                } else {
                    List(candidates) { space in
                        Button {
                            GonggiHaptics.light()
                            onSelect(space)
                        } label: {
                            HStack(spacing: GonggiSpacing.md) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous)
                                        .fill(GonggiColors.surface)
                                        .frame(width: 56, height: 56)
                                    Image(systemName: space.thumbnailSystemImage)
                                        .font(.system(size: 22, weight: .light))
                                        .foregroundStyle(GonggiColors.accentTeal)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(space.name)
                                        .font(GonggiTypography.body(16))
                                        .foregroundStyle(GonggiColors.textPrimary)
                                    Text(space.capturedAt.formatted(date: .abbreviated, time: .omitted))
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
            .navigationTitle("배치할 공간 선택")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { onClose() }
                        .foregroundStyle(GonggiColors.textSecondary)
                }
            }
        }
    }
}
