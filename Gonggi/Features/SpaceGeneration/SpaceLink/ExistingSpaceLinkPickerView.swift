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
                        "연결할 수 없어요",
                        systemImage: "wifi.slash",
                        description: Text(offlineMessage)
                    )
                } else if candidates.isEmpty {
                    ContentUnavailableView(
                        "연결할 수 있는 공간이 없어요",
                        systemImage: "cube.transparent",
                        description: Text("새 공간을 촬영해 보세요.")
                    )
                } else {
                    List(candidates) { space in
                        Button {
                            select(space)
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.secondary.opacity(0.15))
                                        .frame(width: 56, height: 56)
                                    Image(systemName: space.thumbnailSystemImage)
                                        .font(.system(size: 22, weight: .light))
                                        .foregroundStyle(.secondary)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(space.name)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(space.capturedAt.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if alreadyLinkedTargetIds.contains(space.id)
                                        || alreadyLinkedTargetIds.contains(space.sessionId ?? "") {
                                        Text("이미 연결됨")
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
            .navigationTitle("기존 공간 연결")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { onCancel() }
                }
            }
            .alert("이 공간으로 연결할까요?", isPresented: Binding(
                get: { pendingConfirm != nil && !showDuplicateWarn },
                set: { if !$0 { pendingConfirm = nil } }
            )) {
                Button("연결") {
                    if let space = pendingConfirm {
                        onConfirm(space)
                    }
                    pendingConfirm = nil
                }
                Button("취소", role: .cancel) { pendingConfirm = nil }
            } message: {
                if let name = pendingConfirm?.name {
                    Text(name)
                }
            }
            .alert("이미 연결된 공간입니다", isPresented: $showDuplicateWarn) {
                Button("연결") {
                    if let space = pendingConfirm {
                        onConfirm(space)
                    }
                    pendingConfirm = nil
                    showDuplicateWarn = false
                }
                Button("취소", role: .cancel) {
                    pendingConfirm = nil
                    showDuplicateWarn = false
                }
            } message: {
                Text("다른 위치에 한 번 더 연결할까요?")
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
