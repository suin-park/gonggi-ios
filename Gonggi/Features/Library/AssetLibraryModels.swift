import Foundation

/// Library category: spaces vs 3D assets (canonical 3D Locker Asset via mobile API).
enum LibraryCategory: String, CaseIterable, Identifiable {
    case spaces
    case assets

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spaces: return "공간"
        case .assets: return "3D 어셋"
        }
    }
}

enum AssetLibraryLoadPhase: Equatable {
    case idle
    case loading
    case loaded
    case failed
}

/// Loads canonical 3D Locker assets via existing mobile Bearer API (Phase 1).
@MainActor
final class AssetLibraryStore: ObservableObject {
    static let shared = AssetLibraryStore()

    /// Known backend `take: 40` — Phase 1 does not claim a complete catalog beyond this.
    static let knownServerTakeLimit = 40

    @Published private(set) var assets: [MobileAssetDTO] = []
    @Published private(set) var phase: AssetLibraryLoadPhase = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false

    private let client: MobileAssetsAPIClient
    private var loadTask: Task<Void, Never>?
    private let generationStore: AssetGenerationStore
    private var readinessPollTask: Task<Void, Never>?
    private var readinessPollDeadline: Date?

    init(
        client: MobileAssetsAPIClient = MobileAssetsAPIClient(),
        generationStore: AssetGenerationStore = .shared
    ) {
        self.client = client
        self.generationStore = generationStore
    }

    /// Assets + pending/failed generation jobs (never fake jobs as assets).
    var libraryEntries: [AssetLibraryEntry] {
        AssetLibraryEntryMerger.merge(assets: assets, jobs: generationStore.jobs)
    }

    var isTrueEmpty: Bool {
        phase == .loaded && assets.isEmpty && generationStore.jobs.isEmpty && errorMessage == nil
    }

    var mayBeTruncated: Bool {
        assets.count >= Self.knownServerTakeLimit
    }

    func refresh(force: Bool = false) {
        if phase == .loading, !force { return }
        loadTask?.cancel()
        loadTask = Task { await performRefresh() }
    }

    func performRefresh() async {
        let hadContent = !assets.isEmpty || !generationStore.jobs.isEmpty
        if hadContent {
            isRefreshing = true
        } else {
            phase = .loading
        }
        errorMessage = nil

        guard MobileAuthTokenStore.shared.getAccessToken() != nil else {
            assets = []
            phase = .failed
            errorMessage = "로그인이 필요해요"
            isRefreshing = false
            return
        }

        async let jobsRefresh: Bool = generationStore.refreshActiveJobs()
        do {
            let list = try await client.fetchAssets()
            _ = await jobsRefresh
            guard !Task.isCancelled else { return }
            assets = list
            phase = .loaded
            errorMessage = nil
            startScopedReadinessPollIfNeeded()
        } catch let error as MobileAssetsAPIError {
            _ = await jobsRefresh
            guard !Task.isCancelled else { return }
            if case .server(let status) = error, status == 401 {
                assets = []
                phase = .failed
                errorMessage = "로그인이 필요해요"
            } else if hadContent {
                // Keep stale list; surface transient error via message only on empty fail.
                errorMessage = nil
            } else {
                assets = []
                phase = .failed
                errorMessage = "3D 어셋을 불러오지 못했어요"
            }
        } catch {
            _ = await jobsRefresh
            guard !Task.isCancelled else { return }
            if hadContent {
                errorMessage = nil
            } else {
                assets = []
                phase = .failed
                errorMessage = "3D 어셋을 불러오지 못했어요"
            }
        }
        isRefreshing = false
    }

    /// VR Edit fetch can warm the shared Library store without forcing a reload flash.
    func replaceIfNewer(_ list: [MobileAssetDTO]) {
        guard phase != .loading else { return }
        assets = list
        phase = .loaded
        errorMessage = nil
        startScopedReadinessPollIfNeeded()
    }

    /// Targeted update after Detail poll / prepare (avoids full list storm).
    func upsertAsset(_ asset: MobileAssetDTO) {
        if let idx = assets.firstIndex(where: { $0.id == asset.id }) {
            assets[idx] = asset
        } else {
            assets.insert(asset, at: 0)
        }
        if phase == .idle || phase == .failed {
            phase = .loaded
        }
        startScopedReadinessPollIfNeeded()
    }

    // MARK: - Scoped USDZ readiness poll (PROCESSING only, capped)

    private var processingAssetIds: [String] {
        assets.filter(\.isUsdzProcessing).map(\.id)
    }

    func startScopedReadinessPollIfNeeded() {
        let ids = processingAssetIds
        guard !ids.isEmpty else {
            stopScopedReadinessPoll()
            return
        }
        if readinessPollDeadline == nil {
            readinessPollDeadline = Date().addingTimeInterval(3 * 60)
        }
        guard readinessPollTask == nil else { return }
        readinessPollTask = Task { [weak self] in
            var delays: [UInt64] = [2, 3, 5, 8]
            var delayIndex = 0
            while !Task.isCancelled {
                guard let self else { return }
                if let deadline = self.readinessPollDeadline, Date() > deadline {
                    self.stopScopedReadinessPoll()
                    return
                }
                let delay = delays[min(delayIndex, delays.count - 1)]
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delayIndex = min(delayIndex + 1, delays.count - 1)
                guard !Task.isCancelled else { return }
                await self.pollProcessingAssetsOnce()
                if self.processingAssetIds.isEmpty {
                    self.stopScopedReadinessPoll()
                    return
                }
            }
        }
    }

    private func stopScopedReadinessPoll() {
        readinessPollTask?.cancel()
        readinessPollTask = nil
        readinessPollDeadline = nil
    }

    private func pollProcessingAssetsOnce() async {
        let ids = processingAssetIds
        guard !ids.isEmpty else { return }
        for id in ids.prefix(6) {
            do {
                let fresh = try await client.fetchAsset(id: id)
                if let idx = assets.firstIndex(where: { $0.id == id }) {
                    assets[idx] = fresh
                }
            } catch {
                // Keep last known; next cycle retries.
            }
        }
    }
}

enum AssetLibraryEntryMerger {
    static func merge(assets: [MobileAssetDTO], jobs: [MobileGenerationJobDTO]) -> [AssetLibraryEntry] {
        let assetIds = Set(assets.map(\.id))
        let jobEntries: [AssetLibraryEntry] = jobs.compactMap { job in
            if job.isDone {
                return nil
            }
            if let aid = job.assetId, assetIds.contains(aid) {
                return nil
            }
            return .generation(job)
        }
        let assetEntries = assets.map { AssetLibraryEntry.asset($0) }
        return jobEntries + assetEntries
    }
}
