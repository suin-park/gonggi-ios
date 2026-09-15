import Foundation

enum CatalogMockData {
    static let roundCabinetProductId = "mock-catalog-round-cabinet"
    static let roundCabinetVariantId = "mock-catalog-round-cabinet-default"
    static let roundCabinetAssetId = "mock-casset-round-01"
    static let roundCabinetOwnedId = "mock-owned-round-01"

    static func listProducts() -> [CatalogProduct] {
        [roundCabinetListCard(), mockCurtainPlaceholderCard()]
    }

    static func listPayload() -> CatalogListPayload {
        let products = listProducts()
        return CatalogListPayload(
            products: products,
            categories: [
                CatalogCategory(
                    id: "mock-furniture",
                    name: "수납장",
                    sortOrder: 0,
                    products: [roundCabinetListCard()]
                ),
                CatalogCategory(
                    id: "mock-curtain",
                    name: "커튼",
                    sortOrder: 1,
                    products: [mockCurtainPlaceholderCard()]
                ),
            ]
        )
    }

    static func detailProduct(id: String) -> CatalogProduct? {
        switch id {
        case roundCabinetProductId:
            return roundCabinetDetail()
        case "mock-catalog-curtain-sample":
            return mockCurtainDetail()
        default:
            return nil
        }
    }

    static func roundCabinetListCard() -> CatalogProduct {
        CatalogProduct(
            id: roundCabinetProductId,
            partnerId: "jd-homedressing",
            partner: CatalogPartner(
                id: "jd-homedressing",
                slug: "jd-homedressing",
                displayBrandName: "JD홈드레싱"
            ),
            productName: "3단 라운드 마감장",
            shortDescription: "Mock 상품 · 실제 판매가·URL 아님",
            brandName: "JD홈드레싱",
            category: .furniture,
            placementType: .furniture3D,
            displayPriceMinor: nil,
            currency: "KRW",
            thumbnailUrl: nil,
            widthMm: 290,
            depthMm: 290,
            heightMm: 1084,
            variantCount: 1,
            selectedVariantName: "기본",
            catalogRevision: 1,
            productRevision: "mock-rev-1",
            availableForPlacement: true,
            detailUrl: nil,
            purchaseUrl: nil,
            consultationUrl: nil,
            variants: nil
        )
    }

    /// Mock-only curtain card so category expansion can be verified without Production rows.
    static func mockCurtainPlaceholderCard() -> CatalogProduct {
        CatalogProduct(
            id: "mock-catalog-curtain-sample",
            partnerId: "jd-homedressing",
            partner: CatalogPartner(
                id: "jd-homedressing",
                slug: "jd-homedressing",
                displayBrandName: "JD홈드레싱"
            ),
            productName: "커튼 샘플 (Mock)",
            shortDescription: "Mock 전용 · AI 커튼 미리보기 POC",
            brandName: "JD홈드레싱",
            category: .curtain,
            placementType: .curtain2D,
            displayPriceMinor: nil,
            currency: "KRW",
            thumbnailUrl: nil,
            widthMm: 2000,
            depthMm: 50,
            heightMm: 2400,
            variantCount: 1,
            selectedVariantName: "기본",
            catalogRevision: 1,
            productRevision: "mock-curtain-1",
            availableForPlacement: true,
            detailUrl: nil,
            purchaseUrl: nil,
            consultationUrl: nil,
            variants: nil
        )
    }

    static func roundCabinetPlacementSpec() -> CatalogPlacementSpec {
        CatalogPlacementSpec(
            contractVersion: 1,
            coordinateConvention: CatalogPlacementSpec.supportedCoordinateConvention,
            placementType: .furniture3D,
            axisMapping: CatalogAxisMapping(width: "x", height: "y", depth: "z"),
            orientation: CatalogQuaternion(x: 0, y: 0, z: 0, w: 1),
            scaleX: 1,
            scaleY: 1,
            scaleZ: 1,
            bottomOffsetMeters: 0,
            canonicalBounds: CatalogCanonicalBounds(
                min: CatalogVec3(x: -0.145, y: 0, z: -0.145),
                max: CatalogVec3(x: 0.145, y: 1.084, z: 0.145)
            ),
            dimensionsMm: CatalogDimensions(widthMm: 290, depthMm: 290, heightMm: 1084),
            catalogAssetId: roundCabinetAssetId,
            catalogOwnedAssetId: roundCabinetOwnedId,
            catalogRevision: 1,
            productRevision: "mock-rev-1",
            variantRevision: "default",
            usdzSignedUrl: "https://example.invalid/mock/catalog/round-cabinet.usdz",
            usdzSignedUrlExpiresAt: ISO8601DateFormatter().string(
                from: Date().addingTimeInterval(3600)
            )
        )
    }

    static func roundCabinetDetail() -> CatalogProduct {
        var card = roundCabinetListCard()
        let spec = roundCabinetPlacementSpec()
        card.variants = [
            CatalogVariant(
                id: roundCabinetVariantId,
                sourceVariantKey: "default",
                name: "기본",
                hexCode: nil,
                widthMm: 290,
                depthMm: 290,
                heightMm: 1084,
                thumbnailUrl: nil,
                usdzUrl: spec.usdzSignedUrl,
                usdzSignedUrlExpiresAt: spec.usdzSignedUrlExpiresAt,
                catalogAssetId: roundCabinetAssetId,
                catalogOwnedAssetId: roundCabinetOwnedId,
                placementSpec: spec,
                availableForPlacement: true
            ),
        ]
        return card
    }

    static func mockCurtainDetail() -> CatalogProduct {
        var card = mockCurtainPlaceholderCard()
        card.catalog2DAssetId = "mock-curtain-2d-asset"
        card.catalog2DAssetStatus = "READY"
        card.variants = [
            CatalogVariant(
                id: "mock-curtain-variant",
                sourceVariantKey: "default",
                name: "기본",
                hexCode: nil,
                widthMm: 2000,
                depthMm: 50,
                heightMm: 2400,
                thumbnailUrl: nil,
                usdzUrl: nil,
                usdzSignedUrlExpiresAt: nil,
                catalogAssetId: "mock-curtain-2d-asset",
                catalogOwnedAssetId: "mock-curtain-owned-2d",
                placementSpec: nil,
                availableForPlacement: true
            ),
        ]
        return card
    }
}
