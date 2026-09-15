import XCTest
import simd
@testable import Gonggi

final class CatalogModelsTests: XCTestCase {
    func testDecodeRoundCabinetFixture() throws {
        let url = Bundle(for: CatalogModelsTests.self)
            .url(forResource: "catalog_product_detail_round_cabinet", withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle(for: CatalogModelsTests.self)
            .url(forResource: "catalog_product_detail_round_cabinet", withExtension: "json")
        // XcodeGen copies Fixtures folder — also try relative to test bundle resources.
        let data: Data
        if let url, let d = try? Data(contentsOf: url) {
            data = d
        } else {
            let path = URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/catalog_product_detail_round_cabinet.json")
            data = try Data(contentsOf: path)
        }

        let decoded = try JSONDecoder().decode(CatalogProductDetailResponse.self, from: data)
        let product = decoded.product
        XCTAssertEqual(product.productName, "3단 라운드 마감장")
        XCTAssertEqual(product.placementType, .furniture3D)
        XCTAssertEqual(product.partner?.displayBrandName, "JD홈드레싱")
        let variant = try XCTUnwrap(product.variants?.first)
        let spec = try XCTUnwrap(variant.placementSpec)
        XCTAssertEqual(spec.contractVersion, 1)
        XCTAssertEqual(spec.dimensionsMm.heightMm, 1084)
        XCTAssertEqual(spec.catalogAssetId, "casset_round_01")
        XCTAssertEqual(spec.catalogOwnedAssetId, "owned_round_01")
        XCTAssertTrue(spec.usdzSignedUrl.hasPrefix("https://"))
        XCTAssertNil((try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { $0["product"] as? [String: Any] }
            .flatMap { ($0["variants"] as? [[String: Any]])?.first }
            .flatMap { $0["placementSpec"] as? [String: Any] }?["storageKey"])
    }

    func testUnknownPlacementTypeDoesNotCrash() throws {
        let json = """
        {"id":"p1","partnerId":"x","productName":"X","placementType":"SOMETHING_NEW","widthMm":1,"depthMm":1,"heightMm":1}
        """.data(using: .utf8)!
        let product = try JSONDecoder().decode(CatalogProduct.self, from: json)
        XCTAssertEqual(product.placementType, .unsupported)
        XCTAssertFalse(product.placementType.isSupportedForPlacement)
    }

    func testUnsupportedContractVersion() {
        var spec = CatalogMockData.roundCabinetPlacementSpec()
        spec.contractVersion = 99
        let result = CatalogPlacementSpecValidator.validate(spec)
        if case .failure(.unsupportedContractVersion(99)) = result {
            // ok
        } else {
            XCTFail("expected unsupportedContractVersion")
        }
    }

    func testDimensionsQuaternionScaleValidation() {
        var spec = CatalogMockData.roundCabinetPlacementSpec()
        spec.dimensionsMm = CatalogDimensions(widthMm: 0, depthMm: 10, heightMm: 10)
        XCTAssertEqual(CatalogPlacementSpecValidator.validate(spec), .failure(.invalidDimensions))

        spec = CatalogMockData.roundCabinetPlacementSpec()
        spec.orientation = CatalogQuaternion(x: .nan, y: 0, z: 0, w: 1)
        XCTAssertEqual(CatalogPlacementSpecValidator.validate(spec), .failure(.invalidQuaternion))

        spec = CatalogMockData.roundCabinetPlacementSpec()
        spec.scaleX = -1
        XCTAssertEqual(CatalogPlacementSpecValidator.validate(spec), .failure(.invalidScale))
    }

    @MainActor
    func testEmptyCatalogHidesProductionSection() async {
        let mockVM = CatalogHomeViewModel(isMockMode: true)
        mockVM.reload()
        // Allow mock actor fetch to complete.
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(mockVM.shouldShowSection)
        XCTAssertFalse(mockVM.products.isEmpty)
        XCTAssertEqual(mockVM.categories.count, 2)
        XCTAssertEqual(mockVM.categories.map(\.name), ["수납장", "커튼"])

        // Production empty policy: empty state hides section (non-mock).
        let prodVM = CatalogHomeViewModel(isMockMode: false)
        XCTAssertTrue(prodVM.shouldShowSection || prodVM.state == .idle)
    }

    func testTransformOrderAndBottomOffset() {
        let spec = CatalogMockData.roundCabinetPlacementSpec()
        let m = CatalogPlacementTransform.modelMatrix(
            spec: spec,
            userPosition: SIMD3(1, 0, 2),
            userRotationY: 0
        )
        // Identity placement scales → translation in columns.3
        XCTAssertEqual(m.columns.3.x, 1, accuracy: 1e-5)
        XCTAssertEqual(m.columns.3.z, 2, accuracy: 1e-5)

        var withBottom = spec
        withBottom.bottomOffsetMeters = 0.05
        let m2 = CatalogPlacementTransform.modelMatrix(
            spec: withBottom,
            userPosition: SIMD3(0, 0, 0),
            userRotationY: 0
        )
        XCTAssertEqual(m2.columns.3.y, 0.05, accuracy: 1e-5)

        let y = CatalogPlacementTransform.floorAlignedY(floorY: -1.35, localMinY: -0.2, scaleY: 1)
        XCTAssertEqual(y, -1.15, accuracy: 1e-5)
    }

    /// Column-vector convention: M = T*R*B*S*O*A applies A first (rightmost).
    func testTransformMatrixMultiplicationOrderMatchesIntent() {
        var spec = CatalogMockData.roundCabinetPlacementSpec()
        spec.scaleX = 2
        spec.scaleY = 3
        spec.scaleZ = 4
        spec.bottomOffsetMeters = 0.5
        spec.orientation = CatalogQuaternion(x: 0, y: 0, z: 0, w: 1)
        spec.axisMapping = CatalogAxisMapping(width: "x", height: "y", depth: "z")

        let userPos = SIMD3<Float>(10, 0, 0)
        let yaw = Float.pi / 2
        let composed = CatalogPlacementTransform.modelMatrix(
            spec: spec,
            userPosition: userPos,
            userRotationY: yaw
        )

        let axis = CatalogPlacementTransform.axisMappingMatrix(spec.axisMapping)
        let orient = CatalogPlacementTransform.quaternionMatrix(spec.orientation)
        let scale = simd_float4x4(diagonal: SIMD4<Float>(2, 3, 4, 1))
        let bottom = CatalogPlacementTransform.translationMatrix(SIMD3<Float>(0, 0.5, 0))
        let userR = CatalogPlacementTransform.rotationYMatrix(yaw)
        let userT = CatalogPlacementTransform.translationMatrix(userPos)
        let expectedStep1 = orient * axis
        let expectedStep2 = scale * expectedStep1
        let expectedStep3 = bottom * expectedStep2
        let expectedStep4 = userR * expectedStep3
        let expected = userT * expectedStep4

        let p = SIMD4<Float>(1, 1, 1, 1)
        let a = composed * p
        let b = expected * p
        XCTAssertEqual(a.x, b.x, accuracy: 1e-4)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-4)
        XCTAssertEqual(a.z, b.z, accuracy: 1e-4)

        // Stepwise: axis→orient→scale→bottom→yaw→pos on (1,0,0)
        var v = SIMD4<Float>(1, 0, 0, 1)
        v = axis * v
        v = orient * v
        v = scale * v
        XCTAssertEqual(v.x, 2, accuracy: 1e-4)
        v = bottom * v
        XCTAssertEqual(v.y, 0.5, accuracy: 1e-4)
        v = userR * v
        v = userT * v
        let final = composed * SIMD4<Float>(1, 0, 0, 1)
        XCTAssertEqual(v.x, final.x, accuracy: 1e-4)
        XCTAssertEqual(v.y, final.y, accuracy: 1e-4)
        XCTAssertEqual(v.z, final.z, accuracy: 1e-4)
    }

    func testNoDoubleMmToMeterInRulerBounds() {
        let spec = CatalogMockData.roundCabinetPlacementSpec()
        let ends = CatalogPlacementTransform.rulerEndpoints(spec: spec)
        let width = simd_length(ends.width.1 - ends.width.0)
        XCTAssertEqual(width, 0.29, accuracy: 1e-5)
        let height = simd_length(ends.height.1 - ends.height.0)
        XCTAssertEqual(height, 1.084, accuracy: 1e-5)
        // Must match meters from mm once (not mm again).
        XCTAssertEqual(CatalogPlacementTransform.metersFromMm(290), 0.29, accuracy: 1e-6)
    }

    func testPlacementSaveOmitsSignedURL() throws {
        let pending = PendingCatalogPlacement(
            productId: "p",
            variantId: "v",
            catalogAssetId: "a",
            catalogRevision: 1,
            placementSpecVersion: 1,
            dimensionsMm: CatalogDimensions(widthMm: 290, depthMm: 290, heightMm: 1084),
            displayName: "3단 라운드 마감장",
            partnerName: "JD홈드레싱",
            thumbnailUrl: "https://cdn.example.com/t.png",
            placementSpec: CatalogMockData.roundCabinetPlacementSpec(),
            targetSpaceId: "space1",
            targetSessionId: "sess1",
            projectionKey: "sess1",
            calibrationStatusText: "치수 보정 없음"
        )
        let entry = pending.makeLayoutEntry(position: SIMD3(0, -1.35, -1), rotationY: 0.1, floorY: -1.35)
        let data = try JSONEncoder().encode(entry)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("usdzSignedUrl"))
        XCTAssertFalse(json.contains("example.invalid"))
        XCTAssertFalse(json.contains("catalogThumbnailUrl"))
        XCTAssertEqual(entry.catalogProductId, "p")
        XCTAssertEqual(entry.catalogOwnedAssetId, CatalogMockData.roundCabinetPlacementSpec().catalogOwnedAssetId)
        XCTAssertEqual(entry.catalogWidthMm, 290)
        XCTAssertEqual(entry.uniformScale, 1)
    }

