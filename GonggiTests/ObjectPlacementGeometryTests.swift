import XCTest
import simd
@testable import Gonggi

/// Locating by two taps on the object, the walk-around refinement, the drag mapping and the placement trace.
/// The fixture holds REAL ARKit camera data (V1_006: camera positions and optical axes) with expected values computed by
/// the Python study (docs/OBJECT_PLACEMENT_REDESIGN_20261002.md), so these tests tie the app code to the evidence.
final class ObjectPlacementGeometryTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Ray: Decodable { var o: [Double]; var d: [Double] }
        struct Pair: Decodable {
            var o1: [Double]; var d1: [Double]; var o2: [Double]; var d2: [Double]
            var expectedXZ: [Double]; var skewM: Double; var angleDeg: Double; var baselineM: Double
        }
        var truthXZ: [Double]
        var floorY: Double
        var rays: [Ray]
        var plainXZ: [Double]
        var robustXZ: [Double]
        var arcDegAroundRobust: Double
        var twoTap: [Pair]
    }

    private func fixture() throws -> Fixture {
        let name = "placement_rays_v006"
        let bundle = Bundle(for: Self.self)
        let candidates = [
            bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            bundle.url(forResource: name, withExtension: "json"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json"),
        ]
        guard let url = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("fixture missing")
        }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func v3(_ a: [Double]) -> SIMD3<Double> { SIMD3(a[0], a[1], a[2]) }

    // MARK: against the real captured rays

    func testLeastSquaresAndRobustMatchThePythonStudy() throws {
        let f = try fixture()
        let rays = f.rays.map { ObjectRay(origin: v3($0.o), direction: v3($0.d)) }
        let plain = try XCTUnwrap(ObjectRayTriangulation.leastSquares(rays))
        let robust = try XCTUnwrap(ObjectRayTriangulation.robust(rays))
        XCTAssertEqual(plain.x, f.plainXZ[0], accuracy: 1e-3)
        XCTAssertEqual(plain.y, f.plainXZ[1], accuracy: 1e-3)
        XCTAssertEqual(robust.x, f.robustXZ[0], accuracy: 1e-3)
        XCTAssertEqual(robust.y, f.robustXZ[1], accuracy: 1e-3)
        var refiner = ObjectCentreRefiner()
        rays.forEach { refiner.add($0) }
        XCTAssertEqual(refiner.arcDegrees(around: robust), f.arcDegAroundRobust, accuracy: 1.0)
    }

    func testTwoTapMatchesPythonAndRejectsWhatThePreRegisteredRulesReject() throws {
        let f = try fixture()
        var accepted = 0
        var errors: [Double] = []
        for p in f.twoTap {
            let a = ObjectRay(origin: v3(p.o1), direction: v3(p.d1))
            let b = ObjectRay(origin: v3(p.o2), direction: v3(p.d2))
            let result = ObjectTwoTap.estimate(first: a, second: b)
            if p.baselineM < ObjectTwoTap.minBaselineM || p.angleDeg < ObjectTwoTap.minConvergenceDeg {
                guard case .failure(.tooClose) = result else { XCTFail("expected tooClose for \(p.baselineM) m / \(p.angleDeg)°"); continue }
            } else if p.angleDeg > ObjectTwoTap.maxConvergenceDeg {
                guard case .failure(.tooOpposite) = result else { XCTFail("expected tooOpposite for \(p.angleDeg)°"); continue }
            } else {
                let r = try XCTUnwrap(try? result.get(), "expected a result for \(p.baselineM) m / \(p.angleDeg)°")
                XCTAssertEqual(r.point.x, p.expectedXZ[0], accuracy: 1e-4)
                XCTAssertEqual(r.point.y, p.expectedXZ[1], accuracy: 1e-4)
                accepted += 1
                errors.append(simd_length(r.point - SIMD2(f.truthXZ[0], f.truthXZ[1])))
            }
        }
        XCTAssertGreaterThan(accepted, 10)
        let median = errors.sorted()[errors.count / 2]
        XCTAssertLessThan(median, 0.12, "two taps with ~5 cm aim error land within ~12 cm of the object (median)")
    }

    /// The TF89 rule on the same real cameras: where the screen-centre ray meets the plane at the default box mid height.
    /// This is what the evidence in the design doc rests on — one view is not enough.
    func testTheOldCrosshairRuleWasOftenFarOffOnRealCameras() throws {
        let f = try fixture()
        var errs: [Double] = []
        for r in f.rays {
            let ray = ObjectRay(origin: v3(r.o), direction: v3(r.d))
            guard let p = ObjectCaptureSession.heightRulePoint(ray: ray, floorY: Float(f.floorY), centreHeight: 0.175) else { continue }
            errs.append(simd_length(p - SIMD2(f.truthXZ[0], f.truthXZ[1])))
        }
        XCTAssertGreaterThan(errs.count, 30)
        let share15 = Double(errs.filter { $0 <= 0.15 }.count) / Double(errs.count)
        XCTAssertLessThan(share15, 0.5, "fewer than half of the single-view placements were within 15 cm of the object")
    }

    // MARK: synthetic geometry

    private func orbit(around c: SIMD2<Double>, radius: Double, fromDeg: Double, toDeg: Double, steps: Int, height: Double = 1.3) -> [ObjectRay] {
        var out: [ObjectRay] = []
        for i in 0...steps {
            let fraction: Double = steps == 0 ? 0 : Double(i) / Double(steps)
            let deg: Double = fromDeg + (toDeg - fromDeg) * fraction
            let a: Double = deg * Double.pi / 180
            let ox: Double = c.x + radius * cos(a)
            let oz: Double = c.y + radius * sin(a)
            let origin = SIMD3<Double>(ox, height, oz)
            let target = SIMD3<Double>(c.x, 0.25, c.y)
            out.append(ObjectRay(origin: origin, direction: target - origin))
        }
        return out
    }

    func testRefinerFindsTheCentreAndCountsTheArc() {
        let c = SIMD2(0.4, -1.8)
        var r = ObjectCentreRefiner()
        orbit(around: c, radius: 1.3, fromDeg: 0, toDeg: 90, steps: 30).forEach { r.add($0) }
        let est = r.estimate()
        XCTAssertNotNil(est)
        XCTAssertEqual(est!.arcDeg, 90, accuracy: 1.0)
        XCTAssertLessThan(simd_length(est!.point - c), 0.01)
        XCTAssertLessThan(est!.arcDeg, ObjectCentreRefiner.freezeArcDeg)
    }

    func testRobustEstimateIgnoresRaysThatLookElsewhere() {
        let c = SIMD2(0.0, -1.5)
        var rays = orbit(around: c, radius: 1.3, fromDeg: 0, toDeg: 300, steps: 60)
        // 12 frames where the phone looked 1 m to the side
        for i in 0..<12 {
            let o = rays[i * 5].origin
            rays[i * 5] = ObjectRay(origin: o, direction: SIMD3(c.x + 1.0, 0.25, c.y) - o)
        }
        let plain = ObjectRayTriangulation.leastSquares(rays)!
        let robust = ObjectRayTriangulation.robust(rays)!
        XCTAssertLessThan(simd_length(robust - c), simd_length(plain - c) + 1e-9)
        XCTAssertLessThan(simd_length(robust - c), 0.12)
    }

    func testTwoTapNeedsAWalkAndConsistentTaps() {
        let c = SIMD2(0.0, -1.5)
        let a = orbit(around: c, radius: 1.3, fromDeg: 0, toDeg: 0, steps: 0)[0]
        let nearly = orbit(around: c, radius: 1.3, fromDeg: 8, toDeg: 8, steps: 0)[0]
        guard case .failure(.tooClose) = ObjectTwoTap.estimate(first: a, second: nearly) else { return XCTFail("8° apart is too close") }
        let good = orbit(around: c, radius: 1.3, fromDeg: 50, toDeg: 50, steps: 0)[0]
        let ok = try? ObjectTwoTap.estimate(first: a, second: good).get()
        XCTAssertNotNil(ok)
        XCTAssertLessThan(simd_length(ok!.point - c), 1e-6)
        // a second tap on something else: the lines of sight miss each other
        let elsewhere = ObjectRay(origin: good.origin, direction: SIMD3(c.x + 1.2, 0.25, c.y + 0.2) - good.origin)
        guard case .failure(.inconsistent) = ObjectTwoTap.estimate(first: a, second: elsewhere) else { return XCTFail("taps on different things must be rejected") }
    }

    // MARK: drag

    /// The TF89 drag intersected the finger ray with the floor: the box moved 1.2–1.5x as far as the object under the finger.
    func testDragOnTheBodyPlaneMovesTheBoxAsFarAsTheFinger() {
        let eye = SIMD3<Float>(0, 1.3, 0)
        func hits(planeY: Float) -> (SIMD3<Float>, SIMD3<Float>) {
            let d1 = simd_normalize(SIMD3<Float>(0, -0.64, -0.77))
            let d2 = simd_normalize(SIMD3<Float>(0.06, -0.62, -0.78))
            return (ObjectCaptureSession.supportPlaneHit(origin: eye, direction: d1, planeY: planeY)!,
                    ObjectCaptureSession.supportPlaneHit(origin: eye, direction: d2, planeY: planeY)!)
        }
        let bodyY: Float = 0.25
        let (b1, b2) = hits(planeY: bodyY)
        let (f1, f2) = hits(planeY: 0)
        let bodyMove = simd_distance(b1, b2)
        let floorMove = simd_distance(f1, f2)
        let ratio = Double(floorMove / bodyMove)
        XCTAssertEqual(ratio, ObjectDragGeometry.movementRatio(cameraHeight: 1.3, pitchDownDeg: 40, bodyHeight: 0.25, planeHeight: 0), accuracy: 0.01)
        XCTAssertGreaterThan(ratio, 1.15, "the floor plane overshoots a finger that is on the object")
        XCTAssertEqual(ObjectDragGeometry.movementRatio(cameraHeight: 1.3, pitchDownDeg: 40, bodyHeight: 0.25, planeHeight: 0.25), 1.0, accuracy: 1e-9)
    }

    func testHeightRulePointIsTheRayAtThatHeight() {
        let ray = ObjectRay(origin: SIMD3<Float>(0, 1.3, 0), direction: SIMD3<Float>(0, -0.6, -0.8))
        let p = ObjectCaptureSession.heightRulePoint(ray: ray, floorY: 0, centreHeight: 0.2)!
        XCTAssertEqual(p.x, 0, accuracy: 1e-9)
        XCTAssertEqual(p.y, -0.8 * (1.1 / 0.6), accuracy: 1e-6)
        XCTAssertNil(ObjectCaptureSession.heightRulePoint(ray: ObjectRay(origin: SIMD3<Float>(0, 1, 0), direction: SIMD3<Float>(0, 0.2, -1)), floorY: 0, centreHeight: 0.2))
    }

    // MARK: ring and trace

    func testFootprintRingCoversTheWholeFootprint() {
        let box = ObjectCaptureBox(baseCenter: [1, 0.2, 1], size: [0.4, 0.5, 0.3], yawRadians: 0.7)
        let r = ObjectFootprintRing.radius(for: box)
        XCTAssertEqual(r, 0.25, accuracy: 1e-6)
        let pts = ObjectFootprintRing.points(centre: box.baseCenter, radius: r)
        XCTAssertEqual(pts.count, 48)
        XCTAssertTrue(pts.allSatisfy { abs($0.y - 0.2) < 1e-6 })
        XCTAssertTrue(pts.allSatisfy { abs(simd_distance(SIMD2($0.x, $0.z), SIMD2(1, 1)) - r) < 1e-5 })
        for c in box.corners where abs(c.y - box.baseCenter.y) < 1e-5 {
            XCTAssertLessThanOrEqual(simd_distance(SIMD2(c.x, c.z), SIMD2(1, 1)), r + 1e-5)
        }
    }

    func testTraceKeepsPlacementEventsAndThinsSamples() throws {
        var t = ObjectPlacementTrace(appBuild: "2.0 (90)", device: "iPhone")
        t.add(0, "tap1", ["sx": 100, "sy": 200])
        for i in 0..<(ObjectPlacementTrace.maxEvents + 80) { t.add(Double(i), "sample", ["cx": Double(i)]) }
        XCTAssertLessThanOrEqual(t.events.count, ObjectPlacementTrace.maxEvents)
        XCTAssertEqual(t.events.first?.kind, "tap1")
        let data = try JSONEncoder().encode(t)
        XCTAssertEqual(try JSONDecoder().decode(ObjectPlacementTrace.self, from: data), t)
        let url = try t.write(name: "unit_test_trace.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: url)
    }

    func testObjectJsonCarriesThePlacementTrace() throws {
        var t = ObjectPlacementTrace(appBuild: "2.0 (90)", device: "iPhone")
        t.add(1, "located", ["bx": 0.1], ["source": "two_tap_triangulation"])
        let file = ObjectCaptureFile.make(
            box: ObjectCaptureBox(baseCenter: [0, 0, -1], size: [0.4, 0.5, 0.4], yawRadians: 0),
            centerSource: "two_tap_triangulation", sizeSource: "default", coverage: ObjectOrbitCoverage(), frames: [],
            hasLiDAR: false, placementTrace: t
        )
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as! [String: Any]
        XCTAssertNotNil(json["placementTrace"])
        XCTAssertEqual((json["object"] as! [String: Any])["centerSource"] as? String, "two_tap_triangulation")
    }
}
