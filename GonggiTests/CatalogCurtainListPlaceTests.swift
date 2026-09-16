import XCTest
@testable import Gonggi

@MainActor
final class CatalogCurtainListPlaceTests: XCTestCase {
    private final class RecordingCatalogClient: CatalogServing, @unchecked Sendable {
        var detailResult: Result<CatalogProduct, Error>
        private(set) var fetchCount = 0

        init(detailResult: Result<CatalogProduct, Error>) {
            self.detailResult = detailResult
        }

        func fetchCatalogList() async throws -> CatalogListPayload {
            CatalogListPayload(products: [], categories: [])
        }

        func fetchProduct(id: String) async throws -> CatalogProduct {
            fetchCount += 1
            _ = id
            return try detailResult.get()
        }

        func recordEvent(_ request: CatalogEventRequest) async {}
    }

    private func listCurtain(
        available: Bool?,
        variants: [CatalogVariant]? = nil
    ) -> CatalogProduct {
        CatalogProduct(
            id: "curtain-list-1",
            partnerId: "homes",
            partner: CatalogPartner(id: "homes", slug: "homes", displayBrandName: "홈스커튼"),
            productName: "로만쉐이드",
            shortDescription: nil,
            brandName: "홈스커튼",
            category: .curtain,
            placementType: .curtain2D,
            displayPriceMinor: 11_000,
            currency: "KRW",
            thumbnailUrl: nil,
            widthMm: 2400,
            depthMm: 50,
            heightMm: 2200,
            variantCount: 1,
            selectedVariantName: "로만쉐이드",
            catalogRevision: 1,
            productRevision: "r1",
            availableForPlacement: available,
            detailUrl: nil,
            purchaseUrl: nil,
            consultationUrl: nil,
            variants: variants,
            catalog2DAssetId: nil
        )
    }

    private func detailCurtain(
        withVariant: Bool,
        available: Bool = true,
        catalog2DAssetId: String? = "c2d_ready"
    ) -> CatalogProduct {
        var product = listCurtain(available: available)
        product.catalog2DAssetId = catalog2DAssetId
        if withVariant {
            product.variants = [
                CatalogVariant(
                    id: "var-1",
                    sourceVariantKey: "default",
                    name: "로만쉐이드",
                    hexCode: nil,
                    widthMm: 2400,
                    depthMm: 50,
                    heightMm: 2200,
                    thumbnailUrl: nil,
                    usdzUrl: nil,
                    usdzSignedUrlExpiresAt: nil,
                    catalogAssetId: nil,
                    catalogOwnedAssetId: nil,
                    placementSpec: nil,
                    availableForPlacement: true
                ),
            ]
        } else {
            product.variants = []
        }
        return product
    }

