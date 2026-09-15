import Foundation

/// Home catalog segmented filter: curtain vs furniture only (no “전체”).
enum CatalogHomePlacementFilter: String, CaseIterable, Identifiable, Sendable {
    case curtain
    case furniture

    static let userDefaultsKey = "gonggi.catalog.homePlacementFilter"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .curtain: return "커튼"
        case .furniture: return "가구"
        }
    }

    var sectionDescription: String {
        switch self {
        case .curtain:
            return "내 공간의 창문에 제휴 커튼을 적용해보세요."
        case .furniture:
            return "내 공간에 실제 규격의 제휴 가구를 놓아보세요."
        }
    }

    var placementType: CatalogPlacementType {
        switch self {
        case .curtain: return .curtain2D
        case .furniture: return .furniture3D
        }
    }

    static func loadPersisted(defaults: UserDefaults = .standard) -> CatalogHomePlacementFilter {
        guard let raw = defaults.string(forKey: userDefaultsKey),
              let value = CatalogHomePlacementFilter(rawValue: raw)
        else {
            return .curtain
        }
        return value
    }

    func persist(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.userDefaultsKey)
    }

    /// Default curtain; fall back when the preferred type has no products.
    /// Returns `nil` when both curtain and furniture lists are empty.
    static func resolveSelection(
        products: [CatalogProduct],
        preferred: CatalogHomePlacementFilter
    ) -> CatalogHomePlacementFilter? {
        let hasCurtain = products.contains { $0.placementType == .curtain2D }
        let hasFurniture = products.contains { $0.placementType == .furniture3D }
        guard hasCurtain || hasFurniture else { return nil }

        switch preferred {
        case .curtain:
            if hasCurtain { return .curtain }
            return .furniture
        case .furniture:
            if hasFurniture { return .furniture }
            return .curtain
        }
    }

    static func filterProducts(
        _ products: [CatalogProduct],
        by filter: CatalogHomePlacementFilter
    ) -> [CatalogProduct] {
        products.filter { $0.placementType == filter.placementType }
    }

    static func filterCategories(
        _ categories: [CatalogCategory],
        by filter: CatalogHomePlacementFilter
    ) -> [CatalogCategory] {
        categories.compactMap { category in
            let items = filterProducts(category.products, by: filter)
            guard !items.isEmpty else { return nil }
            return CatalogCategory(
                id: category.id,
                name: category.name,
                sortOrder: category.sortOrder,
                products: items
            )
        }
    }

    /// Bump a scroll identity when the filter changes so the horizontal row resets to the start.
    static func nextScrollResetToken(previous: UInt64, didChangeFilter: Bool) -> UInt64 {
        didChangeFilter ? previous &+ 1 : previous
    }
}
