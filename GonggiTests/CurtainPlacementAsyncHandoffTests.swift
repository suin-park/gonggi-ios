import XCTest
@testable import Gonggi

@MainActor
final class CurtainPlacementAsyncHandoffTests: XCTestCase {
    private final class RecordingClient: CurtainPlacementServing, @unchecked Sendable {
        var createResult: Result<CurtainPlacementJob, Error> = .success(
            CurtainPlacementJob(
                id: "job-1",
                status: "QUEUED",
                detectionId: nil,
                windowPolygon: nil,
                windowMaskAssetId: nil,
                confidence: nil,
                needsConfirmation: nil,
                warnings: nil,
                compositeImageUrl: nil,
                originalImageUrl: nil,
                revisionId: nil,
                userFacingSummaryKo: nil,
                errorCode: nil,
                placementResultId: "pr-1"
            )
        )
        var fetchCount = 0

        func createJob(request: CurtainPlacementCreateRequest, idempotencyKey: String?) async throws -> CurtainPlacementJob {
            try createResult.get()
        }

        func fetchJob(id: String) async throws -> CurtainPlacementJob {
            fetchCount += 1
            return try createResult.get()
        }

        func confirmWindow(jobId: String) async throws -> CurtainPlacementJob {
            try createResult.get()
        }

        func reselectWindow(jobId: String, seedU: Double, seedV: Double) async throws -> CurtainPlacementJob {
            try createResult.get()
        }

        func composite(jobId: String) async throws -> CurtainPlacementJob {
            try createResult.get()
        }
    }

