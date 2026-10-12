import XCTest
@testable import Gonggi

/// Alignment coordinator, guidance planner and metrics (pure logic; also runs on Linux).
final class StoreShelfCoreTests2: XCTestCase {
    func testCoordinatorTimesOutThenAMapStillWins() {
        var c = StoreAlignmentCoordinator(timeoutSeconds: 30)
        XCTAssertEqual(c.state, .notStarted)
        c.start(at: 0)
        XCTAssertEqual(c.state, .restoring)
        c.tick(at: 20)
        XCTAssertEqual(c.state, .restoring)
        c.tick(at: 31)
        XCTAssertEqual(c.state, .failed(.notRestored))
        c.worldMapRestored()
        XCTAssertTrue(c.state.isAligned)
        c.retry(at: 100)
        XCTAssertEqual(c.state, .restoring, "a retry starts clean")
    }

    func testCoordinatorSignWithoutMap() {
        var c = StoreAlignmentCoordinator()
        c.start(at: 0)
        let saved = Rigid.yaw(0.1, translation: Vec3(1, 1, -2))
        c.signObserved(savedPose: saved, livePose: Rigid.translation(Vec3(3, 0, 0)).multiplied(by: saved))
        guard case .aligned(let m, let t, _, _) = c.state else { return XCTFail() }
        XCTAssertEqual(m, .referenceImage)
        XCTAssertEqual(t.translationPart.x, 3, accuracy: 1e-4)
    }

    private func plannerData() -> StoreShelfData {
        var d = StoreShelfData.empty(storeId: "st")
        let plane = ShelfPlane.fromBaseline(a: Vec3(-1, 0, -2), b: Vec3(1, 0, -2), viewer: Vec3(0, 1.4, 0))!
        d.shelves = [ShelfLayout(id: "s1", name: "음료 매대", plane: plane, tierBoundaries: [0.5, 1.0],
                                 createdAt: Date(), updatedAt: Date(), photoFileName: nil)]
        d.placements = [ShelfPlacement(id: "pl", productId: "p", shelfId: "s1", u: 1.5, v: 0.7, tier: 1,
                                       world: plane.worldPoint(u: 1.5, v: 0.7), widthM: 0.1, heightM: 0.2, uncertaintyM: 0.03,
                                       observationCount: 6, firstObservedAt: Date(), lastObservedAt: Date(), status: .present,
                                       needsReview: false)]
        // Walked in front of the shelf along z = 0 (the shelf front is at z = -2).
        for k in 0...40 { d.walkTrail.append(ShelfWalkSample(x: -2 + Float(k) * 0.1, y: 1.4, z: 0, time: Double(k))) }
        d.floorY = 0
        return d
    }

    func testPlannerGivesAWalkableRouteInTheLiveFrame() {
        let d = plannerData()
        let planner = StoreGuidancePlanner(data: d)
        XCTAssertTrue(planner.hasWalkableMap)
        let shift = Rigid.yaw(0.3, translation: Vec3(5, 0, -4))      // the live session origin differs
        let camLive = shift.apply(point: Vec3(-1.5, 1.4, 0))
        let plan = planner.plan(placement: d.placements[0], alignment: shift, cameraLive: camLive)!
        guard case .walkableRoute(let wp) = plan.kind else {
            return XCTFail("expected a route: \(String(describing: plan.routeNote))")
        }
        XCTAssertGreaterThanOrEqual(wp.count, 2)
        XCTAssertEqual(plan.route.count, wp.count)
        XCTAssertEqual(plan.destination.distance(to: shift.apply(point: d.placements[0].world)), 0, accuracy: 1e-4)
        XCTAssertEqual(plan.tierLabel, "2번째 칸")
        XCTAssertEqual(plan.tierBand.count, 4)
        XCTAssertEqual(plan.shelfName, "음료 매대")
    }

    func testPlannerFallsBackToStraightDirectionWhenNoTrail() {
        var d = plannerData()
        d.walkTrail = []
        let planner = StoreGuidancePlanner(data: d)
        XCTAssertFalse(planner.hasWalkableMap)
        let plan = planner.plan(placement: d.placements[0], alignment: .identity, cameraLive: Vec3(0, 1.4, 0))!
        XCTAssertEqual(plan.kind, .straightDirection)
        XCTAssertNotNil(plan.routeNote)
        XCTAssertTrue(plan.route.isEmpty)
        let orphan = ShelfPlacement(id: "x", productId: "p", shelfId: "none", u: 0, v: 0, tier: 0, world: .zero, widthM: 0, heightM: 0,
                                    uncertaintyM: 0, observationCount: 1, firstObservedAt: Date(), lastObservedAt: Date(),
                                    status: .present, needsReview: false)
        XCTAssertNil(planner.plan(placement: orphan, alignment: .identity, cameraLive: .zero))
    }

    func testPlannerDoesNotInventAConnectionBetweenSeparateWalks() {
        var d = plannerData()
        d.walkTrail = []
        for k in 0...40 { d.walkTrail.append(ShelfWalkSample(x: -2 + Float(k) * 0.1, y: 1.4, z: 0, time: Double(k))) }
        for k in 0...40 { d.walkTrail.append(ShelfWalkSample(x: 2 - Float(k) * 0.1, y: 1.4, z: -3.2, time: 100 + Double(k))) }
        let planner = StoreGuidancePlanner(data: d)
        let plan = planner.plan(placement: d.placements[0], alignment: .identity, cameraLive: Vec3(0, 1.4, -3.2))!
        XCTAssertEqual(plan.kind, .straightDirection)
    }

