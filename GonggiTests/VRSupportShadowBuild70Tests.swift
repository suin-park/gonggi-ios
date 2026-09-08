import XCTest
@testable import Gonggi

final class VRSupportShadowBuild70Tests: XCTestCase {
    func testA_OldPlacementWithoutSupportYFallsBackToFloorY() throws {
        let json = #"{"id":"p","assetId":"a","position":{"x":0,"y":-1.35,"z":-2}}"#
        let entry = try JSONDecoder().decode(VRPlacedAssetEntry.self, from: Data(json.utf8))
        XCTAssertNil(entry.supportY)
        XCTAssertNil(entry.supportMode)
        XCTAssertEqual(
            entry.resolvedSupportY(floorY: VRPlacementLayout.defaultFloorY),
            VRPlacementLayout.defaultFloorY,
            accuracy: 0.0001
        )
    }

    func testB_FloorModeUsesLayoutFloorY() {
        var entry = VRPlacedAssetEntry(assetId: "a", position: .zero, supportMode: .custom, supportY: -0.2)
        entry.applyFloorSupport(floorY: -1.35)
        XCTAssertEqual(entry.supportMode, .floor)
        XCTAssertEqual(entry.resolvedSupportY(floorY: -1.35), -1.35, accuracy: 0.0001)
        XCTAssertEqual(entry.position.y, -1.35, accuracy: 0.0001)
    }

    func testC_CustomHeightMovesAssetAndImpliedShadowTogether() {
        var entry = VRPlacedAssetEntry(assetId: "a", position: SIMD3(1, -1.35, -2))
        entry.applyCustomHeightOffset(0.9, floorY: -1.35)
        XCTAssertEqual(entry.supportMode, .custom)
        XCTAssertEqual(entry.supportY!, -0.45, accuracy: 0.0001)
        XCTAssertEqual(entry.position.y, entry.supportY!, accuracy: 0.0001)
        // Contact is local child at +0.002 under root — same support height by construction.
        let shadowWorldY = entry.resolvedSupportY(floorY: -1.35) + 0.002
        XCTAssertEqual(shadowWorldY, -0.448, accuracy: 0.0001)
    }

    func testD_DirectionalOffContactOpacity() {
        XCTAssertEqual(VRLightingExperimentPrefs.contactOpacityDirectionalInactive, 0.28, accuracy: 0.001)
    }

    func testE_DirectionalOnContactOpacity() {
        XCTAssertEqual(VRLightingExperimentPrefs.contactOpacityDirectionalActive, 0.12, accuracy: 0.001)
    }

    func testF_LowConfidenceStillHasVisibleContactPolicy() {
        // Eligible requires conf >= 0.65 — below that directional off → inactive opacity.
        XCTAssertGreaterThan(VRLightingExperimentPrefs.contactOpacityDirectionalInactive, 0.18)
        XCTAssertFalse(0.40 >= VRDominantLightEstimator.confidenceThreshold)
    }

    func testG_MultipleAssetsIndependentSupportY() {
        var a = VRPlacedAssetEntry(assetId: "vase", position: .zero)
        var b = VRPlacedAssetEntry(assetId: "chair", position: .zero)
        a.applyCustomHeightOffset(0.8, floorY: -1.35)
        b.applyFloorSupport(floorY: -1.35)
        XCTAssertEqual(a.resolvedSupportY(floorY: -1.35), -0.55, accuracy: 0.0001)
        XCTAssertEqual(b.resolvedSupportY(floorY: -1.35), -1.35, accuracy: 0.0001)
    }

    func testH_SupportFieldsEncodeAndDecodeRoundTrip() throws {
        var entry = VRPlacedAssetEntry(assetId: "a", position: SIMD3(0, -0.42, -1))
        entry.applyCustomHeightOffset(0.93, floorY: -1.35)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(VRPlacedAssetEntry.self, from: data)
        XCTAssertEqual(decoded.supportMode, .custom)
        XCTAssertEqual(decoded.supportY!, entry.supportY!, accuracy: 0.0001)
        XCTAssertEqual(decoded.resolvedSupportY(floorY: -1.35), entry.supportY!, accuracy: 0.0001)
    }

    func testI_HeightOffsetClamped() {
        var entry = VRPlacedAssetEntry(assetId: "a", position: .zero)
        entry.applyCustomHeightOffset(9, floorY: -1.35)
        XCTAssertEqual(
            entry.heightOffset(floorY: -1.35),
            VRPlacementLayout.maxSupportHeightOffset,
            accuracy: 0.0001
        )
    }

    func testJ_LayoutDecodeIgnoresUnknownSupportGracefully() throws {
        let json = """
        {"assets":[{"id":"p","assetId":"a","position":{"x":0,"y":0,"z":0},"supportMode":"custom","supportY":-0.5}]}
        """
        let layout = try JSONDecoder().decode(VRPlacementLayout.self, from: Data(json.utf8))
        XCTAssertEqual(layout.assets.first?.supportMode, .custom)
        XCTAssertEqual(layout.assets.first!.supportY!, -0.5, accuracy: 0.0001)
    }
}
