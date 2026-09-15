import XCTest
@testable import Gonggi

final class CatalogVariantOptionTests: XCTestCase {
    func testResolvedOptionsPreferAPIOptions() {
        var product = sampleProduct(name: "우드", options: nil, variants: nil)
        product.variantOptions = [
            CatalogVariantOption(id: "v-wood", name: "우드", hexCode: "#C4A574", widthMm: 400, depthMm: 290, heightMm: 1084),
            CatalogVariantOption(id: "v-white", name: "화이트", hexCode: "#FFFFFF", widthMm: 400, depthMm: 290, heightMm: 1084),
        ]
        XCTAssertEqual(product.resolvedVariantOptions.map(\.name), ["우드", "화이트"])
        XCTAssertEqual(product.variantOption(id: "v-white")?.name, "화이트")
        XCTAssertEqual(product.variantOption(id: nil)?.id, "v-wood")
    }

    func testResolvedOptionsFallbackToSelectedName() {
        let product = sampleProduct(name: "기본", options: nil, variants: nil)
        let options = product.resolvedVariantOptions
        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options.first?.name, "기본")
    }

    func testResolveVariantPrefersSelectedId() {
        let wood = CatalogVariant(
            id: "v-wood",
            sourceVariantKey: nil,
            name: "우드",
            hexCode: nil,
            widthMm: 400,
            depthMm: 290,
            heightMm: 1084,
            thumbnailUrl: nil,
            usdzUrl: "https://example.com/wood.usdz",
            usdzSignedUrlExpiresAt: nil,
            catalogAssetId: "a1",
            catalogOwnedAssetId: "o1",
            placementSpec: nil,
            availableForPlacement: true
        )
        let white = CatalogVariant(
            id: "v-white",
            sourceVariantKey: nil,
            name: "화이트",
            hexCode: nil,
            widthMm: 400,
            depthMm: 290,
            heightMm: 1084,
            thumbnailUrl: nil,
            usdzUrl: "https://example.com/white.usdz",
            usdzSignedUrlExpiresAt: nil,
            catalogAssetId: "a2",
            catalogOwnedAssetId: "o2",
            placementSpec: nil,
            availableForPlacement: true
        )
        var product = sampleProduct(name: "우드", options: nil, variants: [wood, white])
        product.variants = [wood, white]

        let resolved = CatalogCurtainListPlaceController.resolveVariant(
            in: product,
            preferredId: "v-white"
        )
        XCTAssertEqual(resolved?.id, "v-white")
        XCTAssertEqual(
            CatalogCurtainListPlaceController.resolveVariant(in: product, preferredId: "missing")?.id,
            "v-wood"
        )
    }

    private func sampleProduct(
        name: String,
        options: [CatalogVariantOption]?,
        variants: [CatalogVariant]?
    ) -> CatalogProduct {
        CatalogProduct(
            id: "p1",
            partnerId: "partner",
            partner: nil,
            productName: "테스트 가구",
            shortDescription: nil,
            brandName: "브랜드",
            category: nil,
            placementType: .furniture3D,
            displayPriceMinor: nil,
            currency: "KRW",
            thumbnailUrl: nil,
            widthMm: 400,
            depthMm: 290,
            heightMm: 1084,
            variantCount: options?.count ?? 1,
            selectedVariantName: name,
            variantOptions: options,
            catalogRevision: 1,
            productRevision: nil,
            availableForPlacement: true,
            detailUrl: nil,
            purchaseUrl: nil,
            consultationUrl: nil,
            variants: variants
        )
    }
}
