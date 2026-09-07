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
