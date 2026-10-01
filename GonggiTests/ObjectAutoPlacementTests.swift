import XCTest
#if canImport(simd)
import simd
#endif
@testable import Gonggi

/// Automatic first placement of the product box: when it places, when it must not, and that it places once.
final class ObjectAutoPlacementTests: XCTestCase {
    private let camera = SIMD3<Float>(0, 1.4, 1.4)
    /// Looking 45° down toward -z: the centre ray meets the floor (y = 0) at the origin.
    private var rayDown: SIMD3<Float> { simd_normalize(SIMD3<Float>(0, -1, -1)) }

    private func hit(_ x: Float, _ y: Float, _ z: Float, existing: Bool = true) -> ObjectAutoPlacementHit? {
        ObjectAutoPlacementHit(
            point: SIMD3<Float>(x, y, z), isExistingPlane: existing, planeMinSideM: existing ? 0.6 : nil
        )
    }

    private func floorHits(existing: Bool = true, jitter: Float = 0) -> [ObjectAutoPlacementHit?] {
        [
            hit(jitter, 0, 0, existing: existing), hit(-0.05, 0, 0, existing: existing), hit(0.05, 0, 0, existing: existing),
            hit(0, 0, -0.05, existing: existing), hit(0, 0, 0.05, existing: existing),
        ]
    }

    private func sample(
        _ t: TimeInterval, tracking: Bool = true, camera cam: SIMD3<Float>? = nil, ray: SIMD3<Float>? = nil,
        hits: [ObjectAutoPlacementHit?]? = nil
    ) -> ObjectAutoPlacementSample {
        ObjectAutoPlacementSample(
            timestamp: t, trackingNormal: tracking, cameraPosition: cam ?? camera,
            centreRayDirection: ray ?? rayDown, hits: hits ?? floorHits()
        )
    }

    private let boxHeight: Float = 0.35

    /// Feeds one sample every 0.1 s from t = 10 and returns the index of the first `.place` (nil = never).
    private func firstPlacement(
        _ planner: inout ObjectAutoPlacementPlanner, steps: Int, make: (Int, TimeInterval) -> ObjectAutoPlacementSample
    ) -> (index: Int, base: SIMD3<Float>, existing: Bool)? {
        for i in 0..<steps {
            let t = 10 + Double(i) * 0.1
            if case .place(let base, let existing) = planner.ingest(make(i, t), boxHeight: boxHeight) {
                return (i, base, existing)
            }
        }
        return nil
    }

    func testPlacesOnceAfterTheSurfaceHeldStillAndCentresTheBoxOnTheCentreRay() {
        var planner = ObjectAutoPlacementPlanner()
        let placed = firstPlacement(&planner, steps: 30) { _, t in sample(t) }
        XCTAssertNotNil(placed)
        guard let placed else { return }
        XCTAssertGreaterThanOrEqual(placed.index, 10, "an existing plane must hold about one second")
        XCTAssertTrue(placed.existing)
        XCTAssertEqual(placed.base.y, 0, accuracy: 1e-5, "the box stands on the surface")
        // The default-size box's CENTRE lies on the centre ray, not the base point (which would sit behind the product).
        let centre = placed.base + SIMD3<Float>(0, boxHeight / 2, 0)
        let toCentre = simd_normalize(centre - camera)
        XCTAssertEqual(toCentre.x, rayDown.x, accuracy: 1e-4)
        XCTAssertEqual(toCentre.y, rayDown.y, accuracy: 1e-4)
        XCTAssertEqual(toCentre.z, rayDown.z, accuracy: 1e-4)
        XCTAssertGreaterThan(placed.base.z, 0, "the base is nearer to the phone than where the ray meets the floor")
        // Placed once: the planner is done.
        XCTAssertTrue(planner.isDisabled)
        XCTAssertEqual(planner.ingest(sample(20), boxHeight: boxHeight), .waiting)
    }

    func testEstimatedPlaneMustHoldLonger() {
        var planner = ObjectAutoPlacementPlanner()
        let placed = firstPlacement(&planner, steps: 40) { _, t in sample(t, hits: floorHits(existing: false)) }
        XCTAssertNotNil(placed)
        XCTAssertGreaterThanOrEqual(placed?.index ?? 0, 15)
        XCTAssertEqual(placed?.existing, false)
    }

