import XCTest
@testable import Gonggi

final class AssetLibraryPhase2Tests: XCTestCase {
    func testPlacementUnavailableReasons() {
        XCTAssertNil(
            MobileAssetDTO(
                id: "1",
                name: "A",
                usdzStatus: "READY",
                usdzUrl: "https://example.com/a.usdz",
                availableForPlacement: true
            ).placementUnavailableReason
        )
        XCTAssertEqual(
            MobileAssetDTO(id: "1", name: "A", usdzStatus: "PROCESSING").placementUnavailableReason,
            "AR/공간 배치를 준비하는 중"
        )
        XCTAssertEqual(
            MobileAssetDTO(id: "1", name: "A", usdzStatus: "FAILED").placementUnavailableReason,
            nil
        )
        XCTAssertEqual(
            MobileAssetDTO(id: "1", name: "A", usdzStatus: "NONE").placementUnavailableReason,
            "AR 준비가 필요해요"
        )
    }

    func testPendingMatchesJobAndSessionIds() {
        let spaces = [
            SpaceRecord(
                id: "job-1",
                name: "Home",
                capturedAt: Date(),
                status: .ready,
                thumbnailSystemImage: "house",
                sessionId: "session-1"
            )
        ]
        let pending = PendingAssetPlacement(
            assetId: "asset-1",
            targetSpaceId: "job-1",
            targetSessionId: "session-1",
            source: .assetDetail
        )
        XCTAssertTrue(pending.matches(viewerSessionId: "job-1", spaces: spaces))
        XCTAssertTrue(pending.matches(viewerSessionId: "session-1", spaces: spaces))
        XCTAssertFalse(pending.matches(viewerSessionId: "other", spaces: spaces))
    }

    func testMaxAssetsAppendPolicy() {
        var layout = VRPlacementLayout()
        for i in 0..<VRPlacementLayout.maxAssets {
            let ok = layout.append(
                VRPlacedAssetEntry(
                    assetId: "a-\(i)",
                    position: .zero,
                    uniformScale: 1,
                    sortIndex: i
                )
            )
            XCTAssertTrue(ok)
        }
        let blocked = layout.append(
            VRPlacedAssetEntry(
                assetId: "overflow",
                position: .zero,
                uniformScale: 1,
                sortIndex: 8
            )
        )
        XCTAssertFalse(blocked)
        XCTAssertEqual(layout.assets.count, VRPlacementLayout.maxAssets)
    }

    func testDuplicateAssetIdsAllowedAsInstances() {
        var layout = VRPlacementLayout()
        XCTAssertTrue(
            layout.append(
                VRPlacedAssetEntry(assetId: "chair", position: .zero, uniformScale: 1, sortIndex: 0)
            )
        )
        XCTAssertTrue(
            layout.append(
                VRPlacedAssetEntry(assetId: "chair", position: SIMD3(1, 0, 0), uniformScale: 1, sortIndex: 1)
            )
        )
        XCTAssertEqual(layout.assets.count, 2)
        XCTAssertEqual(Set(layout.assets.map(\.assetId)).count, 1)
        XCTAssertEqual(Set(layout.assets.map(\.id)).count, 2)
    }

    func testSpaceViewerSessionStartInEditMode() {
        let url = URL(fileURLWithPath: "/tmp/p.jpg")
        let session = SpaceViewerSession(id: "s1", fileURL: url, startInEditMode: true)
        XCTAssertTrue(session.startInEditMode)
        let plain = SpaceViewerSession(id: "s1", fileURL: url)
        XCTAssertFalse(plain.startInEditMode)
    }

    func testPlaceableSpaceFilterUsesCanOpenExistingVR() {
        let ready = SpaceRecord(
            id: "r",
            name: "Ready",
            capturedAt: Date(),
            status: .ready,
            thumbnailSystemImage: "cube",
            localLatLongPath: "/tmp/x.jpg",
            remoteImageURL: "https://example.com/x.jpg"
        )
        let generating = SpaceRecord(
            id: "g",
            name: "Gen",
            capturedAt: Date(),
            status: .processing,
            thumbnailSystemImage: "sparkles"
        )
        XCTAssertTrue(ready.canOpenExistingVR)
        XCTAssertFalse(generating.canOpenExistingVR)
    }
}
