import SwiftUI

/// Picker for linking an existing usable GonggiSpace (Build 73).
struct ExistingSpaceLinkPickerView: View {
    let sourceSpaceId: String
    let spaces: [SpaceRecord]
    /// Target session/job ids already linked from this source (for soft warning).
    let alreadyLinkedTargetIds: Set<String>
    var onConfirm: (SpaceRecord) -> Void
    var onCancel: () -> Void

    @State private var pendingConfirm: SpaceRecord?
    @State private var showDuplicateWarn = false
    @State private var offlineMessage: String?

    private var candidates: [SpaceRecord] {
        spaces.filter { space in
            guard space.id != sourceSpaceId else { return false }
            guard space.sessionId != sourceSpaceId else { return false }
            guard space.canOpenExistingVR else { return false }
            // Prefer device-ready; also allow ready with remote URL for multi-device.
            let hasLocal = SpaceLatLongStore.isValidLocalFile(at: space.localLatLongPath)
            let hasRemote = !(space.remoteImageURL ?? space.viewerURL?.absoluteString ?? "").isEmpty
            return hasLocal || hasRemote
        }
        .sorted { $0.capturedAt > $1.capturedAt }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let offlineMessage {
                    ContentUnavailableView(
                        L("Can't link"),
                        systemImage: "wifi.slash",
                        description: Text(offlineMessage)
                    )
                } else if candidates.isEmpty {
                    ContentUnavailableView(
                        L("No spaces to link"),
                        systemImage: "cube.transparent",
                        description: Text(L("Try capturing a new space."))
                    )
                } else {
                    List(candidates) { space in
                        Button {
                            select(space)
                        } label: {
                            HStack(spacing: 12) {
                                SpaceThumbnailView(
                                    space: space,
                                    height: 56,
                                    width: 56,
                                    cornerRadius: 10,
                                    showsActivityOverlay: false
                                )
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(space.name)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(WhikDate.short(space.capturedAt))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if alreadyLinkedTargetIds.contains(space.id)
                                        || alreadyLinkedTargetIds.contains(space.sessionId ?? "") {
                                        Text(L("Already linked"))
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(L("Link an existing space"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { onCancel() }
                }
            }
            .alert(L("Link to this space?"), isPresented: Binding(
                get: { pendingConfirm != nil && !showDuplicateWarn },
                set: { if !$0 { pendingConfirm = nil } }
            )) {
                Button(L("Link")) {
                    if let space = pendingConfirm {
                        onConfirm(space)
                    }
                    pendingConfirm = nil
                }
                Button(L("Cancel"), role: .cancel) { pendingConfirm = nil }
            } message: {
                if let name = pendingConfirm?.name {
                    Text(name)
                }
            }
            .alert(L("This space is already linked"), isPresented: $showDuplicateWarn) {
                Button(L("Link")) {
                    if let space = pendingConfirm {
                        onConfirm(space)
                    }
                    pendingConfirm = nil
                    showDuplicateWarn = false
                }
                Button(L("Cancel"), role: .cancel) {
                    pendingConfirm = nil
                    showDuplicateWarn = false
                }
            } message: {
                Text(L("Link it once more at another spot?"))
            }
        }
    }

    private func select(_ space: SpaceRecord) {
        pendingConfirm = space
        let dup = alreadyLinkedTargetIds.contains(space.id)
            || alreadyLinkedTargetIds.contains(space.sessionId ?? "")
        showDuplicateWarn = dup
    }
}