    func testSurfacesAtDifferentHeightsAreAmbiguousNotGuessed() {
        // A table top at 0.75 m with the floor visible behind it.
        let mixed: [ObjectAutoPlacementHit?] = [
            hit(0, 0.75, 0), hit(-0.05, 0.75, 0), hit(0.05, 0.75, 0), hit(0, 0.75, -0.05), hit(0, 0, -0.9),
        ]
        var planner = ObjectAutoPlacementPlanner()
        var sawAmbiguous = false
        for i in 0..<60 {
            let d = planner.ingest(sample(10 + Double(i) * 0.1, hits: mixed), boxHeight: boxHeight)
            if case .place = d { XCTFail("must not place when two surface heights are in view") }
            if d == .ambiguous { sawAmbiguous = true }
        }
        XCTAssertTrue(sawAmbiguous)
    }

    func testDoesNotPlaceWhenTrackingIsLimitedTooCloseTooFarOrLookingFlat() {
        func never(_ make: @escaping (TimeInterval) -> ObjectAutoPlacementSample, _ message: String) {
            var planner = ObjectAutoPlacementPlanner()
            let placed = firstPlacement(&planner, steps: 40) { _, t in make(t) }
            XCTAssertNil(placed, message)
        }
        never({ self.sample($0, tracking: false) }, "tracking limited")
        never({ self.sample($0, camera: SIMD3<Float>(0, 3.0, 3.5)) }, "surface too far (> 2.5 m)")
        never({ self.sample($0, camera: SIMD3<Float>(0, 0.2, 0.2)) }, "surface too close (< 0.35 m)")
        never({ self.sample($0, ray: simd_normalize(SIMD3<Float>(0, -0.05, -1))) }, "looking nearly horizontally")
        never({ self.sample($0, hits: [self.hit(0, 0, 0), nil, nil, nil, nil]) }, "too few surface hits")
        never({ self.sample($0, hits: [nil, self.hit(0, 0, 0), self.hit(0, 0, 0), self.hit(0, 0, 0), self.hit(0, 0, 0)]) }, "no hit at the centre")
    }

    func testAMovingHitRestartsTheWindow() {
        var planner = ObjectAutoPlacementPlanner()
        // The centre hit slides 3 cm every step: it never holds still.
        let placed = firstPlacement(&planner, steps: 60) { i, t in
            sample(t, hits: floorHits(jitter: Float(i) * 0.03))
        }
        XCTAssertNil(placed)
    }

    func testDisabledPlannerNeverPlaces() {
        var planner = ObjectAutoPlacementPlanner()
        planner.disable()
        XCTAssertNil(firstPlacement(&planner, steps: 40) { _, t in sample(t) })
        XCTAssertFalse(planner.shouldShowManualHint(now: 100))
    }

    func testManualHintAfterTheSearchRanTooLong() {
        var planner = ObjectAutoPlacementPlanner()
        XCTAssertFalse(planner.shouldShowManualHint(now: 5), "no sample yet")
        _ = planner.ingest(sample(10, tracking: false), boxHeight: boxHeight)
        XCTAssertFalse(planner.shouldShowManualHint(now: 15.9))
        XCTAssertTrue(planner.shouldShowManualHint(now: 16.0))
    }

    func testBaseCenterFallsBackToTheHitWhenTheCameraIsBelowTheBoxCentre() {
        let base = ObjectAutoPlacementPlanner.baseCenter(
            camera: SIMD3<Float>(0, 0.1, 1), rayDirection: simd_normalize(SIMD3<Float>(0, -0.2, -1)),
            surfaceY: 0, boxHeight: 0.35, fallback: SIMD3<Float>(0.3, 0, -0.5)
        )
        XCTAssertEqual(base, SIMD3<Float>(0.3, 0, -0.5))
    }

    // MARK: - Placement gate (automatic and manual cannot both place)

    func testFirstClaimWinsAndAutomaticNeverFollowsAManualTouch() {
        var gate = ObjectPlacementGate()
        XCTAssertTrue(gate.claim(.auto))
        XCTAssertFalse(gate.claim(.manual), "already placed")
        XCTAssertFalse(gate.claim(.auto))

        var touched = ObjectPlacementGate()
        touched.manualTouch()
        XCTAssertFalse(touched.claim(.auto), "after a touch the user is in charge")
        XCTAssertTrue(touched.claim(.manual))
        XCTAssertFalse(touched.claim(.manual), "a second tap cannot place a second box")
    }

    func testPlaceAgainTurnsAutomaticPlacementOffForGood() {
        var gate = ObjectPlacementGate()
        XCTAssertTrue(gate.claim(.auto))
        gate.placeAgain()
        XCTAssertFalse(gate.claim(.auto), "automatic placement must not put the box back")
        XCTAssertTrue(gate.claim(.manual))
        XCTAssertFalse(gate.claim(.auto))
    }
}
