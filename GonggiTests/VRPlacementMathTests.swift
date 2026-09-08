import CoreGraphics
import SceneKit
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

    func testO_APIEnvelopeDecodeKeepsAssets_NotEmptyWipe() throws {
        let json = """
        {
          "ok": true,
          "spaceId": "s1",
          "sessionId": "sess",
          "layout": {
            "version": 1,
            "frame": "gonggi.vr.v1",
            "floorY": -1.35,
            "assets": [
              {
                "id": "p1",
                "assetId": "a1",
                "position": {"x": 0, "y": -1.35, "z": -2},
                "rotationY": 0.5,
                "uniformScale": 1.2,
                "sortIndex": 0
              }
            ]
          }
        }
        """
        // Wrong order (bare layout first) would yield assets=[] — regression lock.
        let wiped = try JSONDecoder().decode(VRPlacementLayout.self, from: Data(json.utf8))
        XCTAssertTrue(wiped.assets.isEmpty, "bare decode of API wrapper must not be used")

        let layout = try VRPlacementLayoutCoding.decodeResponse(Data(json.utf8))
        XCTAssertEqual(layout.assets.count, 1)
        XCTAssertEqual(layout.assets[0].id, "p1")
        XCTAssertEqual(layout.assets[0].uniformScale, 1.2, accuracy: 0.001)
    }

    func testP_FloorMissReturnsNilWithoutFallbackJump() {
        let miss = VRFloorRay.intersectFloorIfValid(
            ray: VRWorldRay(origin: SIMD3(0, 0, 0), direction: SIMD3(0, 0, -1)),
            floorY: -1.35
        )
        XCTAssertNil(miss)

        let hit = VRFloorRay.intersectFloorIfValid(
            ray: VRWorldRay(
                origin: SIMD3(0, 0, 0),
                direction: simd_normalize(SIMD3(0, -1, -1))
            ),
            floorY: -1
        )
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.y, -1, accuracy: 0.001)
    }

    func testQ_GrabOffsetPreservesRelativeFingerOffset() {
        let floorHit = SIMD3<Float>(1, -1.35, -2)
        let nodePos = SIMD3<Float>(1.4, -1.35, -2.3)
        let grab = SIMD2(nodePos.x - floorHit.x, nodePos.z - floorHit.z)
        let nextHit = SIMD3<Float>(2, -1.35, -3)
        let applied = SIMD3(nextHit.x + grab.x, -1.35, nextHit.z + grab.y)
        XCTAssertEqual(applied.x, 2.4, accuracy: 0.001)
        XCTAssertEqual(applied.z, -3.3, accuracy: 0.001)
    }

    func testR_LerpAngleUsesShortestPathAcrossWrap() {
        let from: Float = 3.0
        let to: Float = -3.0
        let delta = VRGestureMath.shortestAngleDelta(from: from, to: to)
        XCTAssertLessThan(abs(delta), Float.pi)
        XCTAssertGreaterThan(delta, 0)

        let arrived = VRGestureMath.lerpAngle(from, to, alpha: 1)
        XCTAssertLessThan(
            abs(VRGestureMath.shortestAngleDelta(from: arrived, to: to)),
            0.001
        )

        // 350° → 10° should pass near 0°, not spin the long way.
        let a = 350 * Float.pi / 180
        let b = 10 * Float.pi / 180
        let mid = VRGestureMath.lerpAngle(a, b, alpha: 0.5)
        XCTAssertLessThan(abs(mid), 0.35)
    }

    func testS_OwnerAssetMoveDoesNotEqualCameraPan() {
        let move = EditOneFingerOwner.assetMove(placementId: "p1")
        XCTAssertNotEqual(move, .cameraPan)
        XCTAssertNotEqual(move, .none)
        if case .assetMove(let id) = move {
            XCTAssertEqual(id, "p1")
        } else {
            XCTFail("expected assetMove")
        }
    }

    func testT_MinimumHitExtentGrowsWithDistance() {
        let near = VRGestureMath.minimumHitExtentMeters(
            distance: 1.0,
            viewportHeight: 800,
            targetPoints: 52
        )
        let far = VRGestureMath.minimumHitExtentMeters(
            distance: 3.0,
            viewportHeight: 800,
            targetPoints: 52
        )
        XCTAssertGreaterThan(far, near)
        XCTAssertEqual(
            VRGestureMath.expandExtent(0.05, minimum: near),
            near,
            accuracy: 0.0001
        )
    }

    func testU_PinchLerpMovesTowardTargetWithoutOvershootOnAlphaOne() {
        XCTAssertEqual(VRGestureMath.lerp(1, 2, alpha: 1), 2, accuracy: 0.0001)
        XCTAssertEqual(VRGestureMath.lerp(1, 2, alpha: 0), 1, accuracy: 0.0001)
        let mid = VRGestureMath.lerp(1, 2, alpha: 0.35)
        XCTAssertEqual(mid, 1.35, accuracy: 0.0001)
    }

    func testV_VisualBoundsCenterAndSize() {
        let bounds = AssetVisualBounds(min: SIMD3(-1, 0, -2), max: SIMD3(1, 4, 2))
        XCTAssertEqual(bounds.center, SIMD3(0, 2, 0))
        XCTAssertEqual(bounds.size, SIMD3(2, 4, 4))
    }

    func testW_SelectionCreateOnceDoesNotRecreate() {
        #if DEBUG
        VRSelectionPerfCounters.reset()
        #endif
        let root = SCNNode()
        root.name = "placedAsset:test"
        let content = SCNNode(geometry: SCNBox(width: 0.4, height: 0.8, length: 0.4, chamferRadius: 0))
        content.categoryBitMask = VRPlacedAssetCategory.asset
        content.position.y = 0.4
        root.addChildNode(content)
        VRPlacedAssetNodeFactory.setVisualBounds(
            AssetVisualBounds(min: SIMD3(-0.2, 0, -0.2), max: SIMD3(0.2, 0.8, 0.2)),
            on: root
        )

        let first = VRPlacedAssetNodeFactory.ensureSelectionVisual(on: root, visible: true)
        let second = VRPlacedAssetNodeFactory.ensureSelectionVisual(on: root, visible: true)
        XCTAssertTrue(first === second)
        #if DEBUG
        XCTAssertEqual(VRSelectionPerfCounters.selectionGeometryCreates, 1)
        #endif

        VRPlacedAssetNodeFactory.setSelectionVisible(on: root, visible: false)
        XCTAssertTrue(first.isHidden)
        VRPlacedAssetNodeFactory.setSelectionVisible(on: root, visible: true)
        XCTAssertFalse(first.isHidden)
        #if DEBUG
        XCTAssertEqual(VRSelectionPerfCounters.selectionGeometryCreates, 1)
        #endif
    }

    func testX_ProxyRefreshUsesCachedBoundsWithoutSelectionInflation() {
        let root = SCNNode()
        let content = SCNNode(geometry: SCNBox(width: 0.2, height: 0.2, length: 0.2, chamferRadius: 0))
        content.categoryBitMask = VRPlacedAssetCategory.asset
        root.addChildNode(content)
        let meshBounds = AssetVisualBounds(min: SIMD3(-0.1, 0, -0.1), max: SIMD3(0.1, 0.2, 0.1))
        VRPlacedAssetNodeFactory.setVisualBounds(meshBounds, on: root)
        VRPlacedAssetNodeFactory.attachHitProxy(
            on: root,
            bounds: meshBounds,
            minimumExtent: 0.4,
            enabled: true
        )
        // Selection must use mesh bounds, not proxy-enlarged root.boundingBox.
        let visual = VRPlacedAssetNodeFactory.ensureSelectionVisual(on: root, visible: true)
        let wire = visual.childNodes.first { $0.geometry is SCNBox }
        let box = try XCTUnwrap(wire?.geometry as? SCNBox)
        XCTAssertEqual(Float(box.width), 0.2, accuracy: 0.001)
        XCTAssertEqual(Float(box.height), 0.2, accuracy: 0.001)
    }
}
