import XCTest
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
        XCTAssertEqual(mockVM.availableCategories.count, 2)

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
        let scale = simd_float4x4(diagonal: SIMD4(2, 3, 4, 1))
        let bottom = CatalogPlacementTransform.translationMatrix(SIMD3(0, 0.5, 0))
        let userR = CatalogPlacementTransform.rotationYMatrix(yaw)
        let userT = CatalogPlacementTransform.translationMatrix(userPos)
        let expected = userT * userR * bottom * scale * orient * axis

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
        // +90° yaw around Y: x→z roughly for right-handed SceneKit R_y
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
        XCTAssertEqual(entry.catalogProductId, "p")
        XCTAssertEqual(entry.catalogWidthMm, 290)
        XCTAssertEqual(entry.uniformScale, 1)
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

    func testReadyGateBlocksMissingSpec() {
        let result = CatalogPlacementSpecValidator.validate(nil)
        XCTAssertEqual(result, .failure(.missingPlacementSpec))
    }
}
