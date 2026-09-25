import XCTest
@testable import Gonggi

/// Build 69 — 3DGS library + placement results must not bleed across accounts.
@MainActor
final class GaussianAccountIsolationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "gonggi.gaussianIsolation.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        if let suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        super.tearDown()
    }

    private func remote(_ id: String, _ status: String = "ready", _ name: String = "공간") -> GaussianGenerationStore.RemoteSpace {
        .init(spaceId: id, name: name, status: status, createdAt: Date())
    }

    func testLegacyUnownedRecordsAreNeverShownOrAssigned() {
        let legacy = """
        [{"spaceId":"legacy-space","jobId":"legacy-job","name":"옛 기록","qualityProfile":"spatial_package_v1",
          "status":"ready","progress":1,"createdAt":0,"updatedAt":0}]
        """
        defaults.set(Data(legacy.utf8), forKey: GaussianGenerationStore.legacyUnownedDefaultsKey)
        let store = GaussianGenerationStore(defaults: defaults)
        XCTAssertTrue(store.jobs.isEmpty, "empty before any account is bound")
        store.bind(userId: "user_a")
        XCTAssertTrue(store.jobs.isEmpty, "legacy device-global rows must not be absorbed")
        XCTAssertNotNil(defaults.data(forKey: GaussianGenerationStore.legacyUnownedDefaultsKey), "legacy data preserved")
    }

    func testPartitionsAreSeparateAcrossSwitchAndRelaunch() {
        let store = GaussianGenerationStore(defaults: defaults)
        store.bind(userId: "suin")
        store.upsert(spaceId: "s-suin", jobId: "j-suin", name: "Suin 공간", qualityProfile: "p", status: "processing")
        store.applyRemoteCatalog([remote("s-suin"), remote("s-verify", "ready", "화질 검증용 교실 — 복구본")], forUserId: "suin")
        XCTAssertEqual(Set(store.jobs.map(\.spaceId)), ["s-suin", "s-verify"])

        store.unbind()
        XCTAssertTrue(store.jobs.isEmpty)
        store.bind(userId: "other")
        XCTAssertTrue(store.jobs.isEmpty, "other account sees nothing from suin")
        store.applyRemoteCatalog([remote("s-other")], forUserId: "other")
        XCTAssertEqual(store.jobs.map(\.spaceId), ["s-other"])

        store.bind(userId: "suin")
        XCTAssertEqual(Set(store.jobs.map(\.spaceId)), ["s-suin", "s-verify"])

        // "Relaunch": a fresh store instance reads only the bound partition.
        let relaunched = GaussianGenerationStore(defaults: defaults)
        XCTAssertTrue(relaunched.jobs.isEmpty)
        relaunched.bind(userId: "suin")
        XCTAssertEqual(Set(relaunched.jobs.map(\.spaceId)), ["s-suin", "s-verify"])
        XCTAssertTrue(relaunched.asSpaceRecords().contains { $0.name == "화질 검증용 교실 — 복구본" })
    }

    func testCatalogForAnotherBoundUserIsIgnored() {
        let store = GaussianGenerationStore(defaults: defaults)
        store.bind(userId: "other")
        store.applyRemoteCatalog([remote("s-suin-private")], forUserId: "suin")
        XCTAssertTrue(store.jobs.isEmpty, "late catalog of the previous account must not land")
    }

    func testRemoteMergeKeepsInFlightDropsDeletedSkipsRemoteFailures() {
        let store = GaussianGenerationStore(defaults: defaults)
        store.bind(userId: "u")
        store.upsert(spaceId: "inflight", jobId: "j1", name: "생성 중", qualityProfile: "p", status: "processing")
        store.upsert(spaceId: "deleted-on-server", jobId: "j2", name: "삭제됨", qualityProfile: "p", status: "ready")
        store.applyRemote(spaceId: "deleted-on-server", status: "ready", stage: nil, progress: 1, failureCode: nil)
        store.applyRemoteCatalog([remote("remote-ready"), remote("remote-failed", "failed")], forUserId: "u")
        let ids = Set(store.jobs.map(\.spaceId))
        XCTAssertEqual(ids, ["inflight", "remote-ready"])
        let remoteRow = store.record(spaceId: "remote-ready")
        XCTAssertEqual(remoteRow?.status, "ready")
        XCTAssertTrue(remoteRow?.isRemoteOnly == true)
        XCTAssertFalse(store.activeJobs.contains { $0.jobId.isEmpty }, "remote-only rows are not polled by job id")
    }

    func testSignedOutUpsertIsDropped() {
        let store = GaussianGenerationStore(defaults: defaults)
        store.upsert(spaceId: "x", jobId: "j", name: "n", qualityProfile: "p", status: "processing")
        XCTAssertTrue(store.jobs.isEmpty)
    }
}

@MainActor
final class PlacementResultsAccountSwitchTests: XCTestCase {
    private final class SlowClient: PlacementResultsServing, @unchecked Sendable {
        var onList: (() async -> Void)?
        var results: [ProductPlacementResultDTO]
        init(results: [ProductPlacementResultDTO]) { self.results = results }
        func listResults() async throws -> [ProductPlacementResultDTO] {
            await onList?()
            return results
        }
        func fetchResult(id: String) async throws -> ProductPlacementResultDTO { throw MobilePlacementResultsAPIError.notFound }
        func retryCurtain(placementResultId: String) async throws -> ProductPlacementResultDTO { throw MobilePlacementResultsAPIError.notFound }
        func confirmCurtainJob(jobId: String) async throws {}
        func confirmSpaceCleanupJob(jobId: String) async throws {}
        func retrySpaceCleanupJob(jobId: String) async throws -> ProductPlacementResultDTO { throw MobilePlacementResultsAPIError.notFound }
        func deleteResult(id: String) async throws {}
    }

    private func dto(_ id: String) -> ProductPlacementResultDTO {
        ProductPlacementResultDTO(
            id: id, type: .curtain2D, status: .completed, sourceSpaceId: "s", sourceRevisionId: nil,
            resultRevisionId: nil, curtainCompositeJobId: "j", catalogPartnerId: nil, catalogProductId: nil,
            catalogVariantId: nil, productName: nil, partnerName: nil, optionName: nil,
            productNameSnapshot: "커튼", partnerNameSnapshot: "브랜드", optionNameSnapshot: nil,
            widthMm: nil, depthMm: nil, heightMm: nil, previewUrl: nil, originalPreviewUrl: nil,
            resultPreviewUrl: nil, progress: 1, failureCode: nil, createdAt: nil, updatedAt: nil
        )
    }

    func testAccountResetClearsResults() async {
        let vm = PlacementResultsViewModel(client: SlowClient(results: [dto("a-1")]))
        await vm.refresh(forceLoading: true)
        XCTAssertEqual(vm.results.map(\.id), ["a-1"])
        vm.resetForAccountChange()
        XCTAssertTrue(vm.results.isEmpty)
    }

    func testLateResponseFromPreviousAccountIsDiscarded() async {
        let client = SlowClient(results: [dto("previous-account")])
        let vm = PlacementResultsViewModel(client: client)
        client.onList = {
            // Account switch happens while the request is in flight.
            await MainActor.run { _ = AuthSessionGeneration.bump(reason: "test-switch") }
        }
        await vm.refresh(forceLoading: true)
        XCTAssertTrue(vm.results.isEmpty, "stale list must not overwrite the new account")
    }
}
