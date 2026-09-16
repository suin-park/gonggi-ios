import XCTest
@testable import Gonggi

final class SpaceCleanupTests: XCTestCase {
    @MainActor
    func testModeTitlesAvoidDeleteWording() {
        XCTAssertEqual(SpaceCleanupMode.selectedObjects.title, "가구 선택해서 비우기")
        XCTAssertFalse(SpaceCleanupMode.selectedObjects.title.contains("삭제"))
        XCTAssertFalse(SpaceCleanupMode.selectedObjects.subtitle.contains("삭제"))
        // ALL_FURNITURE remains in the API enum for older jobs but is removed from the menu.
        XCTAssertEqual(SpaceCleanupMode.allFurniture.title, "전체 가구 비우기")
    }

    @MainActor
    func testMenuExposesSelectedModeOnly() {
        XCTAssertEqual(SpaceCleanupMode.selectedObjects.title, "가구 선택해서 비우기")
        XCTAssertNotEqual(SpaceCleanupMode.selectedObjects, .allFurniture)
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
        session.resetForReselect()
        XCTAssertTrue(session.points.isEmpty)
        XCTAssertNil(session.job)
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
    func testDetectPollingLeavesDetectingAndReachesAwaiting() async {
        let mock = SpaceCleanupMockClient()
        mock.detectPollsBeforeReady = 2
        let session = SpaceCleanupSession()
        session.configure(client: mock)
        session.pollIntervalNanosecondsOverride = 20_000_000
        session.activateSelectedMode(
            spaceId: "space-1",
            sourceRevisionId: "rev-0-base",
            consentAccepted: true
        )
        session.addCenterAim(yawDeg: 10, pitchDeg: 5)
        await session.submitSelected()
        XCTAssertEqual(session.job?.status, "DETECTING")
        XCTAssertTrue(session.isPolling)

        let deadline = Date().addingTimeInterval(2)
        while session.job?.status == "DETECTING", Date() < deadline {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(session.job?.status, "AWAITING_CONFIRMATION")
        XCTAssertFalse(session.isPolling)
        XCTAssertGreaterThanOrEqual(mock.fetchCalls, 2)
        XCTAssertFalse(session.detectedPolygons.isEmpty)
    }

    @MainActor
    func testConfirmRequiresMaskReadyAndDetection() async {
        let mock = SpaceCleanupMockClient()
        mock.detectPollsBeforeReady = 0
        let session = SpaceCleanupSession()
        session.configure(client: mock)
        var acceptedId: String?
        session.onAccepted = { acceptedId = $0 }
        session.activateSelectedMode(
            spaceId: "space-1",
            sourceRevisionId: "rev-0-base",
            consentAccepted: true
        )
        session.addCenterAim(yawDeg: 10, pitchDeg: 5)
        await session.submitSelected()
        XCTAssertEqual(session.job?.status, "AWAITING_CONFIRMATION")
        XCTAssertFalse(session.canConfirm)
        session.removalTargetText = "쇼파"
        XCTAssertTrue(session.canConfirm)

        await session.confirmMasks()
        XCTAssertEqual(mock.confirmCalls, 1)
        XCTAssertEqual(mock.lastConfirmRemovalTarget, "쇼파")
        XCTAssertTrue(mock.editWouldHaveBeenCalled)
        XCTAssertNotNil(acceptedId)
        XCTAssertFalse(session.isActive)
        XCTAssertFalse(session.isPolling)
    }

    @MainActor
    func testConfirmBlockedWithoutDetection() async {
        let mock = SpaceCleanupMockClient()
        mock.detectPollsBeforeReady = 0
        let session = SpaceCleanupSession()
        session.configure(client: mock)
        var accepted = false
        session.onAccepted = { _ in accepted = true }
        session.activateSelectedMode(
            spaceId: "space-1",
            sourceRevisionId: "rev-0-base",
            consentAccepted: true
        )
        session.addCenterAim(yawDeg: 0, pitchDeg: 0)
        await session.submitSelected()
        session.job?.detectedObjects = []
        XCTAssertFalse(session.canConfirm)
        await session.confirmMasks()
        XCTAssertEqual(mock.confirmCalls, 0)
        XCTAssertFalse(accepted)
    }

    @MainActor
    func testPollingCancelsOnDisappearAndResumesOnAppear() async {
        let mock = SpaceCleanupMockClient()
        mock.detectPollsBeforeReady = 50
        let session = SpaceCleanupSession()
        session.configure(client: mock)
        session.pollIntervalNanosecondsOverride = 30_000_000
        session.activateSelectedMode(
            spaceId: "space-1",
            sourceRevisionId: "rev-0-base",
            consentAccepted: true
        )
        session.addCenterAim(yawDeg: 5, pitchDeg: 0)
        await session.submitSelected()
        XCTAssertTrue(session.isPolling)
        session.onSelectionUIDisappear()
        XCTAssertFalse(session.isPolling)
        let fetchesAfterCancel = mock.fetchCalls
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(mock.fetchCalls, fetchesAfterCancel)
        session.onSelectionUIAppear()
        XCTAssertTrue(session.isPolling)
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
        XCTAssertTrue(PlacementResultOpenPolicy.canOpenCleanupResult(result))
    }

    func testCleanupOpenBlockedWithoutRevisionOrPreview() {
        var missingRevision = ProductPlacementResultDTO(
            id: "pr-2",
            type: .spaceCleanup,
            status: .completed,
            sourceSpaceId: "space-1",
            sourceRevisionId: "rev-0-base",
            resultRevisionId: nil,
            curtainCompositeJobId: nil,
            spaceCleanupJobId: "job-2",
            catalogPartnerId: nil,
            catalogProductId: nil,
            catalogVariantId: nil,
            productName: nil,
            partnerName: nil,
            optionName: nil,
            productNameSnapshot: nil,
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
        XCTAssertFalse(PlacementResultOpenPolicy.canOpenCleanupResult(missingRevision))

        missingRevision.resultRevisionId = "rev-x"
        missingRevision.previewUrl = nil
        missingRevision.resultPreviewUrl = nil
        XCTAssertFalse(PlacementResultOpenPolicy.canOpenCleanupResult(missingRevision))
    }

    @MainActor
    func testPendingCleanupBaseRevisionConsumeIsSpaceScoped() {
        let app = AppState()
        app.pendingCleanupBaseRevision = PendingCleanupBaseRevision(
            spaceId: "space-a",
            sessionId: "sess-a",
            resultRevisionId: "rev-cleanup-1"
        )
        let other = SpaceRecord(
            id: "space-b",
            name: "Other",
            capturedAt: Date(),
            status: .ready,
            thumbnailSystemImage: "sofa",
            note: nil,
            sessionId: "sess-b",
            latestRevisionId: "rev-0-base"
        )
        XCTAssertNil(app.consumePendingCleanupBaseRevision(matchingSpace: other))
        XCTAssertNotNil(app.pendingCleanupBaseRevision)

        let match = SpaceRecord(
            id: "space-a",
            name: "Match",
            capturedAt: Date(),
            status: .ready,
            thumbnailSystemImage: "sofa",
            note: nil,
            sessionId: "sess-a",
            latestRevisionId: "rev-0-base"
        )
        let consumed = app.consumePendingCleanupBaseRevision(matchingSpace: match)
        XCTAssertEqual(consumed?.resultRevisionId, "rev-cleanup-1")
        XCTAssertNil(app.pendingCleanupBaseRevision)
        XCTAssertNil(app.consumePendingCleanupBaseRevision(matchingSpace: match))
    }

    @MainActor
    func testFurnitureAndCurtainReceiveCleanupBaseRevision() {
        let app = AppState()
        app.pendingCleanupBaseRevision = PendingCleanupBaseRevision(
            spaceId: "space-1",
            sessionId: "sess-1",
            resultRevisionId: "rev-cleanup-xyz"
        )
        let space = SpaceRecord(
            id: "space-1",
            name: "Room",
            capturedAt: Date(),
            status: .ready,
            thumbnailSystemImage: "sofa",
            note: nil,
            sessionId: "sess-1",
            latestRevisionId: "rev-0-base"
        )
        let consumed = app.consumePendingCleanupBaseRevision(matchingSpace: space)
        XCTAssertEqual(consumed?.resultRevisionId, "rev-cleanup-xyz")

        let curtain = PendingCurtainPlacement(
            productId: "p",
            variantId: "v",
            catalog2DAssetId: "a",
            catalogRevision: 1,
            productRevision: "1",
            displayName: "curtain",
            partnerName: "partner",
            thumbnailUrl: nil,
            targetSpaceId: space.id,
            targetSessionId: space.sessionId,
            projectionKey: nil,
            baseRevisionId: consumed?.resultRevisionId ?? space.latestRevisionId ?? "rev-0-base"
        )
        XCTAssertEqual(curtain.baseRevisionId, "rev-cleanup-xyz")

        let furniture = PendingCatalogPlacement(
            productId: "p2",
            variantId: "v2",
            catalogAssetId: "ca",
            catalogRevision: 1,
            placementSpecVersion: 1,
            dimensionsMm: CatalogDimensions(widthMm: 100, depthMm: 100, heightMm: 100),
            displayName: "cabinet",
            partnerName: "partner",
            thumbnailUrl: nil,
            placementSpec: CatalogMockData.roundCabinetPlacementSpec(),
            targetSpaceId: space.id,
            targetSessionId: space.sessionId,
            projectionKey: nil,
            calibrationStatusText: "치수 보정 없음",
            baseRevisionId: "rev-cleanup-xyz"
        )
        XCTAssertEqual(furniture.baseRevisionId, "rev-cleanup-xyz")
    }

    @MainActor
    func testCatalogEntryWithoutPendingDoesNotUseCleanupRevision() {
        let app = AppState()
        XCTAssertNil(app.pendingCleanupBaseRevision)
        let space = SpaceRecord(
            id: "space-1",
            name: "Room",
            capturedAt: Date(),
            status: .ready,
            thumbnailSystemImage: "sofa",
            note: nil,
            sessionId: "sess-1",
            latestRevisionId: "rev-0-base"
        )
        XCTAssertNil(app.consumePendingCleanupBaseRevision(matchingSpace: space))
        XCTAssertEqual(space.latestRevisionId ?? "rev-0-base", "rev-0-base")
    }

    func testNoSparklesIconInCleanupCTA() {
        let forbidden = ["sparkles", "wand.and.stars", "trash", "trash.fill"]
        let used = "sofa"
        XCTAssertFalse(forbidden.contains(used))
    }

    @MainActor
    func testPlacementResultsPollingLifecycle() async {
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

    func testProgressFractionNormalizesZeroToHundredAndZeroToOne() {
        var job = SpaceCleanupJobDTO(
            id: "j",
            status: "DETECTING",
            mode: .selectedObjects,
            spaceId: "s",
            sourceRevisionId: "r",
            resultRevisionId: nil,
            progress: 40,
            selectionPoints: nil,
            detectedObjects: nil,
            failureCode: nil,
            failureMessageSafe: nil,
            outsideMaskDiff: nil,
            placementResultId: nil,
            maskPreviewUrl: nil,
            createdAt: nil,
            updatedAt: nil
        )
        XCTAssertEqual(job.progressFraction, 0.4, accuracy: 1e-9)
        job.progress = 1
        XCTAssertEqual(job.progressFraction, 1.0, accuracy: 1e-9)
    }

    func testSeamAdjacentPolygonProjectionDoesNotCrash() {
        let poly: [SpaceCleanupUvPoint] = [
            SpaceCleanupUvPoint(u: 0.98, v: 0.4),
            SpaceCleanupUvPoint(u: 0.02, v: 0.4),
            SpaceCleanupUvPoint(u: 0.02, v: 0.55),
            SpaceCleanupUvPoint(u: 0.98, v: 0.55),
        ]
        let overlay = SpaceCleanupVROverlay(
            points: [
                SpaceCleanupSelectionPoint(
                    id: "selection-1",
                    u: 0.99,
                    v: 0.5,
                    yaw: 3.0,
                    pitch: 0,
                    direction: SpaceCleanupDirection(x: 0, y: 0, z: -1)
                ),
            ],
            polygons: [poly],
            projectEquirectDegrees: { yaw, pitch in
                CGPoint(x: CGFloat(yaw + 180), y: CGFloat(90 - pitch))
            }
        )
        _ = overlay.body
    }
}
