import XCTest
@testable import Gonggi

@MainActor
final class SpaceJobStoreTests: XCTestCase {
    func testPersistAndReload() {
        let suite = "gonggi.spaceJobStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SpaceJobStore(defaults: defaults, persistEnabled: true)
        store.bind(.user(userId: "test-user"))
        store.remove(jobId: "job-test-1")
        let job = SpaceJobRecord(
            sessionId: "dir-test-1",
            jobId: "job-test-1",
            createdAt: Date(),
            completedAt: nil,
            serverStatus: "generating",
            displayName: "테스트 공간",
            resultImageURL: nil,
            localLatLongPath: nil,
            width: nil,
            height: nil
        )
        store.upsert(job)
        XCTAssertEqual(store.job(id: "job-test-1")?.serverStatus, "generating")
        XCTAssertEqual(store.job(id: "job-test-1")?.ownerUserId, "test-user")
        XCTAssertTrue(store.activeJobs().contains(where: { $0.jobId == "job-test-1" }))

        store.update(jobId: "job-test-1") { $0.serverStatus = "completed" }
        XCTAssertEqual(store.job(id: "job-test-1")?.uiStatus, .ready)

        let reloaded = SpaceJobStore(defaults: defaults, persistEnabled: true)
        reloaded.bind(.user(userId: "test-user"))
        XCTAssertEqual(reloaded.job(id: "job-test-1")?.serverStatus, "completed")

        store.remove(jobId: "job-test-1")
    }

    func testLatLongSizeStillAccepts3840() {
        XCTAssertTrue(SpaceGenerationCoordinator.isValidLatLongSize(width: 3840, height: 1920))
    }
}
