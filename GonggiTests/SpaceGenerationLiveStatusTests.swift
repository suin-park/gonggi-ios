import XCTest
@testable import Gonggi

/// Scripted status responses for SpaceJobRuntime polling tests.
actor ScriptedSpaceRecordAPIClient: SpaceRecordAPIClienting {
    private var statusQueue: [String: [SpaceRecordStatusResponse]] = [:]
    private var defaultStatus: [String: SpaceRecordStatusResponse] = [:]
    private(set) var fetchCount: [String: Int] = [:]
    var downloadDelayNs: UInt64 = 0
    var downloadShouldFail = false
    var networkFailUntilFetch: Int = 0

    func enqueue(jobId: String, statuses: [SpaceRecordStatusResponse]) {
        statusQueue[jobId] = statuses
    }

    func setSteady(jobId: String, status: SpaceRecordStatusResponse) {
        defaultStatus[jobId] = status
    }

    func create(
        sessionId: String,
        imageFiles: [(direction: String, fileURL: URL)],
        captureMetadataJSON: String?
    ) async throws -> SpaceRecordCreateResponse {
        SpaceRecordCreateResponse(sessionId: sessionId, jobId: sessionId, status: "queued")
    }

    func regenerate(
        sessionId: String,
        imageFiles: [(direction: String, fileURL: URL)],
        captureMetadataJSON: String?
    ) async throws -> SpaceRecordCreateResponse {
        try await create(sessionId: sessionId, imageFiles: imageFiles, captureMetadataJSON: captureMetadataJSON)
    }

    func fetchStatus(jobId: String) async throws -> SpaceRecordStatusResponse {
        let n = (fetchCount[jobId] ?? 0) + 1
        fetchCount[jobId] = n
        if networkFailUntilFetch > 0, n <= networkFailUntilFetch {
            throw SpaceRecordClientError.network
        }
        if var queue = statusQueue[jobId], !queue.isEmpty {
            let next = queue.removeFirst()
            statusQueue[jobId] = queue
            return next
        }
        if let steady = defaultStatus[jobId] {
            return steady
        }
        throw SpaceRecordClientError.jobNotFound
    }

    func downloadImage(from url: URL, to destination: URL) async throws {
        if downloadDelayNs > 0 {
            try await Task.sleep(nanoseconds: downloadDelayNs)
        }
        if downloadShouldFail {
            throw SpaceRecordClientError.network
        }
        let jpeg = MockSpaceRecordAPIClient.makeLatLongJPEG() ?? Data([0xFF, 0xD8, 0xFF, 0xD9])
        try jpeg.write(to: destination, options: .atomic)
    }
}