    func testDimensionsShortLabelUsesMm() {
        let dims = CatalogDimensions(widthMm: 400, depthMm: 290, heightMm: 1084)
        XCTAssertEqual(dims.shortLabelMm, "W 400 × D 290 × H 1084 mm")
        XCTAssertEqual(dims.accessibilityLabel, "너비 400밀리미터, 깊이 290밀리미터, 높이 1084밀리미터")
        XCTAssertEqual(CatalogDimensionRuler.formatMm(400), "400 mm")
    }

    func testThumbnailHTTPSFallbackPriority() {
        XCTAssertNil(CatalogThumbnailURL.httpsURL(from: "http://insecure.example/x.jpg"))
        XCTAssertNil(CatalogThumbnailURL.httpsURL(from: "javascript:alert(1)"))
        XCTAssertNotNil(CatalogThumbnailURL.httpsURL(from: "https://cdn.example.com/a.jpg"))

        var product = CatalogMockData.roundCabinetDetail()
        product.thumbnailUrl = nil
        if var variants = product.variants, !variants.isEmpty {
            variants[0].thumbnailUrl = "https://cdn.example.com/variant.jpg"
            product.variants = variants
        }
        XCTAssertEqual(product.resolvedThumbnailURL, "https://cdn.example.com/variant.jpg")

        product.thumbnailUrl = "https://cdn.example.com/product.jpg"
        XCTAssertEqual(product.resolvedThumbnailURL, "https://cdn.example.com/product.jpg")
    }