    func testMetricsSummary() {
        let t0 = Date(timeIntervalSince1970: 0)
        var f = StoreMetricsFile()
        f.registrations = [StoreRegistrationMetric(id: "r", storeId: "s", shelfId: "sh", startedAt: t0, finishedAt: t0.addingTimeInterval(240),
                                                   productsSaved: 20, placementsSaved: 22, rejectedBlurry: 2, rejectedFewObservations: 3,
                                                   unplaceableDetections: 9, manualCorrections: 5, correctionKinds: ["delete": 3, "rename": 2])]
        f.searches = [
            StoreSearchMetric(id: "a", storeId: "s", startedAt: t0, alignedAt: t0.addingTimeInterval(8), recognizedAt: t0.addingTimeInterval(11),
                              guidanceStartedAt: t0.addingTimeInterval(12), outcome: "matched", matchedProductId: "p",
                              testerVerdict: "correct", alignmentMethod: "worldMap", guidanceKind: "route"),
            StoreSearchMetric(id: "b", storeId: "s", startedAt: t0, alignedAt: nil, recognizedAt: nil, guidanceStartedAt: nil,
                              outcome: "unregistered", matchedProductId: nil, testerVerdict: "wrong", alignmentMethod: nil, guidanceKind: nil),
            StoreSearchMetric(id: "c", storeId: "s", startedAt: t0, alignedAt: nil, recognizedAt: nil, guidanceStartedAt: nil,
                              outcome: "uncertain", matchedProductId: nil, testerVerdict: nil, alignmentMethod: nil, guidanceKind: nil),
        ]
        let attempts = [
            StoreRestoreAttempt(id: "1", startedAt: t0, outcome: "restored", secondsToRelocalize: 5, markersExpected: 0,
                                markersPresentAfterRestore: 0, trackingReasonsSeen: [], observedOffset: "within_5cm", note: nil),
            StoreRestoreAttempt(id: "2", startedAt: t0, outcome: "failed_timeout", secondsToRelocalize: nil, markersExpected: 0,
                                markersPresentAfterRestore: 0, trackingReasonsSeen: [], observedOffset: "not_checked", note: nil),
        ]
        let s = StoreMetricsSummary.summarize(f, restoreAttempts: attempts)
        XCTAssertEqual(s.registrationCount, 1)
        XCTAssertEqual(s.meanRegistrationSeconds!, 240, accuracy: 1e-6)
        XCTAssertEqual(s.meanManualCorrectionsPerProduct!, 0.25, accuracy: 1e-9)
        XCTAssertEqual(s.judgedSearches, 2)
        XCTAssertEqual(s.recognitionAccuracy!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.meanSecondsToGuidance!, 12, accuracy: 1e-9)
        XCTAssertEqual(s.restoreSuccessRate!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(StoreShelfTimeText.lastConfirmed(t0, now: t0.addingTimeInterval(30)), "방금 확인")
        XCTAssertEqual(StoreShelfTimeText.lastConfirmed(t0, now: t0.addingTimeInterval(2 * 86_400 + 5)), "2일 전 확인")
    }
    func testStoreDataCanBeMovedIntoAnotherWorldFrame() {
        var d = plannerData()
        d.referenceSigns = [ShelfReferenceSign(id: "sign", name: "안내판", imageFileName: "s.jpg", physicalWidthM: 0.4,
                                               savedPose: Rigid.yaw(0.2, translation: Vec3(1, 1.2, -2)))]
        let t = Rigid.yaw(0.6, translation: Vec3(3, 0.1, -1))
        let m = d.transformed(by: t)
        // A product is still on its shelf plane at the same plane coordinates.
        let shelfOld = d.shelves[0], shelfNew = m.shelves[0]
        let c = shelfNew.plane.coordinates(of: m.placements[0].world)
        XCTAssertEqual(c.u, d.placements[0].u, accuracy: 1e-3)
        XCTAssertEqual(c.v, d.placements[0].v, accuracy: 1e-3)
        XCTAssertEqual(c.offset, 0, accuracy: 1e-3)
        XCTAssertEqual(shelfNew.plane.normal.dot(shelfOld.plane.normal), cosf(0.6), accuracy: 1e-3)
        XCTAssertEqual(m.walkTrail[0].y, d.walkTrail[0].y + 0.1, accuracy: 1e-4)
        XCTAssertEqual(m.floorY!, 0.1, accuracy: 1e-4)
        // The sign pose moves with the world.
        let expected = t.multiplied(by: d.referenceSigns[0].savedPose!)
        XCTAssertEqual(m.referenceSigns[0].savedPose!.translationPart.distance(to: expected.translationPart), 0, accuracy: 1e-4)
        // Undoing the move restores the original data.
        let back = m.transformed(by: t.inverse())
        XCTAssertEqual(back.placements[0].world.distance(to: d.placements[0].world), 0, accuracy: 1e-3)
    }
}
