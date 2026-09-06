import XCTest
@testable import Gonggi

final class SpaceRepairCardPresentationTests: XCTestCase {
    func testActiveRepairKeepsSuccessPathAndRepairingBadge() {
        let store = SpaceRepairStore.shared
        let session = "sess-card-\(UUID().uuidString)"
        let target = RepairTarget.make(
            sessionId: session,
            baseRevisionId: "rev-0-base",
            targetYawDeg: 10,
            targetPitchDeg: 0
        )
        let success = SpaceRepairJobRecord(
            repairJobId: "rep-ok-\(UUID().uuidString)",
            sessionId: session,
            baseRevisionId: "rev-0-base",
            revisionId: "rev-1",
            target: target,
            status: "completed",
            repairMode: "marked_region_direct_edit",
            resultImageURL: nil,
            localLatLongPath: "/tmp/fake-success.jpg",
            createdAt: Date().addingTimeInterval(-100),
            updatedAt: Date().addingTimeInterval(-100),
            errorCode: nil
        )
        // Path validity will fail for /tmp ??badge still repairing from active.
        let active = SpaceRepairJobRecord(
            repairJobId: "rep-active-\(UUID().uuidString)",
            sessionId: session,
            baseRevisionId: "rev-1",
            revisionId: "rev-2",
            target: target,
            status: "editing",
            repairMode: "marked_region_direct_edit",
            resultImageURL: nil,
            localLatLongPath: nil,
            createdAt: Date(),
            updatedAt: Date(),
            errorCode: nil
        )
        store.upsert(success)
        store.upsert(active)
        let overlay = SpaceRepairCardPresentation.overlay(sessionId: session, store: store)
        XCTAssertEqual(overlay.badge, .repairing)
        XCTAssertEqual(overlay.note, "?섏젙 以?)
    }

    func testFailedDoesNotClearWhenNoSuccess() {
        let store = SpaceRepairStore.shared
        let session = "sess-fail-\(UUID().uuidString)"
        let target = RepairTarget.make(
            sessionId: session,
            baseRevisionId: "rev-0-base",
            targetYawDeg: 0,
            targetPitchDeg: 0
        )
        store.upsert(
            SpaceRepairJobRecord(
                repairJobId: "rep-fail-\(UUID().uuidString)",
                sessionId: session,
                baseRevisionId: "rev-0-base",
                revisionId: "rev-x",
                target: target,
                status: "failed",
                repairMode: "marked_region_direct_edit",
                resultImageURL: nil,
                localLatLongPath: nil,
                createdAt: Date(),
                updatedAt: Date(),
                errorCode: "x"
            )
        )
        let overlay = SpaceRepairCardPresentation.overlay(sessionId: session, store: store)
        XCTAssertEqual(overlay.badge, .repairFailed)
        var record = SpaceRecord(
            id: session,
            name: "t",
            capturedAt: Date(),
            status: .ready,
            thumbnailSystemImage: "cube",
            sessionId: session
        )
        record = SpaceRepairCardPresentation.enrich(record, store: store)
        XCTAssertEqual(record.status, .ready)
        XCTAssertEqual(record.repairBadge, .repairFailed)
        XCTAssertTrue(record.canOpenExistingVR)
    }
}