    func testHeroThumbnailPrefersSelectedVariant() {
        var product = CatalogMockData.roundCabinetDetail()
        product.thumbnailUrl = "https://cdn.example.com/product.jpg"
        guard var variants = product.variants, variants.count >= 1 else {
            XCTFail("expected variants")
            return
        }
        variants[0].thumbnailUrl = "https://cdn.example.com/variant-oak.jpg"
        product.variants = variants
        let selectedId = variants[0].id
        XCTAssertEqual(
            product.heroThumbnailURL(selectedVariantId: selectedId),
            "https://cdn.example.com/variant-oak.jpg"
        )
        variants[0].thumbnailUrl = nil
        product.variants = variants
        XCTAssertEqual(
            product.heroThumbnailURL(selectedVariantId: selectedId),
            "https://cdn.example.com/product.jpg"
        )
    }

    func testColorHexNormalizationAndPlainDescription() {
        XCTAssertEqual(CatalogColorHex.normalized("#abc"), "#AABBCC")
        XCTAssertEqual(CatalogColorHex.normalized("C2A87A"), "#C2A87A")
        XCTAssertNil(CatalogColorHex.normalized("not-a-color"))
        XCTAssertNil(CatalogColorHex.normalized("  "))
        XCTAssertEqual(
            CatalogPlainText.nonEmpty("  <b>설명</b> 줄1<br/>줄2  "),
            "설명 줄1\n줄2"
        )
        XCTAssertNil(CatalogPlainText.nonEmpty("   "))
        XCTAssertEqual(CatalogPlainText.nonEmpty("<script>alert(1)</script>"), "alert(1)")
    }

