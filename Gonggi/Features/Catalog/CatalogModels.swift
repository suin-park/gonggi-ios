import Foundation

// MARK: - Placement type

enum CatalogPlacementType: String, Codable, Sendable, Equatable {
    case furniture3D = "FURNITURE_3D"
    case curtain2D = "CURTAIN_2D"
    case unsupported = "UNSUPPORTED"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CatalogPlacementType(rawValue: raw) ?? .unsupported
    }

    var isSupportedForPlacement: Bool { self == .furniture3D || self == .curtain2D }

    var displayCategoryTitle: String {
        switch self {
        case .furniture3D: return "가구"
        case .curtain2D: return "커튼"
        case .unsupported: return "기타"
        }
    }
}

enum CatalogProductCategory: String, Codable, Sendable, Equatable {
    case furniture = "FURNITURE"
    case curtain = "CURTAIN"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "FURNITURE": self = .furniture
        case "CURTAIN": self = .curtain
        default:
            // Unknown categories decode as furniture only for Codable stability;
            // placementType still gates placement.
            self = .furniture
        }
    }
}

// MARK: - Partner / link / dimensions

struct CatalogPartner: Codable, Sendable, Equatable, Hashable {
    var id: String
    var slug: String
    var displayBrandName: String
}

struct CatalogLink: Codable, Sendable, Equatable {
    var detailUrl: String?
    var purchaseUrl: String?
    var consultationUrl: String?
}

struct CatalogDimensions: Codable, Sendable, Equatable, Hashable {
    var widthMm: Int
    var depthMm: Int
    var heightMm: Int

    var isValid: Bool {
        widthMm > 0 && depthMm > 0 && heightMm > 0
    }

    var accessibilityLabel: String {
        "너비 \(widthMm)밀리미터, 깊이 \(depthMm)밀리미터, 높이 \(heightMm)밀리미터"
    }

    /// Product card / detail short label — Catalog mm is the source of truth.
    var shortLabelMm: String {
        "W \(widthMm) × D \(depthMm) × H \(heightMm) mm"
    }

    @available(*, deprecated, renamed: "shortLabelMm")
    var shortLabelCm: String { shortLabelMm }
}

struct CatalogVec3: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var z: Double
}

struct CatalogQuaternion: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var z: Double
    var w: Double
}

struct CatalogAxisMapping: Codable, Sendable, Equatable {
    var width: String
    var height: String
    var depth: String
}

struct CatalogCanonicalBounds: Codable, Sendable, Equatable {
    var min: CatalogVec3
    var max: CatalogVec3
}

struct CatalogPlacementSpec: Codable, Sendable, Equatable {
    static let supportedContractVersion = 1
    static let supportedCoordinateConvention = "scenekit_y_up_front_neg_z_v1"

    var contractVersion: Int
    var coordinateConvention: String
    var placementType: CatalogPlacementType
    var axisMapping: CatalogAxisMapping
    var orientation: CatalogQuaternion
    var scaleX: Double
    var scaleY: Double
    var scaleZ: Double
    var bottomOffsetMeters: Double
    var canonicalBounds: CatalogCanonicalBounds
    var dimensionsMm: CatalogDimensions
    var catalogAssetId: String
    var catalogOwnedAssetId: String
    var catalogRevision: Int
    var productRevision: String
    var variantRevision: String?
    var usdzSignedUrl: String
    var usdzSignedUrlExpiresAt: String?
}

struct CatalogAsset: Codable, Sendable, Equatable {
    var catalogAssetId: String?
    var catalogOwnedAssetId: String?
    var thumbnailUrl: String?
    var usdzUrl: String?
    var usdzSignedUrlExpiresAt: String?
    var placementSpec: CatalogPlacementSpec?
    var availableForPlacement: Bool
}

struct CatalogVariant: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var sourceVariantKey: String?
    var name: String
    var hexCode: String?
    var widthMm: Int
    var depthMm: Int
    var heightMm: Int
    var thumbnailUrl: String?
    var usdzUrl: String?
    var usdzSignedUrlExpiresAt: String?
    var catalogAssetId: String?
    var catalogOwnedAssetId: String?
    var placementSpec: CatalogPlacementSpec?
    var availableForPlacement: Bool

    var dimensions: CatalogDimensions {
        CatalogDimensions(widthMm: widthMm, depthMm: depthMm, heightMm: heightMm)
    }
}

