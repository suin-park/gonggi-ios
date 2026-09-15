import Foundation

enum CatalogCurtainPlacementValidator {
    static func canPlace(product: CatalogProduct, variant: CatalogVariant?) -> Bool {
        guard product.placementType == .curtain2D else { return false }
        guard product.placementType.isSupportedForPlacement else { return false }
        guard let variant else { return false }
        if product.availableForPlacement == false && variant.availableForPlacement == false {
            return false
        }
        return !product.id.isEmpty && !variant.id.isEmpty
    }
}
