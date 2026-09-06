import XCTest
@testable import Gonggi

@MainActor
final class SpaceJobStoreTests: XCTestCase {
    func testPersistAndReload() {
        let store = SpaceJobStore()
        store.remove(jobId: "job-test-1")
        let job = SpaceJobRecord(
            sessionId: "dir-test-1",
            jobId: "job-test-1",
            createdAt: Date(),
            serverStatus: "generating",
            displayName: "테스트 공간",
            resultImageURL: nil,
            localLatLongPath: nil,
            width: nil,
            height: nil
        )
        store.upsert(job)
        XCTAssertEqual(store.job(id: "job-test-1")?.serverStatus, "generating")
        XCTAssertTrue(store.activeJobs().contains(where: { $0.jobId == "job-test-1" }))

        store.update(jobId: "job-test-1") { $0.serverStatus = "completed" }
        XCTAssertEqual(store.job(id: "job-test-1")?.uiStatus, .ready)
        store.remove(jobId: "job-test-1")
    }

    func testLatLongSizeStillAccepts3840() {
        XCTAssertTrue(SpaceGenerationCoordinator.isValidLatLongSize(width: 3840, height: 1920))
    }
}