    func testAcceptNavigatesWithoutDetectPolling() async {
        let client = RecordingClient()
        let session = CurtainPlacementSession()
        session.configure(client: client)

        var acceptedId: String?
        session.onPlacementAccepted = { acceptedId = $0 }

        let pending = PendingCurtainPlacement(
            productId: "p1",
            variantId: "v1",
            catalog2DAssetId: "a1",
            catalogRevision: 1,
            productRevision: "r1",
            displayName: "커튼",
            partnerName: "파트너",
            thumbnailUrl: nil,
            targetSpaceId: "space-1",
            targetSessionId: "space-1",
            projectionKey: nil,
            baseRevisionId: "rev-0-base"
        )
        session.start(with: pending, sessionId: "space-1")
        session.handleSeedTap(
            yawDeg: 10,
            pitchDeg: 5,
            tapPoint: CGPoint(x: 100, y: 200),
            viewSize: CGSize(width: 390, height: 844)
        )

        session.acceptConsentAndCreateJob()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if case .accepted = session.phase { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        guard case .accepted(let resultId) = session.phase else {
            return XCTFail("expected accepted phase, got \(session.phase)")
        }
        XCTAssertEqual(resultId, "pr-1")
        XCTAssertEqual(acceptedId, "pr-1")
        XCTAssertEqual(session.lastPlacementResultId, "pr-1")
        XCTAssertEqual(client.fetchCount, 0, "must not poll job status on VR after accept")
        XCTAssertFalse(session.isActive)
    }

    func testCreateFailureStaysWithRetryActions() async {
        let client = RecordingClient()
        client.createResult = .failure(CurtainPlacementAPIError.server(status: 500, code: nil))
        let session = CurtainPlacementSession()
        session.configure(client: client)

        let pending = PendingCurtainPlacement(
            productId: "p1",
            variantId: "v1",
            catalog2DAssetId: "a1",
            catalogRevision: 1,
            productRevision: "r1",
            displayName: "커튼",
            partnerName: "파트너",
            thumbnailUrl: nil,
            targetSpaceId: "space-1",
            targetSessionId: "space-1",
            projectionKey: nil,
            baseRevisionId: "rev-0-base"
        )
        session.start(with: pending, sessionId: "space-1")
        session.handleSeedTap(
            yawDeg: 10,
            pitchDeg: 5,
            tapPoint: CGPoint(x: 100, y: 200),
            viewSize: CGSize(width: 390, height: 844)
        )
        session.acceptConsentAndCreateJob()

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if case .failed = session.phase { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(session.showsCreateFailureActions)
        XCTAssertTrue(session.isActive)
        XCTAssertNotNil(session.bannerMessage)
    }

    func testOpenPlacementResultsSetsLibraryTab() {
        let suiteName = "CurtainHandoff.app.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SpaceJobStore(defaults: defaults, persistEnabled: false)
        store.bind(.user(userId: "test-handoff"))
        let app = AppState(isMockMode: true, jobStore: store)
        app.selectedTab = .home
        app.pendingViewerJobId = "job-1"

        app.openPlacementResults(resultId: "pr-99")

        XCTAssertEqual(app.selectedTab, .library)
        XCTAssertEqual(app.preferredLibraryCategory, .placementResults)
        XCTAssertEqual(app.pendingLibraryTab, .placementResults)
        XCTAssertEqual(app.pendingPlacementResultHighlightId, "pr-99")
        XCTAssertNil(app.pendingViewerJobId)
    }

    func testDismissCancelsPolling() async {
        let client = RecordingClient()
        let session = CurtainPlacementSession()
        session.configure(client: client)
        let pending = PendingCurtainPlacement(
            productId: "p1",
            variantId: "v1",
            catalog2DAssetId: "a1",
            catalogRevision: 1,
            productRevision: "r1",
            displayName: "커튼",
            partnerName: "파트너",
            thumbnailUrl: nil,
            targetSpaceId: "space-1",
            targetSessionId: "space-1",
            projectionKey: nil,
            baseRevisionId: "rev-0-base"
        )
        session.start(with: pending, sessionId: "space-1")
        // Force legacy polling path then dismiss.
        session.handleSeedTap(
            yawDeg: 0,
            pitchDeg: 0,
            tapPoint: nil,
            viewSize: CGSize(width: 100, height: 100)
        )
        // Enter compositing polling via confirm path isn't needed — dismiss must clear task.
        session.dismiss()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(session.isActive)
    }
}

@MainActor
final class PlacementResultsPollingTests: XCTestCase {
    private final class FlakyListClient: PlacementResultsServing, @unchecked Sendable {
        var listCalls = 0
        var results: [ProductPlacementResultDTO]

        init(results: [ProductPlacementResultDTO]) {
            self.results = results
        }

        func listResults() async throws -> [ProductPlacementResultDTO] {
            listCalls += 1
            return results
        }

        func fetchResult(id: String) async throws -> ProductPlacementResultDTO {
            guard let result = results.first(where: { $0.id == id }) else {
                throw MobilePlacementResultsAPIError.notFound
            }
            return result
        }

        func retryCurtain(placementResultId: String) async throws -> ProductPlacementResultDTO {
            try await fetchResult(id: placementResultId)
        }

        func confirmCurtainJob(jobId: String) async throws {}

        func deleteResult(id: String) async throws {}
    }

    func testPollingCancelledOnDisappear() async {
        let client = FlakyListClient(results: [
            ProductPlacementResultDTO(
                id: "pr-1",
                type: .curtain2D,
                status: .inProgress,
                sourceSpaceId: "s1",
                sourceRevisionId: nil,
                resultRevisionId: nil,
                curtainCompositeJobId: "j1",
                catalogPartnerId: nil,
                catalogProductId: nil,
                catalogVariantId: nil,
                productName: nil,
                partnerName: nil,
                optionName: nil,
                productNameSnapshot: "커튼",
                partnerNameSnapshot: "브랜드",
                optionNameSnapshot: nil,
                widthMm: nil,
                depthMm: nil,
                heightMm: nil,
                previewUrl: nil,
                originalPreviewUrl: nil,
                resultPreviewUrl: nil,
                progress: 0.2,
                failureCode: nil,
                createdAt: nil,
                updatedAt: nil
            ),
        ])
        let vm = PlacementResultsViewModel(client: client)
        vm.onAppear()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if case .loaded = vm.phase { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(vm.isPolling || vm.hasInFlight)
        vm.onDisappear()
        XCTAssertFalse(vm.isPolling)
    }
}
