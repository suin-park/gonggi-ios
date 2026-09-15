import XCTest
@testable import Gonggi

final class CatalogFurnitureARControllerTests: XCTestCase {
    private func furniture(available: Bool?) -> CatalogProduct {
        CatalogProduct(
            id: "f1",
            partnerId: "jd",
            partner: nil,
            productName: "3단 도어장",
            shortDescription: nil,
            brandName: nil,
            category: .furniture,
            placementType: .furniture3D,
            displayPriceMinor: nil,
            currency: "KRW",
            thumbnailUrl: nil,
            widthMm: 400,
            depthMm: 290,
            heightMm: 1084,
            variantCount: 1,
            selectedVariantName: "우드",
            catalogRevision: 1,
            productRevision: "r1",
            availableForPlacement: available,
            detailUrl: nil,
            purchaseUrl: nil,
            consultationUrl: nil,
            variants: nil
        )
    }

    func testAREnabledForFurnitureWhenAvailable() {
        XCTAssertTrue(CatalogFurnitureARController.isEnabled(product: furniture(available: true)))
        XCTAssertTrue(CatalogFurnitureARController.isEnabled(product: furniture(available: nil)))
    }

    func testARDisabledWhenUnavailable() {
        XCTAssertFalse(CatalogFurnitureARController.isEnabled(product: furniture(available: false)))
    }

    func testARHiddenLogicForCurtain() {
        let curtain = CatalogProduct(
            id: "c1",
            partnerId: "homes",
            partner: nil,
            productName: "커튼",
            shortDescription: nil,
            brandName: nil,
            category: .curtain,
            placementType: .curtain2D,
            displayPriceMinor: nil,
            currency: "KRW",
            thumbnailUrl: nil,
            widthMm: 2000,
            depthMm: 50,
            heightMm: 2400,
            variantCount: 1,
            selectedVariantName: nil,
            catalogRevision: 1,
            productRevision: "r1",
            availableForPlacement: true,
            detailUrl: nil,
            purchaseUrl: nil,
            consultationUrl: nil,
            variants: nil
        )
        XCTAssertFalse(CatalogFurnitureARController.isEnabled(product: curtain))
    }
}
