import Foundation

/// Transient handoff: Asset Detail / Space Detail → VR Edit placement draft (consume-once).
/// Not persisted. Do not merge with `PendingSpaceLinkCapture`.
struct PendingAssetPlacement: Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case assetDetail
        case spaceDetail
        case vrEdit
    }

    let assetId: String
    /// SpaceRecord.id (usually jobId) — same key used for `SpaceViewerSession.id`.
    let targetSpaceId: String
    /// Optional GonggiSpace.sessionId for matcher / API key fallback.
    let targetSessionId: String?
    let assetSnapshot: MobileAssetDTO?
    let source: Source
    let createdAt: Date

    init(
        assetId: String,
        targetSpaceId: String,
        targetSessionId: String? = nil,
        assetSnapshot: MobileAssetDTO? = nil,
        source: Source,
        createdAt: Date = Date()
    ) {
        self.assetId = assetId
        self.targetSpaceId = targetSpaceId
        self.targetSessionId = targetSessionId
        self.assetSnapshot = assetSnapshot
        self.source = source
        self.createdAt = createdAt
    }

    func matches(viewerSessionId: String, spaces: [SpaceRecord]) -> Bool {
        if targetSpaceId == viewerSessionId { return true }
        if let targetSessionId, targetSessionId == viewerSessionId { return true }
        if let space = spaces.first(where: {
            $0.id == targetSpaceId || $0.sessionId == targetSpaceId
                || $0.id == targetSessionId || $0.sessionId == targetSessionId
        }) {
            return space.id == viewerSessionId || space.sessionId == viewerSessionId
        }
        return false
    }
}

/// Shared launch path for Asset Detail / Space Detail → VR Edit + pending insert.
@MainActor
enum AssetPlacementLaunch {
    enum BlockReason: Equatable {
        case maxAssets
        case spaceNotReady
        case prepareFailed(String)

        var userMessage: String {
            switch self {
            case .maxAssets:
                return "이 공간에는 최대 8개의 3D 오브젝트를 배치할 수 있어요"
            case .spaceNotReady:
                return "이 공간은 아직 배치할 수 없어요"
            case .prepareFailed(let message):
                return message
            }
        }
    }

    static func placementCount(for space: SpaceRecord) async -> Int {
        let store = VRPlacementLayoutStore()
        let keys = Array(Set([space.id, space.sessionId].compactMap { $0 }))
        var best = 0
        for key in keys {
            let local = try? await store.loadLocal(sessionId: key)
            let remote = try? await store.fetchRemote(sessionId: key)
            let merged = await store.merge(local: local, remote: remote)
            best = max(best, merged.assets.count)
        }
        return best
    }

    static func open(
        space: SpaceRecord,
        asset: MobileAssetDTO,
        source: PendingAssetPlacement.Source,
        appState: AppState,
        present: (SpaceViewerLaunch) -> Void
    ) async -> BlockReason? {
        guard asset.availableForPlacement,
              let usdz = asset.usdzUrl, !usdz.isEmpty
        else {
            return .spaceNotReady
        }
        guard space.canOpenExistingVR else {
            return .spaceNotReady
        }

        let count = await placementCount(for: space)
        if count >= VRPlacementLayout.maxAssets {
            return .maxAssets
        }

        appState.pendingAssetPlacement = PendingAssetPlacement(
            assetId: asset.id,
            targetSpaceId: space.id,
            targetSessionId: space.sessionId,
            assetSnapshot: asset,
            source: source
        )

        switch await appState.prepareSpaceViewer(jobId: space.id) {
        case .success(let url):
            let audioURL = space.audioURL.flatMap(URL.init(string:))
                ?? AppState.preferredAudioURL(for: space.id)
            present(
                SpaceViewerLaunch(
                    single: SpaceViewerSession(
                        id: space.id,
                        fileURL: url,
                        audioURL: audioURL,
                        videoURL: AppState.preferredVideoURL(for: space.id),
                        startInEditMode: true
                    )
                )
            )
            return nil
        case .failure(let error):
            appState.pendingAssetPlacement = nil
            return .prepareFailed(error.userMessage)
        }
    }
}
