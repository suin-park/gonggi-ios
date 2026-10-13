import Foundation

// 매장 대표 사진, 매장 둘러보기(360 공간 연결)의 모델과 순수 규칙. Linux 테스트 대상.

// MARK: - Server DTOs

/// A store in the customer list 「매장 둘러보기」.
struct RemoteBrowsableStore: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var branchName: String?
    var address: String
    var latitude: Double?
    var longitude: Double?
    var distanceM: Int?
    var coverUrl: String?
    var hasTour: Bool

    var displayName: String {
        if let b = branchName, !b.isEmpty { return name + " " + b }
        return name
    }
}

struct RemoteBrowsableStoresBody: Codable, Equatable, Sendable {
    var items: [RemoteBrowsableStore]
}

/// A 360 space linked to a store. `status`: DRAFT, PUBLISHED, UNPUBLISHED.
struct RemoteTourSpace: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var status: String
    var width: Int?
    var height: Int?
    var imageUrl: String
    var linkedAt: String?
    var publishedAt: String?

    var isPublished: Bool { status == "PUBLISHED" }
}

struct RemoteTourSpacesBody: Codable, Equatable, Sendable {
    var spaces: [RemoteTourSpace]
}

struct RemoteTourSpaceBody: Codable, Equatable, Sendable {
    var space: RemoteTourSpace
}

/// What customers read of a published tour space (no owner, no original space id).
struct RemotePublicTourSpace: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var width: Int?
    var height: Int?
    var imageUrl: String
}

struct RemotePublicTourBody: Codable, Equatable, Sendable {
    var spaces: [RemotePublicTourSpace]
}

struct RemoteCoverUploadBody: Codable, Equatable, Sendable {
    struct Target: Codable, Equatable, Sendable {
        var key: String
        var url: String
        var contentType: String
        var bytes: Int
    }

    var upload: Target
}

struct RemoteCoverConfirmBody: Codable, Equatable, Sendable {
    var coverUrl: String
}

struct RemotePublicProduct: Codable, Equatable, Identifiable, Sendable {
    var identity: String
    var name: String
    var brand: String?
    var variant: String?
    var volumeText: String?
    var imageUrl: String?
    var lastConfirmedAt: String?

    var id: String { identity }

    var subtitle: String {
        [brand, variant, volumeText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

struct RemotePublicProductsBody: Codable, Equatable, Sendable {
    var items: [RemotePublicProduct]
}

// MARK: - Cover photo rules

enum KmoCoverPolicy {
    static let maxBytes = 3 * 1024 * 1024
    static let maxLongSide: Double = 1600

    /// Longest side after scaling down (never scaled up).
    static func targetLongSide(width: Double, height: Double) -> Double {
        let long = max(width, height)
        return long > maxLongSide ? maxLongSide : long
    }

    /// JPEG qualities to try, best first, until the data fits the server limit.
    static let qualities: [Double] = [0.82, 0.7, 0.55, 0.4]
}

// MARK: - Image state (what the screen shows for a photo slot)

enum KmoImageSlot: Equatable {
    /// No photo exists: show a small, tidy substitute (no large empty box).
    case none
    case loading
    case loaded
    /// The photo exists but could not be loaded: offer a retry.
    case failed

    static func initial(urlString: String?) -> KmoImageSlot {
        guard let s = urlString?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return .none }
        return .loading
    }

    /// Photo area height for a card: only a real or loading photo reserves the tall space.
    var reservesPhotoHeight: Bool {
        switch self {
        case .none: return false
        case .loading, .loaded, .failed: return true
        }
    }
}

// MARK: - Tour link bookkeeping (a capture started from 「매장 촬영」)

struct KmoPendingStoreLink: Codable, Equatable, Identifiable, Sendable {
    var storeId: String
    var sessionId: String
    var createdAt: Date

    var id: String { storeId + "|" + sessionId }
}

struct KmoPendingStoreLinkStore {
    static let keyPrefix = "kmo.pendinglink.v1."
    static let maxAge: TimeInterval = 14 * 24 * 3600

    var storage: KmoKeyValueStorage

    private func key(_ account: String) -> String { Self.keyPrefix + account }

    func load(account: String?, now: Date = Date()) -> [KmoPendingStoreLink] {
        guard let account, !account.isEmpty, let data = storage.kmoData(forKey: key(account)) else { return [] }
        let all = (try? JSONDecoder().decode([KmoPendingStoreLink].self, from: data)) ?? []
        return all.filter { now.timeIntervalSince($0.createdAt) < Self.maxAge }
    }

    func add(_ link: KmoPendingStoreLink, account: String?) {
        guard let account, !account.isEmpty else { return }
        var all = load(account: account, now: link.createdAt).filter { $0.id != link.id }
        all.append(link)
        save(all, account: account)
    }

    func remove(id: String, account: String?) {
        guard let account, !account.isEmpty else { return }
        save(load(account: account).filter { $0.id != id }, account: account)
    }

    private func save(_ items: [KmoPendingStoreLink], account: String) {
        storage.kmoSet(items.isEmpty ? nil : try? JSONEncoder().encode(items), forKey: key(account))
    }
}

struct KmoLibrarySpaceRef: Equatable, Sendable {
    var id: String
    var sessionId: String?
    var isReady: Bool
}

enum KmoPendingLinkReconciler {
    /// The pending links whose space finished generating: (link, the space id to send to the server).
    static func ready(pending: [KmoPendingStoreLink], spaces: [KmoLibrarySpaceRef]) -> [(link: KmoPendingStoreLink, spaceId: String)] {
        pending.compactMap { p in
            guard let s = spaces.first(where: { $0.isReady && ($0.sessionId == p.sessionId || $0.id == p.sessionId) }) else { return nil }
            return (p, s.id)
        }
    }
}

// MARK: - Copy

enum KmoTourText {
    static let notReady = "둘러보기 준비 중"
    static let draft = "초안"
    static let published = "공개 중"
    static let unpublished = "비공개"

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "PUBLISHED": return published
        case "UNPUBLISHED": return unpublished
        default: return draft
        }
    }

    /// Shown before a manager publishes: exactly which space becomes visible to customers.
    static func publishConfirm(title: String) -> String {
        "「\(title)」 360 공간이 고객에게 공개돼요. 보관함의 원래 공간은 그대로 비공개예요."
    }

    static func linkError(code: String?) -> String {
        switch code {
        case "SPACE_NOT_READY": return "아직 만들어지는 중인 공간이에요"
        case "TOUR_LIMIT": return "한 매장에 연결할 수 있는 공간을 넘었어요"
        case "IMAGE_SOURCE_NOT_ALLOWED", "IMAGE_FETCH_FAILED": return "공간 이미지를 가져오지 못했어요. 잠시 후 다시 시도해 주세요"
        case "IMAGE_TYPE_INVALID", "IMAGE_SIZE_INVALID": return "이 공간의 이미지는 연결할 수 없어요"
        default: return "공간을 연결하지 못했어요. 다시 시도해 주세요"
        }
    }
}
