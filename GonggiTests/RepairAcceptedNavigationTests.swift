import XCTest
@testable import Gonggi

final class RepairAcceptedNavigationTests: XCTestCase {
    func testAutoDismissDelayIsBetweenOneAndOnePointFiveSeconds() {
        let ns = RepairAcceptedNavigation.autoDismissDelayNanoseconds
        XCTAssertGreaterThanOrEqual(ns, 1_000_000_000)
        XCTAssertLessThanOrEqual(ns, 1_500_000_000)
    }

    func testActiveRepairShowsLibraryBadgeWithoutBlockingVRRequirement() {
        let store = SpaceRepairStore.shared
        let sessionId = "nav-ux-\(UUID().uuidString)"
        let job = SpaceRepairJobRecord(
            repairJobId: "rep-nav-\(UUID().uuidString)",
            sessionId: sessionId,
            baseRevisionId: "rev-0-base",
            revisionId: "rev-pending",
            target: RepairTarget.make(
                sessionId: sessionId,
                baseRevisionId: "rev-0-base",
                targetYawDeg: 10,
                targetPitchDeg: 0
            ),
            status: "editing",
            repairMode: "marked_region_direct_edit",
            resultImageURL: nil,
            localLatLongPath: nil,
            createdAt: Date(),
            updatedAt: Date(),
            errorCode: nil
        )
        store.upsert(job)
        defer {
            // Soft cleanup: mark completed so it doesn't leave active forever in shared store
            store.update(repairJobId: job.repairJobId) { $0.status = "failed"; $0.errorCode = "test_cleanup" }
        }

        let overlay = SpaceRepairCardPresentation.overlay(sessionId: sessionId, store: store)
        XCTAssertEqual(overlay.badge, .repairing)
        XCTAssertEqual(overlay.note, "?섏젙 以?)

        var record = SpaceRecord(
            id: sessionId,
            name: "Test",
            capturedAt: Date(),
            status: .ready,
            thumbnailSystemImage: "cube",
            note: nil,
            viewerURL: nil,
            localLatLongPath: nil,
            sessionId: sessionId
        )
        record = SpaceRepairCardPresentation.enrich(record, store: store)
        XCTAssertTrue(record.showsActivityIndicator)
        XCTAssertTrue(record.canOpenExistingVR)
        XCTAssertEqual(record.statusBadgeLabel, "?섏젙 以?)
    }
}