struct CatalogProduct: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var partnerId: String
    var partner: CatalogPartner?
    var productName: String
    var shortDescription: String?
    var brandName: String?
    var category: CatalogProductCategory?
    var placementType: CatalogPlacementType
    var displayPriceMinor: Int?
    var currency: String?
    var thumbnailUrl: String?
    var widthMm: Int
    var depthMm: Int
    var heightMm: Int
    var variantCount: Int?
    var selectedVariantName: String?
    var catalogRevision: Int?
    var productRevision: String?
    var availableForPlacement: Bool?
    var detailUrl: String?
    var purchaseUrl: String?
    var consultationUrl: String?
    var variants: [CatalogVariant]?

    var partnerDisplayName: String {
        partner?.displayBrandName ?? brandName ?? "제휴 업체"
    }

    var dimensions: CatalogDimensions {
        CatalogDimensions(widthMm: widthMm, depthMm: depthMm, heightMm: heightMm)
    }

    var primaryVariant: CatalogVariant? {
        variants?.first(where: { $0.availableForPlacement }) ?? variants?.first
    }

    var priceLabel: String {
        if let minor = displayPriceMinor, minor > 0, let currency {
            if currency.uppercased() == "KRW" {
                let won = minor
                let formatter = NumberFormatter()
                formatter.numberStyle = .decimal
                let formatted = formatter.string(from: NSNumber(value: won)) ?? "\(won)"
                return "\(formatted)원"
            }
            return "\(minor) \(currency)"
        }
        // No sale price → always show inquiry (links optional; placement still available).
        return "가격 문의"
    }

    /// VoiceOver / combined a11y — avoid "가격 가격 문의".
    var priceAccessibilityLabel: String {
        if priceLabel == "가격 문의" { return "가격 문의" }
        return "가격 \(priceLabel)"
    }

    /// Final card thumbnail: product URL → primary variant URL (HTTPS only).
    var resolvedThumbnailURL: String? {
        if let product = CatalogThumbnailURL.sanitizedHTTPSString(thumbnailUrl) {
            return product
        }
        if let variant = CatalogThumbnailURL.sanitizedHTTPSString(primaryVariant?.thumbnailUrl) {
            return variant
        }
        return variants?
            .lazy
            .compactMap { CatalogThumbnailURL.sanitizedHTTPSString($0.thumbnailUrl) }
            .first
    }
}

struct CatalogProductListResponse: Codable, Sendable {
    var ok: Bool?
    var products: [CatalogProduct]
    var categories: [CatalogCategory]?
}

struct CatalogCategory: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var sortOrder: Int?
    var products: [CatalogProduct]
}

struct CatalogListPayload: Sendable, Equatable {
    var products: [CatalogProduct]
    var categories: [CatalogCategory]

    /// Prefer server categories; otherwise one fallback section with all products.
    /// Published products missing from every category become a trailing `기타` row.
    static func normalize(products: [CatalogProduct], categories: [CatalogCategory]?) -> CatalogListPayload {
        let filteredProducts = products.filter { $0.placementType != .unsupported }
        let byId = Dictionary(uniqueKeysWithValues: filteredProducts.map { ($0.id, $0) })
        if let categories, !categories.isEmpty {
            var mapped = categories.compactMap { cat -> CatalogCategory? in
                let items: [CatalogProduct]
                if cat.products.isEmpty {
                    items = []
                } else {
                    items = cat.products.compactMap { card in
                        let resolved = byId[card.id] ?? card
                        return resolved.placementType == .unsupported ? nil : resolved
                    }
                }
                guard !items.isEmpty else { return nil }
                return CatalogCategory(
                    id: cat.id,
                    name: cat.name,
                    sortOrder: cat.sortOrder,
                    products: items
                )
            }
            if !mapped.isEmpty {
                let assigned = Set(mapped.flatMap { $0.products.map(\.id) })
                let leftover = filteredProducts.filter { !assigned.contains($0.id) }
                if !leftover.isEmpty {
                    // Prefer server-provided 기타 row when present; otherwise append.
                    if let idx = mapped.firstIndex(where: { $0.id == "uncategorized" || $0.name == "기타" }) {
                        let existingIds = Set(mapped[idx].products.map(\.id))
                        let extras = leftover.filter { !existingIds.contains($0.id) }
                        if !extras.isEmpty {
                            var merged = mapped[idx]
                            merged.products.append(contentsOf: extras)
                            mapped[idx] = merged
                        }
                    } else {
                        mapped.append(
                            CatalogCategory(
                                id: "uncategorized",
                                name: "기타",
                                sortOrder: 9999,
                                products: leftover
                            )
                        )
                    }
                }
                return CatalogListPayload(products: filteredProducts, categories: mapped)
            }
        }
        guard !filteredProducts.isEmpty else {
            return CatalogListPayload(products: [], categories: [])
        }
        // No merchandising categories → single section (UI hides row title).
        return CatalogListPayload(
            products: filteredProducts,
            categories: [
                CatalogCategory(
                    id: "all",
                    name: "제휴 상품",
                    sortOrder: 0,
                    products: filteredProducts
                )
            ]
        )
    }

    /// True when categories are real merchandising shelves (show per-row titles).
    static func shouldShowCategoryTitles(_ categories: [CatalogCategory]) -> Bool {
        guard !categories.isEmpty else { return false }
        if categories.count > 1 { return true }
        let only = categories[0]
        if only.id == "all" { return false }
        if only.id == "uncategorized", only.name == "제휴 상품" { return false }
        return true
    }
}

struct CatalogProductDetailResponse: Codable, Sendable {
    var ok: Bool?
    var product: CatalogProduct
}

struct CatalogEventRequest: Codable, Sendable {
    var type: String
    var productId: String
    var variantId: String?
    var spaceId: String?
    var payload: CatalogEventPayload?
}

struct CatalogEventPayload: Codable, Sendable {
    var channel: String?
    var host: String?
    var appBuild: String?
    /// Cloud sanitizes to host only; never send full URL as other keys.
    var outboundUrl: String?
}