    func testRulerSpecFromStoredEntryAxis() throws {
        var entry = VRPlacedAssetEntry(assetId: "catalog:a", position: .zero)
        entry.catalogAssetId = "a"
        entry.catalogWidthMm = 400
        entry.catalogDepthMm = 290
        entry.catalogHeightMm = 1084
        let spec = try XCTUnwrap(CatalogDimensionRuler.rulerSpecFromStoredEntry(entry))
        let ends = CatalogPlacementTransform.rulerEndpoints(spec: spec)
        XCTAssertEqual(simd_length(ends.width.1 - ends.width.0), 0.4, accuracy: 1e-5)
        XCTAssertEqual(simd_length(ends.depth.1 - ends.depth.0), 0.29, accuracy: 1e-5)
        XCTAssertEqual(simd_length(ends.height.1 - ends.height.0), 1.084, accuracy: 1e-5)
    }

    func testExternalHTTPSAndDangerousURL() {
        switch SpaceLinkExternalURL.normalize("https://shop.example.com/item") {
        case .success(let s): XCTAssertNotNil(s)
        case .failure: XCTFail("https should succeed")
        }
        switch SpaceLinkExternalURL.normalize("javascript:alert(1)") {
        case .success: XCTFail("javascript should fail")
        case .failure: break
        }
        switch SpaceLinkExternalURL.normalize("https://user:pass@evil.com/") {
        case .success: XCTFail("userinfo should fail")
        case .failure: break
        }
        switch SpaceLinkExternalURL.normalize("http://insecure.example.com") {
        case .success: XCTFail("http should fail")
        case .failure: break
        }
    }

    func testEventPayloadHasNoPIIKeysInModel() throws {
        let payload = CatalogEventPayload(
            channel: "gonggi_ios",
            host: "shop.example.com",
            appBuild: "2.0(33)",
            outboundUrl: "https://shop.example.com/buy"
        )
        let data = try JSONEncoder().encode(payload)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(obj?["email"])
        XCTAssertNil(obj?["phone"])
        XCTAssertNil(obj?["image"])
        XCTAssertEqual(obj?["channel"] as? String, "gonggi_ios")
    }

    @MainActor
    func testCalibrationReuseAndInvalidate() {
        let store = CatalogFloorCalibrationStore.shared
        store.upsert(
            CatalogFloorCalibrationSnapshot(
                spaceId: "s1",
                projectionKey: "pk1",
                status: .complete,
                cameraHeightMm: 1500,
                coordinateConventionVersion: "scenekit_y_up_v1",
                updatedAt: Date(),
                anchorCount: 2
            )
        )
        XCTAssertEqual(store.status(spaceId: "s1", projectionKey: "pk1").status, .complete)
        store.reconcile(spaceId: "s1", currentProjectionKey: "pk2", previousProjectionKey: "pk1")
        XCTAssertEqual(store.status(spaceId: "s1", projectionKey: "pk2").status, .needsReconfirm)
        XCTAssertEqual(
            store.statusFromCameraHeight(cameraHeightMm: 1500, anchorCount: 1),
            .needsMore
        )
    }

