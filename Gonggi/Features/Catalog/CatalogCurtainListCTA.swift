import Foundation

/// Home/list CTA eligibility for curtains when the list payload omits `variants`.
/// Does **not** replace `CatalogCurtainPlacementValidator.canPlace` (variant still required to start).
enum CatalogCurtainListCTA {
    static func isEnabled(product: CatalogProduct) -> Bool {
        guard product.placementType == .curtain2D else { return false }
        guard product.placementType.isSupportedForPlacement else { return false }
        return product.availableForPlacement == true
    }
}
