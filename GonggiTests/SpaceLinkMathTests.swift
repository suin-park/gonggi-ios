import XCTest
@testable import Gonggi

final class SpaceLinkMathTests: XCTestCase {
    func testWorldPositionFrontIsNegativeZ() {
        let p = SpaceLinkMath.worldPosition(yawDeg: 0, pitchDeg: 0, radius: 3)
        XCTAssertEqual(p.x, 0, accuracy: 0.05)
        XCTAssertEqual(p.y, 0, accuracy: 0.05)
        XCTAssertLessThan(p.z, -2.5)
    }

    func testWorldPositionRightIsPositiveXArea() {
        let p = SpaceLinkMath.worldPosition(yawDeg: 90, pitchDeg: 0, radius: 3)
        XCTAssertGreaterThan(p.x, 2.0)
    }

    func testClampRadius() {
        XCTAssertEqual(SpaceLink.clampRadius(0.1), SpaceLink.minRadius)
        XCTAssertEqual(SpaceLink.clampRadius(99), SpaceLink.maxRadius)
        XCTAssertEqual(SpaceLink.clampRadius(3), 3, accuracy: 0.001)
    }

    func testDraftDefaults() {
        let d = SpaceLink.makeDraft(sourceSpaceId: "s1", yawDeg: 10, pitchDeg: 5)
        XCTAssertEqual(d.status, .draft)
        XCTAssertNil(d.targetSpaceId)
        XCTAssertFalse(d.isNavigable)
        XCTAssertTrue(d.id.hasPrefix("draft-"))
    }

    func testMaxLinksCap() {
        XCTAssertEqual(SpaceLink.maxLinksPerSource, 8)
    }

    func testDTOMapsToLinkedNavigable() {
        let dto = SpaceLinkDTO(
            id: "l1",
            sourceSpaceId: "s1",
            targetSpaceId: "t1",
            yawDeg: 12,
            pitchDeg: -3,
            radius: 3,
            label: nil,
            status: "linked",
            targetEntryYawDeg: nil,
            createdAt: "2026-09-08T00:00:00.000Z",
            updatedAt: "2026-09-08T00:00:00.000Z",
            targetSessionId: "sess-t",
            targetResultImageURL: "https://example.com/x.jpg",
            targetStatus: "completed"
        )
        let m = dto.toModel()
        XCTAssertEqual(m.status, .linked)
        XCTAssertTrue(m.isNavigable)
        XCTAssertEqual(m.targetSessionId, "sess-t")
    }

    func testPendingCaptureRoundTrip() throws {
        let pending = PendingSpaceLinkCapture(
            sourceSpaceId: "src",
            draftHotspotId: "draft-1",
            yawDeg: 1,
            pitchDeg: 2,
            radius: 3,
            label: "주방",
            targetSessionId: "tgt",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(pending)
        let decoded = try JSONDecoder().decode(PendingSpaceLinkCapture.self, from: data)
        XCTAssertEqual(decoded, pending)
    }

    func testCategoryBitIsDistinct() {
        XCTAssertEqual(VRPlacedAssetCategory.spaceLink, 1 << 6)
        XCTAssertEqual(
            VRPlacedAssetCategory.spaceLink & VRPlacedAssetCategory.asset,
            0
        )
        XCTAssertEqual(
            VRPlacedAssetCategory.spaceLink & VRPlacedAssetCategory.panorama,
            0
        )
    }

    func testHitProxyLargerThanVisualTargets() {
        XCTAssertGreaterThan(
            SpaceHotspotNodeFactory.hitTargetPoints,
            SpaceHotspotNodeFactory.visualTargetPoints
        )
    }

    /// Build 74: center ray → store yaw/pitch → world → screen UV ≈ center
    /// (spawn path: SceneKit camera presentation → VRFloorRay → equirect → insideOutSpherePoint).
    func testSpawnCenterRoundTripWithinFifteenPoints() {
        let cases: [(yaw: Float, pitch: Float)] = [
            (0, 0),
            (90, 0),
            (180, 0),
            (-90, 0),
            (0, 30),
            (0, -30),
            (45, 15),
            (-120, -20)
        ]
        let aspect = Float(390.0 / 844.0)
        for look in cases {
            let stored = SpaceLinkMath.equirectDegreesFromCameraCenterRay(
                cameraYawDeg: look.yaw,
                cameraPitchDeg: look.pitch
            )
            let uv = SpaceLinkMath.screenUV(
                yawDeg: stored.yawDeg,
                pitchDeg: stored.pitchDeg,
                cameraYawDeg: look.yaw,
                cameraPitchDeg: look.pitch,
                verticalFOVDegrees: 70,
                aspect: aspect
            )
            XCTAssertNotNil(uv, "behind camera for look=\(look) stored=\(stored)")
            guard let uv else { continue }
            let dxPt = abs(uv.x - 0.5) * 390
            let dyPt = abs(uv.y - 0.5) * 844
            let err = sqrt(dxPt * dxPt + dyPt * dyPt)
            XCTAssertLessThanOrEqual(
                err,
                15,
                "screen error \(err)pt look=\(look) stored=\(stored) uv=\(uv)"
            )
        }
    }

    func testWorldDirectionInverseMatchesInsideOutPoint() {
        let samples: [(Float, Float)] = [
            (0, 0), (90, 0), (-90, 10), (180, -20), (45, 30)
        ]
        for (yaw, pitch) in samples {
            let p = SpaceLinkMath.worldPosition(yawDeg: yaw, pitchDeg: pitch, radius: 3)
            let back = SpaceLinkMath.equirectDegreesFromWorldDirection(p)
            let dyaw = abs(VRSphereEquirectBridge.shortestDeltaDeg(from: back.yawDeg, to: yaw))
            XCTAssertLessThan(dyaw, 0.5, "yaw mismatch for (\(yaw),\(pitch)) → \(back)")
            XCTAssertEqual(back.pitchDeg, pitch, accuracy: 0.5)
        }
    }

    func testOverlayFlipsNearTopEdge() {
        let origin = SpaceLinkOverlayLayout.panelOrigin(
            marker: CGPoint(x: 200, y: 80),
            panelSize: CGSize(width: 180, height: 160),
            container: CGSize(width: 390, height: 844)
        )
        // Near top: panel should not go above safe margin.
        XCTAssertGreaterThan(origin.y, 40)
    }
}
