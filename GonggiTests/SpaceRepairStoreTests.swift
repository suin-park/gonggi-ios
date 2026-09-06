import XCTest
@testable import Gonggi

final class SpaceRepairStoreTests: XCTestCase {
    func testUpsertPersistsActiveJobFields() {
        let store = SpaceRepairStore.shared
        let target = RepairTarget.make(
            sessionId: "sess-test-repair",
            baseRevisionId: "rev-0-base",
            targetYawDeg: 12,
            targetPitchDeg: -3
        )
        let job = SpaceRepairJobRecord(
            repairJobId: "rep-test-\(UUID().uuidString)",
            sessionId: target.sessionId,
            baseRevisionId: target.baseRevisionId,
            revisionId: "rev-1-test",
            target: target,
            status: "uploaded",
            repairMode: "marked_region_direct_edit",
            resultImageURL: nil,
            localLatLongPath: nil,
            createdAt: Date(),
            updatedAt: Date(),
            errorCode: nil
        )
        store.upsert(job)
        let loaded = store.job(repairJobId: job.repairJobId)
        XCTAssertEqual(loaded?.sessionId, target.sessionId)
        XCTAssertEqual(loaded?.revisionId, "rev-1-test")
        XCTAssertEqual(loaded?.target.targetYawDeg, 12)
        XCTAssertTrue(loaded?.isActive == true)

        store.update(repairJobId: job.repairJobId) { $0.status = "failed" }
        XCTAssertEqual(store.job(repairJobId: job.repairJobId)?.status, "failed")
        XCTAssertNil(store.active(for: target.sessionId))
    }
}