    private func furnitureList() -> CatalogProduct {
        CatalogProduct(
            id: "furn-1",
            partnerId: "jd",
            partner: nil,
            productName: "수납장",
            shortDescription: nil,
            brandName: nil,
            category: .furniture,
            placementType: .furniture3D,
            displayPriceMinor: nil,
            currency: "KRW",
            thumbnailUrl: nil,
            widthMm: 100,
            depthMm: 100,
            heightMm: 100,
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
    }

    private func makeApp() -> AppState {
        let suiteName = "curtain-list-place-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = SpaceJobStore(defaults: defaults, persistEnabled: false)
        store.bind(.user(userId: "test-curtain-list"))
        return AppState(isMockMode: true, jobStore: store)
    }

    private func placeableSpace(id: String = "space-1") -> SpaceRecord {
        let sample = SpaceRecord.sampleArchive[0]
        return SpaceRecord(
            id: id,
            name: "내 공간",
            capturedAt: sample.capturedAt,
            status: .ready,
            thumbnailSystemImage: sample.thumbnailSystemImage,
            note: sample.note,
            memo: sample.memo,
            viewerURL: sample.viewerURL,
            sessionId: id,
            remoteImageURL: "https://example.com/outdoor-alley.jpg"
        )
    }

    func testListCTAEnabledWhenCurtainAvailableWithoutVariants() {
        let product = listCurtain(available: true, variants: nil)
        XCTAssertNil(product.primaryVariant)
        XCTAssertFalse(
            CatalogCurtainPlacementValidator.canPlace(product: product, variant: product.primaryVariant)
        )
        XCTAssertTrue(CatalogCurtainListCTA.isEnabled(product: product))
    }

    func testListCTADisabledWhenAvailableFalse() {
        XCTAssertFalse(CatalogCurtainListCTA.isEnabled(product: listCurtain(available: false)))
        XCTAssertFalse(CatalogCurtainListCTA.isEnabled(product: listCurtain(available: nil)))
    }

    func testListCTAIgnoresFurniture() {
        XCTAssertFalse(CatalogCurtainListCTA.isEnabled(product: furnitureList()))
    }

    func testOutdoorSpaceDoesNotAffectListCTA() {
        // Space imagery is irrelevant to CTA enablement.
        let product = listCurtain(available: true)
        XCTAssertTrue(CatalogCurtainListCTA.isEnabled(product: product))
        XCTAssertFalse(CatalogPlaceSpacePickerView.placeableSpaces(from: [placeableSpace()]).isEmpty)
    }

    func testTapFetchesDetailThenStartsPlacement() async {
        let client = RecordingCatalogClient(detailResult: .success(detailCurtain(withVariant: true)))
        let app = makeApp()
        let controller = CatalogCurtainListPlaceController()
        let list = listCurtain(available: true)

        controller.placeTapped(
            listProduct: list,
            client: client,
            spaces: [placeableSpace()],
            appState: app
        )
        let deadline = Date().addingTimeInterval(2)
        while case .loading = controller.phase, Date() < deadline {
            await Task.yield()
        }

        XCTAssertEqual(client.fetchCount, 1)
        if case .started = controller.phase {
            // ok
        } else {
            XCTFail("expected started, got \(controller.phase)")
        }
        XCTAssertEqual(app.pendingCurtainPlacement?.productId, "curtain-list-1")
        XCTAssertEqual(app.pendingCurtainPlacement?.variantId, "var-1")
        XCTAssertEqual(app.pendingCurtainPlacement?.catalog2DAssetId, "c2d_ready")
        XCTAssertEqual(app.pendingViewerJobId, "space-1")
    }

    func testMissingVariantShowsErrorAndAllowsRetry() async {
        let client = RecordingCatalogClient(detailResult: .success(detailCurtain(withVariant: false)))
        let app = makeApp()
        let controller = CatalogCurtainListPlaceController()

        controller.placeTapped(
            listProduct: listCurtain(available: true),
            client: client,
            spaces: [placeableSpace()],
            appState: app
        )
        let deadline = Date().addingTimeInterval(2)
        while case .loading = controller.phase, Date() < deadline {
            await Task.yield()
        }

        guard case .error(_, let message) = controller.phase else {
            return XCTFail("expected error")
        }
        XCTAssertTrue(message.contains("옵션"))
        XCTAssertNil(app.pendingCurtainPlacement)

        client.detailResult = .success(detailCurtain(withVariant: true))
        controller.retry(client: client, spaces: [placeableSpace()], appState: app)
        let deadline2 = Date().addingTimeInterval(2)
        while case .loading = controller.phase, Date() < deadline2 {
            await Task.yield()
        }
        if case .started = controller.phase {
            XCTAssertEqual(client.fetchCount, 2)
        } else {
            XCTFail("retry should start placement, got \(controller.phase)")
        }
    }

    func testFetchFailureClearsLoadingAndAllowsRetry() async {
        let client = RecordingCatalogClient(detailResult: .failure(CatalogAPIError.offline))
        let app = makeApp()
        let controller = CatalogCurtainListPlaceController()

        controller.placeTapped(
            listProduct: listCurtain(available: true),
            client: client,
            spaces: [placeableSpace()],
            appState: app
        )
        let deadline = Date().addingTimeInterval(2)
        while case .loading = controller.phase, Date() < deadline {
            await Task.yield()
        }

        guard case .error(_, let message) = controller.phase else {
            return XCTFail("expected error")
        }
        XCTAssertEqual(message, CatalogAPIError.offline.userMessage)
        XCTAssertNil(controller.loadingProductId)

        client.detailResult = .success(detailCurtain(withVariant: true))
        controller.retry(client: client, spaces: [placeableSpace()], appState: app)
        let deadline2 = Date().addingTimeInterval(2)
        while case .loading = controller.phase, Date() < deadline2 {
            await Task.yield()
        }
        XCTAssertEqual(client.fetchCount, 2)
        if case .started = controller.phase {} else {
            XCTFail("expected started after retry")
        }
    }

    func testDuplicateTapDoesNotDoubleFetch() async {
        let client = RecordingCatalogClient(detailResult: .success(detailCurtain(withVariant: true)))
        let app = makeApp()
        let controller = CatalogCurtainListPlaceController()
        let list = listCurtain(available: true)

        controller.placeTapped(listProduct: list, client: client, spaces: [placeableSpace()], appState: app)
        controller.placeTapped(listProduct: list, client: client, spaces: [placeableSpace()], appState: app)
        controller.placeTapped(listProduct: list, client: client, spaces: [placeableSpace()], appState: app)

        let deadline = Date().addingTimeInterval(2)
        while case .loading = controller.phase, Date() < deadline {
            await Task.yield()
        }

        XCTAssertEqual(client.fetchCount, 1)
        XCTAssertNotNil(app.pendingCurtainPlacement)
    }

    func testSessionCacheSkipsSecondNetworkFetch() async {
        let client = RecordingCatalogClient(detailResult: .success(detailCurtain(withVariant: true)))
        let app = makeApp()
        let controller = CatalogCurtainListPlaceController()
        let list = listCurtain(available: true)

        controller.placeTapped(listProduct: list, client: client, spaces: [placeableSpace()], appState: app)
        let deadline = Date().addingTimeInterval(2)
        while case .loading = controller.phase, Date() < deadline {
            await Task.yield()
        }
        controller.clearStartedMessage()

        controller.placeTapped(listProduct: list, client: client, spaces: [placeableSpace()], appState: app)
        let deadline2 = Date().addingTimeInterval(2)
        while case .loading = controller.phase, Date() < deadline2 {
            await Task.yield()
        }

        XCTAssertEqual(client.fetchCount, 1)
        XCTAssertNotNil(controller.cachedProductForTesting(id: list.id))
    }

    func testCanPlaceStillRequiresVariant() {
        let product = listCurtain(available: true, variants: nil)
        XCTAssertFalse(
            CatalogCurtainPlacementValidator.canPlace(product: product, variant: nil)
        )
    }
}
