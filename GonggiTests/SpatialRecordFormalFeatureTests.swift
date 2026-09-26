import XCTest
@testable import Gonggi

/// Build 72 — 3D 공간 기록 as a formal feature: native profile, real Library state, retry.
@MainActor
final class SpatialRecordFormalFeatureTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "gonggi.spatialFormal.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        if let suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        super.tearDown()
    }

    private func makeStore() -> GaussianGenerationStore {
        let store = GaussianGenerationStore(defaults: defaults)
        store.bind(userId: "user_a")
        store.upsert(spaceId: "s1", jobId: "j1", name: "거실", qualityProfile: "p", status: "uploading")
        return store
    }

    func testAppRequestsNativeFasterGsWithoutFilter() {
        XCTAssertEqual(
            ServerGenerationProfileMapper.spatialPackageProfile,
            "spatial_package_colmap_fastergs_native_v1"
        )
        XCTAssertEqual(
            ServerGenerationProfileMapper.sanitize("spatial_package_colmap_fastergs_native_v1"),
            "spatial_package_colmap_fastergs_native_v1"
        )
    }

    func testInterruptedUploadIsShownAsRetryableFailureNotGenerating() {
        let store = makeStore()
        store.markInterrupted(spaceId: "s1")
        let record = store.record(spaceId: "s1")!
        XCTAssertEqual(record.spaceStatus, .failed)
        XCTAssertEqual(record.userFacingStatusLabel, "업로드 중단 · 다시 시도할 수 있어요")
        XCTAssertTrue(record.canRetry)
        XCTAssertTrue(store.activeJobs.isEmpty, "interrupted rows are not polled as in-progress")
    }

    func testServerFailureCodeDrivesLabel() {
        let store = makeStore()
        store.applyRemote(spaceId: "s1", status: "failed", stage: nil, progress: 0, failureCode: "NATIVE_UNAVAILABLE")
        XCTAssertEqual(store.record(spaceId: "s1")?.userFacingStatusLabel, "생성 서버 준비 안 됨 · 다시 시도할 수 있어요")
        store.applyRemote(spaceId: "s1", status: "failed", stage: nil, progress: 0, failureCode: "RETRY_LIMIT")
        XCTAssertEqual(store.record(spaceId: "s1")?.canRetry, false)
    }

    func testCatalogDoesNotHideLocalInterruptionButReadyWins() {
        let store = makeStore()
        store.markInterrupted(spaceId: "s1")
        store.applyRemoteCatalog(
            [.init(spaceId: "s1", name: "거실", status: "uploading", createdAt: Date())],
            forUserId: "user_a"
        )
        XCTAssertEqual(store.record(spaceId: "s1")?.spaceStatus, .failed)
        store.applyRemoteCatalog(
            [.init(spaceId: "s1", name: "거실", status: "ready", createdAt: Date())],
            forUserId: "user_a"
        )
        XCTAssertEqual(store.record(spaceId: "s1")?.spaceStatus, .ready)
    }

    func testActiveUploadTrackingIsInMemory() {
        let store = makeStore()
        store.beginActiveUpload(spaceId: "s1")
        XCTAssertTrue(store.isUploadActive(spaceId: "s1"))
        store.endActiveUpload(spaceId: "s1")
        XCTAssertFalse(store.isUploadActive(spaceId: "s1"))
    }

    func testSpatialRecordHiddenUntilServerIncludesAccount() {
        let live = AppState(isMockMode: false, spaceService: MockSpaceGenerationService())
        XCTAssertNil(live.spatialRecordAvailable)
        XCTAssertFalse(live.showsSpatialRecord, "unknown rollout scope must not show 3D 공간 기록")
        let mock = AppState(isMockMode: true)
        XCTAssertTrue(mock.showsSpatialRecord)
    }

    func testServerCodesHaveClearMessagesWithoutRawCodes() {
        for code in ["NATIVE_UNAVAILABLE", "JOB_LIMIT_ACTIVE", "JOB_LIMIT_DAILY", "RETRY_LIMIT", "ORG_REQUIRED", "JOB_EXPIRED"] {
            let message = SpaceGenerationErrorPresenter.userMessage(
                for: SpaceGenerationError.server(code: code, httpStatus: 400)
            )
            XCTAssertFalse(message.contains(code), code)
            XCTAssertNotEqual(message, SpaceGenerationErrorPresenter.genericCreateFailure, code)
        }
    }
}
