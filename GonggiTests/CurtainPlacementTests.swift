import XCTest
@testable import Gonggi

final class CurtainPlacementTests: XCTestCase {
    func testCurtain2DPlacementTypeSupported() {
        XCTAssertTrue(CatalogPlacementType.curtain2D.isSupportedForPlacement)
        XCTAssertTrue(CatalogPlacementType.furniture3D.isSupportedForPlacement)
        XCTAssertFalse(CatalogPlacementType.unsupported.isSupportedForPlacement)
    }

    func testDecodeCurtainProductFixture() throws {
        let json = """
        {
          "id": "curtain-1",
          "partnerId": "jd-homedressing",
          "productName": "린넨 커튼",
          "placementType": "CURTAIN_2D",
          "category": "CURTAIN",
          "widthMm": 2000,
          "depthMm": 50,
          "heightMm": 2400,
          "availableForPlacement": true
        }
        """.data(using: .utf8)!
        let product = try JSONDecoder().decode(CatalogProduct.self, from: json)
        XCTAssertEqual(product.placementType, .curtain2D)
        XCTAssertEqual(product.category, .curtain)
        XCTAssertTrue(product.placementType.isSupportedForPlacement)
        XCTAssertTrue(
            CatalogCurtainPlacementValidator.canPlace(
                product: product,
                variant: CatalogVariant(
                    id: "v1",
                    sourceVariantKey: nil,
                    name: "기본",
                    hexCode: nil,
                    widthMm: 2000,
                    depthMm: 50,
                    heightMm: 2400,
                    thumbnailUrl: nil,
                    usdzUrl: nil,
                    usdzSignedUrlExpiresAt: nil,
                    catalogAssetId: "asset-2d",
                    catalogOwnedAssetId: nil,
                    placementSpec: nil,
                    availableForPlacement: true
                )
            )
        )
    }

    func testConsentGateRequiresFlagOnCreate() async {
        let client = MobileCurtainPlacementAPIClient()
        let seed = CurtainPlacementSeedPayload(
            seedContractVersion: 1,
            spaceId: "space-1",
            baseRevisionId: "rev-0-base",
            latLongWidth: 3840,
            latLongHeight: 1920,
            u: 0.5,
            v: 0.5,
            yawDeg: 0,
            pitchDeg: 0,
            direction: CurtainPlacementDirection(x: 0, y: 0, z: -1),
            screen: nil,
            pixel: nil,
            capturedAt: ISO8601DateFormatter().string(from: Date())
        )
        let request = CurtainPlacementCreateRequest(
            aiConsentAccepted: false,
            catalogProductId: "p1",
            catalogVariantId: "v1",
            productRevision: "r1",
            catalog2DAssetId: "a1",
            seed: seed
        )
        do {
            _ = try await client.createJob(request: request, idempotencyKey: nil)
            XCTFail("expected consentRequired")
        } catch CurtainPlacementAPIError.consentRequired {
            // ok
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMockClientAcceptsConsent() async throws {
        let client = CurtainPlacementMockClient()
        let capture = CurtainSeedMath.captureFromEquirectTap(
            yawDeg: 10,
            pitchDeg: 5,
            tapPoint: CGPoint(x: 100, y: 200),
            viewSize: CGSize(width: 390, height: 844),
            latLongWidth: 3840,
            latLongHeight: 1920,
            spaceId: "space-1",
            baseRevisionId: "rev-0-base"
        )
        let job = try await client.createJob(
            request: CurtainPlacementCreateRequest(
                aiConsentAccepted: true,
                catalogProductId: "p1",
                catalogVariantId: "v1",
                productRevision: "r1",
                catalog2DAssetId: "a1",
                seed: capture.seed
            ),
            idempotencyKey: "test-key"
        )
        XCTAssertEqual(job.status, "DETECTING_WINDOW")
    }

    func testSeedMathRoundTripAndWarnings() {
        let (yaw, pitch) = VRSphereEquirectBridge.equirectDegreesFromTextureUV(u: 0.02, v: 0.5)
        let capture = CurtainSeedMath.captureFromEquirectTap(
            yawDeg: yaw,
            pitchDeg: pitch,
            tapPoint: nil,
            viewSize: CGSize(width: 100, height: 100),
            latLongWidth: 3840,
            latLongHeight: 1920,
            spaceId: "s",
            baseRevisionId: "rev-0-base"
        )
        XCTAssertTrue(capture.clientWarnings.contains(.nearSeam))
        let back = VRSphereEquirectBridge.equirectDegreesFromTextureUV(
            u: Float(capture.seed.u),
            v: Float(capture.seed.v)
        )
        XCTAssertEqual(back.yawDeg, yaw, accuracy: 0.01)
        XCTAssertEqual(back.pitchDeg, pitch, accuracy: 0.01)

        let poleCapture = CurtainSeedMath.captureFromEquirectTap(
            yawDeg: 0,
            pitchDeg: 80,
            tapPoint: nil,
            viewSize: CGSize(width: 100, height: 100),
            latLongWidth: 3840,
            latLongHeight: 1920,
            spaceId: "s",
            baseRevisionId: "rev-0-base"
        )
        XCTAssertTrue(poleCapture.clientWarnings.contains(.nearPole))
    }

    func testIdempotencyKeyStable() {
        let seed = CurtainPlacementSeedPayload(
            seedContractVersion: 1,
            spaceId: "space-1",
            baseRevisionId: "rev-0-base",
            latLongWidth: nil,
            latLongHeight: nil,
            u: 0.5,
            v: 0.4,
            yawDeg: 0,
            pitchDeg: 0,
            direction: CurtainPlacementDirection(x: 0, y: 0, z: -1),
            screen: nil,
            pixel: nil,
            capturedAt: "t"
        )
        let a = CurtainPlacementSession.idempotencyKey(
            spaceId: "space-1",
            baseRevisionId: "rev-0-base",
            productId: "p1",
            variantId: "v1",
            seed: seed
        )
        let b = CurtainPlacementSession.idempotencyKey(
            spaceId: "space-1",
            baseRevisionId: "rev-0-base",
            productId: "p1",
            variantId: "v1",
            seed: seed
        )
        XCTAssertEqual(a, b)
    }
}
