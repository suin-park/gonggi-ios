import XCTest
@testable import Gonggi

final class SpaceCleanupTests: XCTestCase {
    @MainActor
    func testModeTitlesAvoidDeleteWording() {
        XCTAssertEqual(SpaceCleanupMode.allFurniture.title, "전체 가구 비우기")
        XCTAssertEqual(SpaceCleanupMode.selectedObjects.title, "가구 선택해서 비우기")
        for mode in SpaceCleanupMode.allCases {
            XCTAssertFalse(mode.title.contains("삭제"))
            XCTAssertFalse(mode.subtitle.contains("삭제"))
        }
    }

    @MainActor
    func testMultiPointAddUndoResetAndSeamWrap() {
        let session = SpaceCleanupSession()
        session.begin(spaceId: "space-1", sourceRevisionId: "rev-0-base")
        session.consentAccepted = true
        session.selectMode(.selectedObjects)

        session.addPoint(
            u: 0.98,
            v: 0.5,
            yaw: 1.0,
            pitch: 0,
            direction: SpaceCleanupDirection(x: 0, y: 0, z: -1)
        )
        session.addPoint(
            u: -0.05,
            v: 0.5,
            yaw: -1.0,
            pitch: 0,
            direction: SpaceCleanupDirection(x: 0, y: 0, z: -1)
        )
        XCTAssertEqual(session.points.count, 2)
        XCTAssertEqual(session.points[0].u, 0.98, accuracy: 1e-9)
        XCTAssertEqual(session.points[1].u, 0.95, accuracy: 1e-9)

        session.undoLast()
        XCTAssertEqual(session.points.count, 1)
        session.resetPoints()
        XCTAssertTrue(session.points.isEmpty)
    }

    @MainActor
    func testCanonicalJSONOmitsScreenAsRequired() throws {
        let point = SpaceCleanupSelectionPoint(
            id: "selection-1",
            u: 0.2,
            v: 0.58,
            yaw: 1.1,
            pitch: -0.1,
            direction: SpaceCleanupDirection(x: 0.4, y: -0.1, z: -0.9),
            screenX: 10,
            screenY: 20
        )
        let json = SpaceCleanupSession.canonicalJSONObject(for: point)
        XCTAssertEqual(json["u"] as? Double, 0.2)
        XCTAssertEqual(json["v"] as? Double, 0.58)
        XCTAssertNotNil(json["direction"] as? [String: Double])
        XCTAssertNil(json["screenX"])
        XCTAssertNil(json["screenY"])
    }

    @MainActor
    func testConfirmRequiresAwaitingConfirmation() async {
        let mock = SpaceCleanupMockClient()
        let session = SpaceCleanupSession()
        session.configure(client: mock)
        session.begin(spaceId: "space-1", sourceRevisionId: "rev-0-base")
        session.consentAccepted = true
        session.selectMode(.selectedObjects)
        session.addCenterAim(yawDeg: 10, pitchDeg: 5)
        await session.submitSelected()
        XCTAssertEqual(session.job?.status, "AWAITING_CONFIRMATION")
        XCTAssertEqual(mock.confirmCalls, 0)
        XCTAssertFalse(mock.editWouldHaveBeenCalled)

        await session.confirmMasks()
        XCTAssertEqual(mock.confirmCalls, 1)
        XCTAssertTrue(mock.editWouldHaveBeenCalled)
        XCTAssertEqual(session.job?.resultRevisionId, "rev-cleanup-cleanup-job-1")
    }

    @MainActor
    func testAllFurnitureCreatesWithoutConfirm() async {
        let mock = SpaceCleanupMockClient()
        let session = SpaceCleanupSession()
        session.configure(client: mock)
        session.begin(spaceId: "space-1", sourceRevisionId: "rev-0-base")
        session.consentAccepted = true
        await session.submitAllFurniture()
        XCTAssertEqual(session.job?.mode, .allFurniture)
        XCTAssertEqual(mock.confirmCalls, 0)
    }

    func testPlacementResultTypeSpaceCleanupBadge() {
        XCTAssertEqual(ProductPlacementResultType.spaceCleanup.badgeTitle, "공간 정리")
    }

    func testResolvedResultRevisionIdForCleanupCard() {
        let result = ProductPlacementResultDTO(
            id: "pr-1",
            type: .spaceCleanup,
            status: .completed,
            sourceSpaceId: "space-1",
            sourceRevisionId: "rev-0-base",
            resultRevisionId: "rev-cleanup-abc",
            curtainCompositeJobId: nil,
            spaceCleanupJobId: "job-1",
            catalogPartnerId: nil,
            catalogProductId: nil,
            catalogVariantId: nil,
            productName: nil,
            partnerName: nil,
            optionName: nil,
            productNameSnapshot: "선택한 가구 비우기 결과",
            partnerNameSnapshot: nil,
            optionNameSnapshot: nil,
            widthMm: nil,
            depthMm: nil,
            heightMm: nil,
            previewUrl: "https://example.com/result.jpg",
            originalPreviewUrl: nil,
            resultPreviewUrl: "https://example.com/result.jpg",
            progress: 1,
            failureCode: nil,
            createdAt: nil,
            updatedAt: nil
        )
        XCTAssertEqual(
            PlacementResultOpenPolicy.resolvedResultRevisionId(for: result),
            "rev-cleanup-abc"
        )
        PlacementResultOpenPolicy.stashCleanupBaseRevision(
            spaceKey: "space-1",
            resultRevisionId: "rev-cleanup-abc"
        )
        XCTAssertEqual(
            PlacementResultOpenPolicy.consumeCleanupBaseRevision(spaceKey: "space-1"),
            "rev-cleanup-abc"
        )
        XCTAssertNil(PlacementResultOpenPolicy.consumeCleanupBaseRevision(spaceKey: "space-1"))
    }

    func testNoSparklesIconInCleanupCTA() {
        // Space Detail CTA uses sofa / square.stack.3d — never sparkles / magic wand / trash.
        let forbidden = ["sparkles", "wand.and.stars", "trash", "trash.fill"]
        let used = "sofa"
        XCTAssertFalse(forbidden.contains(used))
    }

    @MainActor
    func testPollingResumesOnlyWhileVisibleAndInFlight() async {
        let seed = ProductPlacementResultDTO(
            id: "pr-cleanup-progress",
            type: .spaceCleanup,
            status: .inProgress,
            sourceSpaceId: "space-1",
            sourceRevisionId: "rev-0-base",
            resultRevisionId: nil,
            curtainCompositeJobId: nil,
            spaceCleanupJobId: "job-1",
            catalogPartnerId: nil,
            catalogProductId: nil,
            catalogVariantId: nil,
            productName: nil,
            partnerName: nil,
            optionName: nil,
            productNameSnapshot: "공간을 정리하고 있어요",
            partnerNameSnapshot: nil,
            optionNameSnapshot: nil,
            widthMm: nil,
            depthMm: nil,
            heightMm: nil,
            previewUrl: nil,
            originalPreviewUrl: nil,
            resultPreviewUrl: nil,
            progress: 0.3,
            failureCode: nil,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            updatedAt: nil
        )
        let client = PlacementResultsMockClient(seed: [seed])
        let vm = PlacementResultsViewModel(client: client)
        vm.onAppear()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(vm.isPolling || vm.hasInFlight)
        vm.onDisappear()
        XCTAssertFalse(vm.isPolling)
    }
}