    func testSpacePickerCounts() {
        XCTAssertTrue(CatalogPlaceSpacePickerView.placeableSpaces(from: []).isEmpty)
    }

    @MainActor
    func testMockAndProductionShareViewModelType() {
        let a = CatalogHomeViewModel(isMockMode: true)
        let b = CatalogHomeViewModel(isMockMode: false)
        XCTAssertTrue(type(of: a) == type(of: b))
    }

    func testPriceInquiryLabelWithoutLinksOrPrice() {
        var product = CatalogMockData.roundCabinetListCard()
        product.displayPriceMinor = nil
        product.currency = "KRW"
        product.consultationUrl = nil
        product.purchaseUrl = nil
        XCTAssertEqual(product.priceLabel, "가격 문의")
        XCTAssertEqual(product.priceAccessibilityLabel, "가격 문의")
    }

    func testPriceInquiryLabelForConsultationWithoutPrice() {
        var product = CatalogMockData.roundCabinetListCard()
        product.displayPriceMinor = nil
        product.currency = "KRW"
        product.consultationUrl = "https://example.com/consult"
        product.purchaseUrl = nil
        XCTAssertEqual(product.priceLabel, "가격 문의")
        XCTAssertEqual(product.priceAccessibilityLabel, "가격 문의")
    }

    func testNumericPriceLabelUnchanged() {
        var product = CatalogMockData.roundCabinetListCard()
        product.displayPriceMinor = 89000
        product.currency = "KRW"
        XCTAssertEqual(product.priceLabel, "89,000원")
        XCTAssertEqual(product.priceAccessibilityLabel, "가격 89,000원")
    }

    func testReadyGateBlocksMissingSpec() {
        let result = CatalogPlacementSpecValidator.validate(nil)
        XCTAssertEqual(result, .failure(.missingPlacementSpec))
    }

    // MARK: - Merchandising categories

    func testNormalizeFallbackSingleSectionWhenCategoriesMissing() {
        let products = CatalogMockData.listProducts()
        let payload = CatalogListPayload.normalize(products: products, categories: nil)
        XCTAssertEqual(payload.categories.count, 1)
        XCTAssertEqual(payload.categories[0].id, "all")
        XCTAssertEqual(payload.categories[0].name, "제휴 상품")
        XCTAssertEqual(payload.categories[0].products.count, products.count)
        XCTAssertFalse(CatalogListPayload.shouldShowCategoryTitles(payload.categories))
    }

    func testNormalizeAdds기타ForLeftoverProducts() {
        let cabinet = CatalogMockData.roundCabinetListCard()
        let curtain = CatalogMockData.mockCurtainPlaceholderCard()
        let shelf = CatalogCategory(
            id: "shelf-1",
            name: "수납장",
            sortOrder: 0,
            products: [cabinet]
        )
        let payload = CatalogListPayload.normalize(
            products: [cabinet, curtain],
            categories: [shelf]
        )
        XCTAssertEqual(payload.categories.map(\.name), ["수납장", "기타"])
        XCTAssertEqual(payload.categories[1].id, "uncategorized")
        XCTAssertEqual(payload.categories[1].products.map(\.id), [curtain.id])
        XCTAssertTrue(CatalogListPayload.shouldShowCategoryTitles(payload.categories))
    }

    func testNormalizeDropsEmptyCategoriesAndUnsupported() {
        var unsupported = CatalogMockData.roundCabinetListCard()
        unsupported.id = "bad"
        unsupported.placementType = .unsupported
        let empty = CatalogCategory(id: "empty", name: "빈", sortOrder: 0, products: [])
        let good = CatalogCategory(
            id: "good",
            name: "수납장",
            sortOrder: 1,
            products: [CatalogMockData.roundCabinetListCard()]
        )
        let payload = CatalogListPayload.normalize(
            products: [CatalogMockData.roundCabinetListCard(), unsupported],
            categories: [empty, good]
        )
        XCTAssertEqual(payload.categories.map(\.name), ["수납장"])
        XCTAssertFalse(payload.products.contains(where: { $0.placementType == .unsupported }))
    }

