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

    init(client: MobileAssetsAPIClient = MobileAssetsAPIClient()) {
        self.client = client
    }

    var isTrueEmpty: Bool {
        phase == .loaded && assets.isEmpty && errorMessage == nil
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
        let hadContent = !assets.isEmpty
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

        do {
            let list = try await client.fetchAssets()
            guard !Task.isCancelled else { return }
            assets = list
            phase = .loaded
            errorMessage = nil
        } catch let error as MobileAssetsAPIError {
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
}
