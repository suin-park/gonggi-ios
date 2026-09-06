import Foundation

/// Library category: spaces vs 3D assets (future 3D Locker linkage).
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

/// Shell model for 3D assets until Locker asset API is wired.
struct AssetRecord: Identifiable, Equatable, Hashable {
    enum Status: String {
        case ready
        case generating
        case failed

        var label: String {
            switch self {
            case .ready: return "준비됨"
            case .generating: return "생성 중"
            case .failed: return "실패"
            }
        }
    }

    var id: String
    var name: String
    var createdAt: Date
    var status: Status
    var typeLabel: String
    var thumbnailSystemImage: String
}

/// Placeholder store — replace with 3D Locker asset API client later.
@MainActor
final class AssetLibraryStore: ObservableObject {
    static let shared = AssetLibraryStore()

    @Published private(set) var assets: [AssetRecord] = []

    func refresh() {
        // Shell: empty until account-linked asset fetch exists.
    }
}