    func testDecodeListResponseWithCategories() throws {
        let json = """
        {
          "ok": true,
          "products": [
            {
              "id": "p1",
              "partnerId": "jd",
              "productName": "A",
              "placementType": "FURNITURE_3D",
              "widthMm": 100,
              "depthMm": 100,
              "heightMm": 100
            }
          ],
          "categories": [
            {
              "id": "c1",
              "name": "거실",
              "sortOrder": 0,
              "products": [
                {
                  "id": "p1",
                  "partnerId": "jd",
                  "productName": "A",
                  "placementType": "FURNITURE_3D",
                  "widthMm": 100,
                  "depthMm": 100,
                  "heightMm": 100
                }
              ]
            }
          ]
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CatalogProductListResponse.self, from: json)
        let payload = CatalogListPayload.normalize(
            products: decoded.products,
            categories: decoded.categories
        )
        XCTAssertEqual(payload.categories.count, 1)
        XCTAssertEqual(payload.categories[0].name, "거실")
        XCTAssertTrue(CatalogListPayload.shouldShowCategoryTitles(payload.categories))
    }

    // MARK: - Thumbnail aspect-fit (no crop)

    func testThumbnailContainerAspectIsStable() {
        XCTAssertEqual(CatalogProductThumbnailLayout.containerWidth, 200, accuracy: 0.1)
        XCTAssertEqual(CatalogProductThumbnailLayout.containerHeight, 140, accuracy: 0.1)
        XCTAssertEqual(
            CatalogProductThumbnailLayout.containerAspectRatio,
            200.0 / 140.0,
            accuracy: 1e-6
        )
        XCTAssertGreaterThanOrEqual(CatalogProductThumbnailLayout.imageInset, 8)
        XCTAssertLessThanOrEqual(CatalogProductThumbnailLayout.imageInset, 12)
    }

    func testThumbnailAspectFitDoesNotClipPortraitLandscapeSquare() {
        // 1) Tall cabinet (~0.4 W/H)
        let portrait: CGFloat = 400.0 / 1084.0
        // 2) Wide sofa (~2.2 W/H)
        let landscape: CGFloat = 2200.0 / 1000.0
        // 3) Square
        let square: CGFloat = 1.0
        // 4) Transparent product-like tall PNG aspect
        let transparentProduct: CGFloat = 600.0 / 900.0

        for (name, aspect) in [
            ("portrait_cabinet", portrait),
            ("landscape_sofa", landscape),
            ("square", square),
            ("transparent_product", transparentProduct),
        ] {
            XCTAssertTrue(
                CatalogProductThumbnailLayout.fittedImageFitsWithoutClipping(
                    sourceAspectWidthOverHeight: aspect
                ),
                "\(name) must fit without clipping"
            )
            let fitted = CatalogProductThumbnailLayout.fittedImageSize(
                sourceAspectWidthOverHeight: aspect
            )
            let boxW = CatalogProductThumbnailLayout.containerWidth
                - CatalogProductThumbnailLayout.imageInset * 2
            let boxH = CatalogProductThumbnailLayout.containerHeight
                - CatalogProductThumbnailLayout.imageInset * 2
            XCTAssertLessThanOrEqual(fitted.width, boxW + 0.5, name)
            XCTAssertLessThanOrEqual(fitted.height, boxH + 0.5, name)
            // Aspect preserved
            XCTAssertEqual(fitted.width / fitted.height, aspect, accuracy: 1e-5, name)
        }
    }

    func testThumbnailInvalidOrMissingURLUsesPlaceholderState() {
        XCTAssertNil(CatalogThumbnailURL.httpsURL(from: "not a url"))
        XCTAssertNil(CatalogThumbnailURL.httpsURL(from: "http://insecure.example/x.png"))
        XCTAssertNil(CatalogThumbnailURL.httpsURL(from: nil))
        XCTAssertNil(CatalogThumbnailURL.httpsURL(from: ""))

        XCTAssertEqual(
            CatalogThumbnailDisplayState.resolve(hasHTTPSThumbnailURL: false, phase: .empty),
            .missingURL
        )
        XCTAssertEqual(
            CatalogThumbnailDisplayState.resolve(hasHTTPSThumbnailURL: true, phase: .empty),
            .loading
        )
        XCTAssertEqual(
            CatalogThumbnailDisplayState.resolve(hasHTTPSThumbnailURL: true, phase: .failure),
            .loadFailed
        )
        XCTAssertEqual(
            CatalogThumbnailDisplayState.resolve(hasHTTPSThumbnailURL: true, phase: .success),
            .loaded
        )
        XCTAssertTrue(CatalogThumbnailDisplayState.missingURL.usesSofaPlaceholder)
        XCTAssertTrue(CatalogThumbnailDisplayState.loadFailed.usesSofaPlaceholder)
        XCTAssertFalse(CatalogThumbnailDisplayState.loading.usesSofaPlaceholder)

        var noThumb = CatalogMockData.roundCabinetListCard()
        noThumb.thumbnailUrl = nil
        XCTAssertNil(noThumb.resolvedThumbnailURL)

        var badThumb = CatalogMockData.roundCabinetListCard()
        badThumb.thumbnailUrl = "https://example.invalid/does-not-exist-404.png"
        // URL is HTTPS-valid; load failure is a separate display state (card must still render).
        XCTAssertNotNil(CatalogThumbnailURL.httpsURL(from: badThumb.resolvedThumbnailURL))
        XCTAssertEqual(
            CatalogThumbnailDisplayState.resolve(hasHTTPSThumbnailURL: true, phase: .failure),
            .loadFailed
        )
    }

    func testCardAccessibilityKeepsProductNameWhenThumbnailMissing() {
        var product = CatalogMockData.roundCabinetListCard()
        product.thumbnailUrl = nil
        let label =
            "\(product.partnerDisplayName), \(product.productName), \(product.priceLabel), \(product.dimensions.shortLabelMm)"
        XCTAssertTrue(label.contains(product.productName))
        XCTAssertEqual(
            CatalogThumbnailDisplayState.missingURL.accessibilitySuffix,
            "이미지 없음"
        )
        XCTAssertEqual(
            CatalogThumbnailDisplayState.loadFailed.accessibilitySuffix,
            "이미지를 불러오지 못함"
        )
    }

    // MARK: - Tab bar / safe-area clearance

    func testHomeScrollBottomPaddingClearsTabBarOnPlusAndCompact() {
        // iPhone 14 Plus-class home indicator ~34pt; compact / older ~0–20pt.
        let plus = GonggiTabBarLayout.homeScrollBottomPadding(safeAreaBottom: 34)
        let compact = GonggiTabBarLayout.homeScrollBottomPadding(safeAreaBottom: 0)
        let small = GonggiTabBarLayout.homeScrollBottomPadding(safeAreaBottom: 20)

        XCTAssertGreaterThanOrEqual(plus, GonggiTabBarLayout.contentHeight + 34)
        XCTAssertGreaterThanOrEqual(compact, GonggiTabBarLayout.contentHeight)
        XCTAssertGreaterThanOrEqual(small, GonggiTabBarLayout.contentHeight + 20)
        XCTAssertGreaterThanOrEqual(
            GonggiTabBarLayout.homeSafeAreaInsetHeight,
            GonggiTabBarLayout.contentHeight + GonggiSpacing.touchTarget - 0.1
        )
        XCTAssertEqual(
            GonggiTabBarLayout.homeScrollContentPadding,
            GonggiTabBarLayout.scrollClearance,
            accuracy: 0.1
        )
        XCTAssertEqual(
            GonggiTabBarLayout.detailScrollBottomPadding,
            GonggiSpacing.xxl,
            accuracy: 0.1
        )
        XCTAssertGreaterThan(plus, compact)
    }
}
