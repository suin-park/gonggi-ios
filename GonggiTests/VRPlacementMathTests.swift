import CoreGraphics
import XCTest
import simd
@testable import Gonggi

final class VRPlacementMathTests: XCTestCase {
    func testA_CenterScreenRayIntersectsFloor() {
        let angle: Float = -.pi / 4
        let c = cos(angle)
        let s = sin(angle)
        var camera = simd_float4x4(
            SIMD4(1, 0, 0, 0),
            SIMD4(0, c, s, 0),
            SIMD4(0, -s, c, 0),
            SIMD4(0, 1, 0, 1)
        )
        camera.columns.3 = SIMD4(0, 1, 0, 1)

        let point = VRFloorRay.floorPoint(
            screenPoint: CGPoint(x: 100, y: 200),
            viewportSize: CGSize(width: 200, height: 400),
            cameraTransform: camera,
            floorY: -1
        )

        XCTAssertEqual(point.x, 0, accuracy: 0.001)
        XCTAssertEqual(point.y, -1, accuracy: 0.001)
        XCTAssertEqual(point.z, -2, accuracy: 0.01)
    }

    func testB_FloorIntersectionClampsNearAndFarDistance() {
        let near = VRFloorRay.intersectFloor(
            ray: VRWorldRay(
                origin: SIMD3(0, 0, 0),
                direction: simd_normalize(SIMD3(0, -10, -1))
            ),
            floorY: -1
        )
        let far = VRFloorRay.intersectFloor(
            ray: VRWorldRay(
                origin: SIMD3(0, 0, 0),
                direction: simd_normalize(SIMD3(0, -0.01, -1))
            ),
            floorY: -1
        )

        XCTAssertEqual(abs(near.z), VRFloorRay.minimumDistance, accuracy: 0.001)
        XCTAssertEqual(abs(far.z), VRFloorRay.maximumDistance, accuracy: 0.001)
    }

    func testC_ParallelRayFallsBackForwardTwoMeters() {
        let point = VRFloorRay.intersectFloor(
            ray: VRWorldRay(origin: SIMD3(1, 0, 2), direction: SIMD3(0, 0, -1)),
            floorY: VRPlacementLayout.defaultFloorY
        )

        XCTAssertEqual(point, SIMD3(1, VRPlacementLayout.defaultFloorY, 0))
    }

    func testD_LayoutEnforcesMaximumEightAssets() {
        let entries = (0..<10).map {
            VRPlacedAssetEntry(
                id: "placed-\($0)",
                assetId: "asset-\($0)",
                position: .zero,
                sortIndex: $0
            )
        }
        var layout = VRPlacementLayout(assets: entries)

        XCTAssertEqual(layout.assets.count, VRPlacementLayout.maxAssets)
        XCTAssertFalse(
            layout.append(
                VRPlacedAssetEntry(assetId: "asset-extra", position: .zero)
            )
        )
    }

    func testE_UniformScaleClampsToSupportedRange() {
        var entry = VRPlacedAssetEntry(
            assetId: "asset-1",
            position: .zero,
            uniformScale: 0.01
        )
        XCTAssertEqual(entry.uniformScale, VRPlacedAssetEntry.minimumScale)

        entry.setUniformScale(20)
        XCTAssertEqual(entry.uniformScale, VRPlacedAssetEntry.maximumScale)

        entry.setUniformScale(1.25)
        XCTAssertEqual(entry.uniformScale, 1.25)
    }

    func testF_ZeroViewportProducesFiniteForwardRay() {
        let ray = VRFloorRay.ray(
            screenPoint: .zero,
            viewportSize: .zero,
            cameraTransform: matrix_identity_float4x4
        )
        XCTAssertEqual(ray.origin, .zero)
        XCTAssertEqual(ray.direction, SIMD3(0, 0, -1))
    }

    func testG_UpwardRayUsesHorizontalFallback() {
        let point = VRFloorRay.intersectFloor(
            ray: VRWorldRay(origin: SIMD3(2, 1, 3), direction: simd_normalize(SIMD3(1, 1, 0))),
            floorY: -1
        )
        XCTAssertEqual(point, SIMD3(4, -1, 3))
    }

    func testH_FarDiagonalIntersectionClampsRadially() {
        let point = VRFloorRay.intersectFloor(
            ray: VRWorldRay(
                origin: .zero,
                direction: simd_normalize(SIMD3(1, -0.01, -1))
            ),
            floorY: -1
        )
        XCTAssertEqual(simd_length(SIMD2(point.x, point.z)), VRFloorRay.maximumDistance, accuracy: 0.001)
    }

    func testI_AppendAllowsEighthEntry() {
        var layout = VRPlacementLayout(assets: (0..<7).map {
            VRPlacedAssetEntry(assetId: "\($0)", position: .zero)
        })
        XCTAssertTrue(layout.append(VRPlacedAssetEntry(assetId: "eighth", position: .zero)))
        XCTAssertEqual(layout.assets.count, 8)
    }

    func testJ_MissingPlacementAvailabilityDecodesFalse() throws {
        let data = Data(#"{"id":"a","name":"의자"}"#.utf8)
        let asset = try JSONDecoder().decode(MobileAssetDTO.self, from: data)
        XCTAssertFalse(asset.availableForPlacement)
    }

    func testK_ArrayPositionDecodesForBackwardCompatibility() throws {
        let json = #"{"id":"p","assetId":"a","position":[1,2,3]}"#
        let entry = try JSONDecoder().decode(VRPlacedAssetEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.position, SIMD3(1, 2, 3))
    }

    func testL_EntryEncodesPositionAsNamedComponents() throws {
        let entry = VRPlacedAssetEntry(assetId: "a", position: SIMD3(1, 2, 3))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any]
        )
        let position = try XCTUnwrap(object["position"] as? [String: Any])
        XCTAssertEqual(position["x"] as? Double, 1)
        XCTAssertEqual(position["y"] as? Double, 2)
        XCTAssertEqual(position["z"] as? Double, 3)
    }

    func testM_DecodedLayoutDefaultsVersionFrameAndFloor() throws {
        let layout = try JSONDecoder().decode(
            VRPlacementLayout.self,
            from: Data(#"{"assets":[]}"#.utf8)
        )
        XCTAssertEqual(layout.version, VRPlacementLayout.currentVersion)
        XCTAssertEqual(layout.frame, VRPlacementLayout.coordinateFrame)
        XCTAssertEqual(layout.floorY, VRPlacementLayout.defaultFloorY)
    }

    func testN_LayoutDecodeClampsEntryScale() throws {
        let json = """
        {"assets":[{"id":"p","assetId":"a","position":{"x":0,"y":0,"z":0},"uniformScale":99}]}
        """
        let layout = try JSONDecoder().decode(VRPlacementLayout.self, from: Data(json.utf8))
        XCTAssertEqual(layout.assets.first?.uniformScale, VRPlacedAssetEntry.maximumScale)
    }
}
