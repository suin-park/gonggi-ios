import Foundation

// Customer product search across stores, the camera index and the manager's product catalog. Pure Swift (Linux-tested).
//
// What the customer is told is only what was recorded: the last time the product was confirmed at a store and the count
// recorded then. It is never "재고 있음".

// MARK: - Published catalog next to a release

struct RemoteCatalogOverlayItem: Codable, Equatable, Sendable {
    var productId: String
    var shelfId: String
    /// "release" | "admin"
    var origin: String
    var name: String
    var brand: String?
    var variant: String?
    var volumeText: String?
    /// "ACTIVE" | "DISCONTINUED" | "UNLINKED"
    var status: String
    var quantity: Int?
    var quantityVerifiedAt: String?
    var lastConfirmedAt: String?
    var imageUrl: String?
}

struct RemoteCatalogOverlay: Codable, Equatable, Sendable {
    var catalogVersion: Int?
    var items: [RemoteCatalogOverlayItem]
}

/// Applies the published catalog (names a manager corrected, discontinued products, products added without a capture) to
/// the data of a downloaded release. The map, the shelves and the guidance points are not touched.
enum CatalogOverlayApplier {
    struct Summary: Equatable, Sendable {
        var renamed = 0
        var removed = 0
        var added = 0
    }

    @discardableResult
    static func apply(_ overlay: RemoteCatalogOverlay, to data: inout StoreShelfData, newPlacementId: () -> String = { UUID().uuidString }) -> Summary {
        var summary = Summary()
        for o in overlay.items {
            let active = o.status == "ACTIVE"
            if o.origin == "admin" {
                guard active, !o.name.isEmpty, let shelf = data.shelves.first(where: { $0.id == o.shelfId }) else { continue }
                if data.products.contains(where: { $0.id == o.productId }) == false {
                    var p = ShelfProduct(id: o.productId, name: o.name, createdAt: Date(), imageFileNames: [], embeddings: [], colorDescriptors: [],
                                         similarProductIds: [], needsReview: false, reviewReasons: [])
                    p.nameSource = ShelfNameSource.manual
                    p.brand = o.brand
                    p.variantText = o.variant
                    p.volumeText = o.volumeText
                    data.products.append(p)
                    summary.added += 1
                }
                if !data.placements.contains(where: { $0.productId == o.productId && $0.shelfId == o.shelfId }) {
                    // No position of its own: the guide leads to the shelf (its approach point), never to a made-up spot.
                    var pl = ShelfPlacement(
                        id: newPlacementId(), productId: o.productId, shelfId: o.shelfId, u: 0, v: 1, tier: 0, world: shelf.plane.origin,
                        widthM: 0.1, heightM: 0.2, uncertaintyM: 1, observationCount: 1, firstObservedAt: Date(), lastObservedAt: Date(),
                        status: .present, needsReview: false)
                    pl.visibleCount = o.quantity
                    pl.countBasis = o.quantity == nil ? "cannot_count" : "counted"
                    data.placements.append(pl)
                }
                continue
            }
            guard let i = data.products.firstIndex(where: { $0.id == o.productId }) else { continue }
            if !active {
                data.placements.removeAll { $0.productId == o.productId && ($0.shelfId == o.shelfId || o.shelfId.isEmpty) }
                if !data.placements.contains(where: { $0.productId == o.productId }) { data.products.remove(at: i) }
                summary.removed += 1
                continue
            }
            if !o.name.isEmpty, data.products[i].name != o.name {
                data.products[i].name = o.name
                data.products[i].nameSource = ShelfNameSource.manual
                summary.renamed += 1
            }
            data.products[i].brand = o.brand ?? data.products[i].brand
            data.products[i].variantText = o.variant ?? data.products[i].variantText
            data.products[i].volumeText = o.volumeText ?? data.products[i].volumeText
        }
        return summary
    }
}

// MARK: - Cross-store search

struct RemoteProductStoreEntry: Codable, Equatable, Identifiable, Sendable {
    var storeId: String
    var name: String
    var branchName: String?
    var address: String
    var latitude: Double?
    var longitude: Double?
    var distanceM: Int?
    var lastConfirmedAt: String?
    var recordedQuantity: Int?
    var quantityVerifiedAt: String?
    var shelves: [String]
    var productIds: [String]

    var id: String { storeId }
    var displayName: String {
        if let b = branchName, !b.isEmpty { return name + " " + b }
        return name
    }
}

struct RemoteProductSearchResult: Codable, Equatable, Identifiable, Sendable {
    var identity: String
    var name: String
    var brand: String?
    var variant: String?
    var volumeText: String?
    var imageUrl: String?
    var stores: [RemoteProductStoreEntry]

    var id: String { identity }