@MainActor
final class SpaceGenerationLiveStatusTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: SpaceJobStore!
    private var runtime: SpaceJobRuntime!
    private var api: ScriptedSpaceRecordAPIClient!

    override func setUp() async throws {
        suiteName = "gonggi.liveStatus.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SpaceJobStore(defaults: defaults, persistEnabled: true)
        store.bind(.user(userId: "user_live_status"))
        runtime = SpaceJobRuntime(store: store)
        runtime.pollIntervalOverrideNs = 50_000_000 // 50ms
        api = ScriptedSpaceRecordAPIClient()
        runtime.replaceAPI(api)
        _ = AuthSessionGeneration.bump(reason: "testSetup")
    }

    override func tearDown() async throws {
        runtime.cancelAllForAccountChange()
        if let suiteName {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func seedProcessing(jobId: String = "job-live-1") {
        store.upsert(
            SpaceJobRecord(
                sessionId: jobId,
                jobId: jobId,
                createdAt: Date(),
                completedAt: nil,
                serverStatus: "generating",
                displayName: "테스트",
                resultImageURL: nil,
                localLatLongPath: nil,
                width: nil,
                height: nil,
                ownerUserId: "user_live_status"
            )
        )
    }

    func testProcessingToCompletedWithoutTabNavigation() async {
        seedProcessing()
        await api.enqueue(jobId: "job-live-1", statuses: [
            SpaceRecordStatusResponse(status: "generating"),
            SpaceRecordStatusResponse(
                status: "completed",
                imageUrl: "https://example.com/latlong.jpg",
                width: 2048,
                height: 1024
            ),
        ])
        await api.setSteady(
            jobId: "job-live-1",
            status: SpaceRecordStatusResponse(
                status: "completed",
                imageUrl: "https://example.com/latlong.jpg",
                width: 2048,
                height: 1024
            )
        )

        runtime.handleScenePhase(.active)
        runtime.ensurePolling()
        XCTAssertTrue(runtime.isPolling)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if store.job(id: "job-live-1")?.serverStatus == "completed" { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(store.job(id: "job-live-1")?.serverStatus, "completed")
        XCTAssertEqual(store.job(id: "job-live-1")?.resultImageURL, "https://example.com/latlong.jpg")
        XCTAssertEqual(store.job(id: "job-live-1")?.uiStatus, .ready)
    }

    func testProcessingToFailedStopsPolling() async {
        seedProcessing(jobId: "job-fail-1")
        await api.enqueue(jobId: "job-fail-1", statuses: [
            SpaceRecordStatusResponse(status: "generating"),
            SpaceRecordStatusResponse(status: "failed", errorCode: "openai_generation_failed"),
        ])
        runtime.ensurePolling()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if store.job(id: "job-fail-1")?.serverStatus == "failed" { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(store.job(id: "job-fail-1")?.serverStatus, "failed")
        // Allow poll loop to notice empty active set.
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertFalse(runtime.isPolling)
    }

    func testNetworkErrorKeepsProcessingThenCompletes() async {
        seedProcessing(jobId: "job-net-1")
        await api.setSteady(
            jobId: "job-net-1",
            status: SpaceRecordStatusResponse(
                status: "completed",
                imageUrl: "https://example.com/ok.jpg",
                width: 2048,
                height: 1024
            )
        )
        // Fail the first poll fetch; keep processing (not failed), then complete.
        await api.setNetworkFailUntil(1)

        runtime.ensurePolling()

        let deadline = Date().addingTimeInterval(3)
        var sawFailed = false
        while Date() < deadline {
            let status = store.job(id: "job-net-1")?.serverStatus
            if status == "failed" { sawFailed = true }
            if status == "completed" { break }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        XCTAssertFalse(sawFailed, "transient network must not mark the job failed")
        XCTAssertEqual(store.job(id: "job-net-1")?.serverStatus, "completed")
    }

    func testEnsurePollingIsIdempotent() {
        seedProcessing(jobId: "job-dup-1")
        runtime.ensurePolling()
        XCTAssertTrue(runtime.isPolling)
        runtime.ensurePolling()
        runtime.ensurePolling()
        XCTAssertTrue(runtime.isPolling)
        // Still a single poller — second ensure must not leave nil.
        runtime.resumePolling()
        XCTAssertTrue(runtime.isPolling)
    }

    func testBackgroundStopsForegroundResumes() async {
        seedProcessing(jobId: "job-bg-1")
        await api.setSteady(
            jobId: "job-bg-1",
            status: SpaceRecordStatusResponse(status: "generating")
        )
        runtime.handleScenePhase(.active)
        runtime.ensurePolling()
        XCTAssertTrue(runtime.isPolling)

        runtime.handleScenePhase(.background)
        XCTAssertFalse(runtime.isPolling)

        runtime.handleScenePhase(.active)
        runtime.ensurePolling()
        XCTAssertTrue(runtime.isPolling)
    }

    func testInactiveDoesNotStopPolling() {
        seedProcessing(jobId: "job-inactive-1")
        runtime.handleScenePhase(.active)
        runtime.ensurePolling()
        XCTAssertTrue(runtime.isPolling)
        runtime.handleScenePhase(.inactive)
        XCTAssertTrue(runtime.isPolling)
    }

    func testAccountSwitchDiscardsStaleCompletion() async {
        seedProcessing(jobId: "job-stale-a")
        await api.enqueue(jobId: "job-stale-a", statuses: [
            SpaceRecordStatusResponse(status: "generating"),
        ])
        runtime.ensurePolling()
        try? await Task.sleep(nanoseconds: 40_000_000)

        // Switch account generation + clear store presentation.
        _ = AuthSessionGeneration.bump(reason: "accountSwitch")
        runtime.cancelAllForAccountChange()
        store.bind(.user(userId: "user_b"))
        XCTAssertTrue(store.jobs.isEmpty)

        // Late status would have applied to old job — ensure B store still empty.
        await runtime.syncActiveJobsOnce()
        XCTAssertTrue(store.jobs.isEmpty)
    }

    func testCompletedJobsDoNotKeepPolling() async {
        store.upsert(
            SpaceJobRecord(
                sessionId: "done-1",
                jobId: "done-1",
                createdAt: Date(),
                completedAt: Date(),
                serverStatus: "completed",
                displayName: "Done",
                resultImageURL: "https://example.com/x.jpg",
                localLatLongPath: nil,
                width: 2048,
                height: 1024
            )
        )
        runtime.ensurePolling()
        XCTAssertFalse(runtime.isPolling)
    }

    func testFailedJobsDoNotKeepPolling() {
        store.upsert(
            SpaceJobRecord(
                sessionId: "fail-done",
                jobId: "fail-done",
                createdAt: Date(),
                completedAt: nil,
                serverStatus: "failed",
                displayName: "Fail",
                resultImageURL: nil,
                localLatLongPath: nil,
                width: nil,
                height: nil,
                lastErrorCode: "x"
            )
        )
        runtime.ensurePolling()
        XCTAssertFalse(runtime.isPolling)
    }

    func testMultipleJobsIndependentCompletion() async {
        seedProcessing(jobId: "m1")
        seedProcessing(jobId: "m2")
        await api.enqueue(jobId: "m1", statuses: [
            SpaceRecordStatusResponse(
                status: "completed",
                imageUrl: "https://example.com/m1.jpg",
                width: 2048,
                height: 1024
            ),
        ])
        await api.enqueue(jobId: "m2", statuses: [
            SpaceRecordStatusResponse(status: "generating"),
            SpaceRecordStatusResponse(
                status: "completed",
                imageUrl: "https://example.com/m2.jpg",
                width: 2048,
                height: 1024
            ),
        ])
        await api.setSteady(
            jobId: "m2",
            status: SpaceRecordStatusResponse(
                status: "completed",
                imageUrl: "https://example.com/m2.jpg",
                width: 2048,
                height: 1024
            )
        )
        runtime.ensurePolling()
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let a = store.job(id: "m1")?.serverStatus
            let b = store.job(id: "m2")?.serverStatus
            if a == "completed", b == "completed" { break }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        XCTAssertEqual(store.job(id: "m1")?.serverStatus, "completed")
        XCTAssertEqual(store.job(id: "m2")?.serverStatus, "completed")
    }

    func testAppStateRebuildReflectsCompletion() async {
        let app = AppState(isMockMode: false, jobStore: store)
        seedProcessing(jobId: "ui-1")
        app.rebuildSpaces()
        XCTAssertEqual(app.spaces.first(where: { $0.id == "ui-1" })?.status, .processing)

        await api.enqueue(jobId: "ui-1", statuses: [
            SpaceRecordStatusResponse(
                status: "completed",
                imageUrl: "https://example.com/ui.jpg",
                width: 2048,
                height: 1024
            ),
        ])
        // Drive one status apply via sync (same path as poll completion apply).
        let genRuntime = SpaceJobRuntime(store: store)
        genRuntime.replaceAPI(api)
        await genRuntime.syncActiveJobsOnce()
        app.rebuildSpaces()
        XCTAssertEqual(store.job(id: "ui-1")?.serverStatus, "completed")
        XCTAssertEqual(app.spaces.first(where: { $0.id == "ui-1" })?.status, .ready)
    }

    func testSlowDownloadDoesNotBlockCompletedStatus() async {
        seedProcessing(jobId: "slow-dl")
        await api.setDownloadDelay(2_000_000_000) // 2s — longer than we wait for status
        await api.enqueue(jobId: "slow-dl", statuses: [
            SpaceRecordStatusResponse(
                status: "completed",
                imageUrl: "https://example.com/slow.jpg",
                width: 2048,
                height: 1024
            ),
        ])
        runtime.ensurePolling()
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if store.job(id: "slow-dl")?.serverStatus == "completed" { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(store.job(id: "slow-dl")?.serverStatus, "completed")
    }
}

private extension ScriptedSpaceRecordAPIClient {
    func setNetworkFailUntil(_ n: Int) {
        networkFailUntilFetch = n
    }

    func setDownloadDelay(_ ns: UInt64) {
        downloadDelayNs = ns
    }
}
