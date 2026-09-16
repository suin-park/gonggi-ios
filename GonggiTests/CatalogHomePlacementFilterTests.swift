import XCTest
@testable import Gonggi

final class CatalogHomePlacementFilterTests: XCTestCase {
    private func product(id: String, type: CatalogPlacementType) -> CatalogProduct {
        CatalogProduct(
            id: id,
            partnerId: "p",
            partner: nil,
            productName: id,
            shortDescription: nil,
            brandName: nil,
            category: type == .curtain2D ? .curtain : .furniture,
            placementType: type,
            displayPriceMinor: nil,
            currency: "KRW",
            thumbnailUrl: nil,
            widthMm: 100,
            depthMm: 100,
            heightMm: 100,
            variantCount: 1,
            selectedVariantName: nil,
            catalogRevision: nil,
            productRevision: nil,
            availableForPlacement: true,
            detailUrl: nil,
            purchaseUrl: nil,
            consultationUrl: nil,
            variants: nil
        )
    }

    func testDefaultPreferredIsCurtain() {
        let suiteName = "CatalogHomeFilter.default.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        XCTAssertEqual(CatalogHomePlacementFilter.loadPersisted(defaults: suite), .curtain)
    }

    func testResolveFallsBackToFurnitureWhenNoCurtain() {
        let products = [product(id: "f1", type: .furniture3D)]
        let resolved = CatalogHomePlacementFilter.resolveSelection(products: products, preferred: .curtain)
        XCTAssertEqual(resolved, .furniture)
    }

    func testResolveKeepsCurtainWhenOnlyCurtain() {
        let products = [product(id: "c1", type: .curtain2D)]
        let resolved = CatalogHomePlacementFilter.resolveSelection(products: products, preferred: .furniture)
        XCTAssertEqual(resolved, .curtain)
    }

    func testResolveNilWhenBothEmpty() {
        XCTAssertNil(
            CatalogHomePlacementFilter.resolveSelection(products: [], preferred: .curtain)
        )
    }

    func testFilterUsesPlacementTypeNotName() {
        let products = [
            product(id: "named-curtain-but-furniture", type: .furniture3D),
            product(id: "c1", type: .curtain2D),
        ]
        let filtered = CatalogHomePlacementFilter.filterProducts(products, by: .curtain)
        XCTAssertEqual(filtered.map(\.id), ["c1"])
    }

    func testScrollResetTokenIncrementsOnFilterChange() {
        XCTAssertEqual(
            CatalogHomePlacementFilter.nextScrollResetToken(previous: 3, didChangeFilter: true),
            4
        )
        XCTAssertEqual(
            CatalogHomePlacementFilter.nextScrollResetToken(previous: 3, didChangeFilter: false),
            3
        )
    }

    @MainActor
    func testViewModelPersistsFilterAndResetsScroll() {
        let suiteName = "CatalogHomeFilter.vm.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let vm = CatalogHomeViewModel(isMockMode: true, defaults: suite)
        XCTAssertEqual(vm.selectedFilter, .curtain)
        let tokenBefore = vm.productScrollResetToken
        vm.selectFilter(.furniture)
        XCTAssertEqual(vm.selectedFilter, .furniture)
        XCTAssertEqual(CatalogHomePlacementFilter.loadPersisted(defaults: suite), .furniture)
        XCTAssertEqual(vm.productScrollResetToken, tokenBefore + 1)
    }
}