    /// "코카콜라 제로 · 355ml"
    var subtitle: String {
        [brand, variant, volumeText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct RemoteProductSearchBody: Codable, Equatable, Sendable {
    var results: [RemoteProductSearchResult]
}

struct RemoteCameraIndexItem: Codable, Equatable, Sendable {
    var identity: String
    var name: String
    var brand: String?
    var variant: String?
    var volumeText: String?
    var featureModel: String
    var embedding: String
    var storeCount: Int
}

struct RemoteCameraIndexPage: Codable, Equatable, Sendable {
    var total: Int
    var items: [RemoteCameraIndexItem]
    var nextOffset: Int?
}

enum CameraIndexGallery {
    /// The index as the product list the recognition engine already understands (id = identity). Names are display only.
    static func makeData(_ items: [RemoteCameraIndexItem]) -> StoreShelfData {
        var d = StoreShelfData.empty(storeId: "camera-index")
        d.products = items.map { i in
            var p = ShelfProduct(id: i.identity, name: i.name, createdAt: Date(), imageFileNames: [], embeddings: [StoreVector(base64: i.embedding)],
                                 colorDescriptors: [], similarProductIds: [], needsReview: false, reviewReasons: [])
            p.brand = i.brand
            p.variantText = i.variant
            p.volumeText = i.volumeText
            return p
        }
        return d
    }
}

/// What a customer reads about availability: the recorded confirmation, never "in stock".
enum ProductAvailabilityText {
    static let disclaimer = "매장에서 마지막으로 확인한 기록이에요. 지금 재고는 확인되지 않아요."

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일"
        return f
    }()

    static func day(_ iso: String?) -> String? {
        guard let iso, let d = AnalysisImporter.parseDate(iso) else { return nil }
        return formatter.string(from: d)
    }

    static func confirmedLine(_ iso: String?) -> String {
        if let d = day(iso) { return "마지막 확인 \(d)" }
        return "확인한 날짜가 없어요"
    }

    /// 0 and "not counted" are different things.
    static func quantityLine(quantity: Int?, verifiedIso: String?) -> String {
        guard let q = quantity else { return "수량은 확인되지 않았어요" }
        let when = day(verifiedIso).map { " (\($0))" } ?? ""
        return q == 0 ? "확인했을 때 0개였어요\(when)" : "확인했을 때 \(q)개\(when)"
    }

    static func distance(_ meters: Int?) -> String? {
        guard let m = meters else { return nil }
        return m < 1000 ? "\(m)m" : String(format: "%.1fkm", Double(m) / 1000)
    }
}

// MARK: - Manager catalog

struct RemoteCatalogShelf: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
}

struct RemoteCatalogItem: Codable, Equatable, Identifiable, Sendable {
    var productId: String
    var shelfId: String
    var shelfName: String?
    var name: String
    var brand: String?
    var variant: String?
    var volumeText: String?
    /// "ACTIVE" | "DISCONTINUED" | "UNLINKED"
    var status: String
    var quantity: Int?
    /// "capture" | "admin_confirmed"
    var quantityBasis: String?
    var quantityVerifiedAt: String?
    var lastConfirmedAt: String?
    var infoUpdatedAt: String
    var nameLocked: Bool
    var origin: String
    var imageUrl: String?
    var unpublishedChange: Bool

    var id: String { productId + "|" + shelfId }
    var isActive: Bool { status == "ACTIVE" }
    var statusText: String? {
        switch status {
        case "DISCONTINUED": return "취급 중단"
        case "UNLINKED": return "매대 연결 해제"
        default: return nil
        }
    }
}

struct RemoteCatalogView: Codable, Equatable, Sendable {
    var editVersion: Int
    var publishedEditVersion: Int?
    var publishedAt: String?
    var shelves: [RemoteCatalogShelf]
    var items: [RemoteCatalogItem]

    var unpublishedCount: Int { items.filter(\.unpublishedChange).count }
}

struct RemoteCatalogMutation: Codable, Equatable, Sendable {
    var editVersion: Int
    var changed: Bool?
}

struct RemoteCatalogUpload: Codable, Equatable, Sendable {
    var key: String
    var contentType: String
    var url: String
}

struct RemoteCatalogNewItem: Codable, Equatable, Sendable {
    var productId: String
    var editVersion: Int
    var upload: RemoteCatalogUpload?
}

struct RemoteCatalogImage: Codable, Equatable, Sendable {
    var editVersion: Int
    var upload: RemoteCatalogUpload
}

struct RemoteCatalogPublished: Codable, Equatable, Sendable {
    var editVersion: Int
    var publishedAt: String
    var items: Int
}

/// Minimal JSON value for PATCH bodies where "not sent" and "null" differ (a quantity that is unknown, not unchanged).
enum StoreJSONValue: Encodable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }
}

/// What the manager's edit sheet sends: only what really changed, always with the version it was made on.
enum CatalogEditBody {
    static func make(old: RemoteCatalogItem, name: String, brand: String, variant: String, volume: String,
                     quantity: Int?, quantityKnown: Bool, confirmNow: Bool, baseVersion: Int) -> [String: StoreJSONValue] {
        var b: [String: StoreJSONValue] = ["baseVersion": .int(baseVersion)]
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        func opt(_ s: String) -> StoreJSONValue { clean(s).isEmpty ? .null : .string(clean(s)) }
        if clean(name) != old.name { b["name"] = .string(clean(name)) }
        if clean(brand) != (old.brand ?? "") { b["brand"] = opt(brand) }
        if clean(variant) != (old.variant ?? "") { b["variant"] = opt(variant) }
        if clean(volume) != (old.volumeText ?? "") { b["volumeText"] = opt(volume) }
        let newQuantity: Int? = quantityKnown ? max(0, quantity ?? 0) : nil
        if newQuantity != old.quantity {
            b["quantity"] = newQuantity.map { .int($0) } ?? .null
        }
        if confirmNow { b["confirm"] = .bool(true) }
        return b
    }

    static func hasChanges(_ body: [String: StoreJSONValue]) -> Bool {
        body.keys.contains { $0 != "baseVersion" }
    }
}
