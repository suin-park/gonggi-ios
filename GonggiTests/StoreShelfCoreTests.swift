import XCTest
@testable import Gonggi

/// Pure logic of the 매장 feature (geometry, duplicate merging, matching, walkable route, alignment, guidance).
/// Foundation only: the same file runs on Linux (Tools/StoreShelfLogicCheck) and in the app's unit tests.
final class StoreShelfCoreTests: XCTestCase {
    // MARK: Helpers

    private func appearance(_ a: [Float], color: [Float]? = nil) -> ShelfAppearance {
        ShelfAppearance(embedding: a, color: color ?? [])
    }

    /// A camera at `position` looking along -Z (identity rotation) with a 1000 px focal length, 1000x1000 sensor.
    private func camera(at position: Vec3, rotation: Rigid? = nil) -> StoreCameraModel {
        let pose = (rotation ?? .identity).multiplied(by: .identity)
        var m = pose.m
        m[12] = position.x
        m[13] = position.y
        m[14] = position.z
        return StoreCameraModel(fx: 1000, fy: 1000, cx: 500, cy: 500, width: 1000, height: 1000, cameraToWorld: Rigid(floats: m)!)
    }

    private func frontPlane() -> ShelfPlane {
        // Shelf front at z = -2, left (-1, 0) to right (+1, 0), customer at the origin.
        ShelfPlane.fromBaseline(a: Vec3(-1, 0, -2), b: Vec3(1, 0, -2), viewer: Vec3(0, 1.4, 0))!
    }

    // MARK: Rigid / camera

    func testRigidInverseAndMultiply() {
        let t = Rigid.yaw(0.7, translation: Vec3(1, 2, 3))
        let p = Vec3(0.4, -1, 2)
        let back = t.inverse().apply(point: t.apply(point: p))
        XCTAssertEqual(back.x, p.x, accuracy: 1e-5)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-5)
        XCTAssertEqual(back.z, p.z, accuracy: 1e-5)
        let id = t.multiplied(by: t.inverse())
        XCTAssertEqual(id.translationPart.length, 0, accuracy: 1e-5)
        XCTAssertEqual(id.rotationAngle, 0, accuracy: 1e-3)
        XCTAssertEqual(Rigid.yaw(0.5).rotationAngle, 0.5, accuracy: 1e-4)
        XCTAssertNil(Rigid(floats: [1, 2, 3]))
    }

    func testPixelRayAndProjectionRoundTrip() {
        let cam = StoreCameraModel(fx: 1400, fy: 1400, cx: 960, cy: 720, width: 1920, height: 1440,
                                   cameraToWorld: Rigid.yaw(0.4, translation: Vec3(0.5, 1.3, 0.2)))
        let ray = cam.ray(throughPixel: 1200, 300)!
        let world = ray.origin + ray.direction * 3.2
        let px = cam.project(world)!
        XCTAssertEqual(px.u, 1200, accuracy: 0.05)
        XCTAssertEqual(px.v, 300, accuracy: 0.05)
        XCTAssertEqual(px.depth, 3.2 * cam.cameraToWorld.cameraForward.dot(ray.direction), accuracy: 0.01)
        XCTAssertNil(cam.project(cam.position - cam.cameraToWorld.cameraForward * 2), "behind the camera")
    }

    func testVisionBoxFlipAndUprightMapping() {
        // Vision: origin bottom-left. A box in the TOP-left of the image has a large y.
        let r = StoreImageSpace.sensorRect(fromVision: 0.1, y: 0.7, w: 0.2, h: 0.2, imageWidth: 1000, imageHeight: 500)
        XCTAssertEqual(r.minU, 100, accuracy: 1e-3)
        XCTAssertEqual(r.maxU, 300, accuracy: 1e-3)
        XCTAssertEqual(r.minV, 50, accuracy: 1e-3)
        XCTAssertEqual(r.maxV, 150, accuracy: 1e-3)
        // Upright image = sensor rotated 90 deg clockwise: sensor top-left (0,0) -> upright top-right.
        let sensorH: Float = 500
        let up = StoreImageSpace.uprightPixel(fromSensor: 0, 0, sensorHeight: sensorH)
        XCTAssertEqual(up.x, sensorH, accuracy: 1e-4)
        XCTAssertEqual(up.y, 0, accuracy: 1e-4)
        let s = StoreImageSpace.sensorPixel(fromUpright: up.x, up.y, sensorHeight: sensorH)
        XCTAssertEqual(s.u, 0, accuracy: 1e-4)
        XCTAssertEqual(s.v, 0, accuracy: 1e-4)
        for (u, v) in [(10 as Float, 20 as Float), (900, 480), (333, 12)] {
            let a = StoreImageSpace.uprightPixel(fromSensor: u, v, sensorHeight: sensorH)
            let b = StoreImageSpace.sensorPixel(fromUpright: a.x, a.y, sensorHeight: sensorH)
            XCTAssertEqual(b.u, u, accuracy: 1e-4)
            XCTAssertEqual(b.v, v, accuracy: 1e-4)
        }
    }

    // MARK: Shelf plane and position estimation

    func testPlaneFacesTheViewerWhateverTheTapOrder() {
        let viewer = Vec3(0, 1.4, 0)
        let a = Vec3(-1, 0, -2), b = Vec3(1, 0, -2)
        let p1 = ShelfPlane.fromBaseline(a: a, b: b, viewer: viewer)!
        let p2 = ShelfPlane.fromBaseline(a: b, b: a, viewer: viewer)!
        for p in [p1, p2] {
            XCTAssertGreaterThan(p.normal.dot(viewer - a), 0)
            XCTAssertEqual(p.normal.z, 1, accuracy: 1e-5)
            XCTAssertEqual(p.uAxis.x, 1, accuracy: 1e-5, "u runs left to right as the customer sees it")
            XCTAssertEqual(p.uAxis.cross(Vec3.up).dot(p.normal), 1, accuracy: 1e-5, "(u, v, n) right-handed")
        }
        XCTAssertEqual(p1.origin, Vec3(-1, 0, -2))
        XCTAssertEqual(p2.origin, Vec3(-1, 0, -2), "origin is the left end in both orders")
        XCTAssertNil(ShelfPlane.fromBaseline(a: a, b: a + Vec3(0.05, 0, 0), viewer: viewer), "too short")
        XCTAssertNil(ShelfPlane.fromBaseline(a: a, b: a + Vec3(0, 2, 0), viewer: viewer), "vertical pair has no direction")
    }

    func testPositionEstimateHitsTheKnownPoint() {
        let plane = frontPlane()
        let cam = camera(at: Vec3(0, 1.4, 0))
        // World point on the shelf: u = 1.5 (0.5 right of centre), v = 0.8.
        let target = plane.worldPoint(u: 1.5, v: 0.8)
        let px = cam.project(target)!
        let fix = ShelfPositionEstimator.estimate(plane: plane, camera: cam, pixelU: px.u, pixelV: px.v)!
        XCTAssertEqual(fix.u, 1.5, accuracy: 1e-3)
        XCTAssertEqual(fix.v, 0.8, accuracy: 1e-3)
        XCTAssertEqual(fix.world.distance(to: target), 0, accuracy: 1e-3)
        XCTAssertEqual(fix.distance, (0.5 * 0.5 + 0.6 * 0.6 + 4).squareRoot(), accuracy: 0.01)
        XCTAssertGreaterThan(fix.uncertaintyM, 0)
    }

    func testNoFixWithoutDistanceEvidence() {
        let plane = frontPlane()
        // A ray almost parallel to the plane (about 5.7 degrees): refused for its angle even when the distance is allowed.
        let th: Float = -.pi / 2 + 0.1
        let grazing = camera(at: Vec3(-10, 1.4, 0), rotation: Rigid.yaw(th))
        XCTAssertNil(ShelfPositionEstimator.estimate(plane: plane, camera: grazing, pixelU: 500, pixelV: 500))
        var wide = ShelfPositionEstimator.Limits()
        wide.maxDistance = 100
        XCTAssertNil(ShelfPositionEstimator.estimate(plane: plane, camera: grazing, pixelU: 500, pixelV: 500, limits: wide))
        wide.minCosIncidence = 0.05
        XCTAssertNotNil(ShelfPositionEstimator.estimate(plane: plane, camera: grazing, pixelU: 500, pixelV: 500, limits: wide),
                        "only the angle limit was in the way")
        // Beyond the maximum distance.
        let far = camera(at: Vec3(0, 1.4, 7))
        XCTAssertNil(ShelfPositionEstimator.estimate(plane: plane, camera: far, pixelU: 500, pixelV: 500))
        // Looking away from the shelf: the plane is behind the camera.
        let away = camera(at: Vec3(0, 1.4, -5))
        XCTAssertNil(ShelfPositionEstimator.estimate(plane: plane, camera: away, pixelU: 500, pixelV: 500))
        // Above the shelf height limit.
        let px = camera(at: Vec3(0, 1.4, 0)).project(plane.worldPoint(u: 1, v: 5))
        if let px {
            XCTAssertNil(ShelfPositionEstimator.estimate(plane: plane, camera: camera(at: Vec3(0, 1.4, 0)), pixelU: px.u, pixelV: px.v))
        }
    }

    func testPhysicalSize() {
        let cam = camera(at: .zero)
        let s = ShelfPositionEstimator.physicalSize(pixelWidth: 100, pixelHeight: 250, distance: 2, camera: cam)
        XCTAssertEqual(s.w, 0.2, accuracy: 1e-5)
        XCTAssertEqual(s.h, 0.5, accuracy: 1e-5)
    }

    // MARK: Image statistics, NMS

    func testSharpnessSeparatesBlurFromEdges() {
        let w = 32, h = 32
        var blurry = [UInt8](repeating: 128, count: w * h)
        var sharp = blurry
        for y in 0..<h {
            for x in 0..<w {
                blurry[y * w + x] = UInt8(100 + x)                  // smooth ramp
                sharp[y * w + x] = ((x / 4 + y / 4) % 2 == 0) ? 20 : 235  // checker
            }
        }
        XCTAssertLessThan(StoreImageStats.laplacianVariance(luma: blurry, width: w, height: h), 1)
        XCTAssertGreaterThan(StoreImageStats.laplacianVariance(luma: sharp, width: w, height: h), 1000)
        XCTAssertEqual(StoreImageStats.laplacianVariance(luma: [1, 2], width: 1, height: 2), 0)
    }

    func testColorDescriptorDistinguishesColours() {
        func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> [Float] {
            StoreImageStats.colorDescriptor(rgba: (0..<64).flatMap { _ in [r, g, b, 255] }, width: 8, height: 8)
        }
        let red = solid(220, 30, 30), red2 = solid(200, 40, 35), blue = solid(30, 40, 220), grey = solid(120, 120, 120)
        XCTAssertEqual(red.reduce(0, +), 1, accuracy: 1e-4)
        XCTAssertLessThan(StoreVectorMath.histogramDistance(red, red2)!, 0.1)
        XCTAssertGreaterThan(StoreVectorMath.histogramDistance(red, blue)!, 0.9)
        XCTAssertGreaterThan(StoreVectorMath.histogramDistance(red, grey)!, 0.9)
    }

    func testNMSKeepsTheBestAndDropsContainedBoxes() {
        func r(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> StoreImageSpace.PixelRect {
            StoreImageSpace.PixelRect(minU: a, minV: b, maxU: c, maxV: d)
        }
        let items: [(rect: StoreImageSpace.PixelRect, score: Float)] = [
            (r(0, 0, 100, 100), 0.9),      // 0 best
            (r(5, 5, 100, 105), 0.8),      // 1 heavy overlap -> dropped
            (r(20, 20, 60, 60), 0.7),      // 2 inside 0 -> dropped
            (r(200, 0, 300, 100), 0.6),    // 3 separate -> kept
        ]
        XCTAssertEqual(StoreRegionNMS.suppress(items), [0, 3])
    }

    // MARK: Vector math and matching

    func testCosineDistance() {
        XCTAssertEqual(StoreVectorMath.cosineDistance([1, 0], [1, 0])!, 0, accuracy: 1e-6)
        XCTAssertEqual(StoreVectorMath.cosineDistance([1, 0], [0, 1])!, 1, accuracy: 1e-6)
        XCTAssertEqual(StoreVectorMath.cosineDistance([1, 0], [-1, 0])!, 2, accuracy: 1e-6)
        XCTAssertNil(StoreVectorMath.cosineDistance([], []))
        XCTAssertNil(StoreVectorMath.cosineDistance([0, 0], [1, 0]))
        XCTAssertNil(StoreVectorMath.cosineDistance([1], [1, 2]))
    }

    func testVectorBase64RoundTrip() {
        let v: [Float] = [0, 1.5, -2.25, 3.14159, 1e-7, 12345.678]
        XCTAssertEqual(StoreVector(v).values, v)
        XCTAssertEqual(StoreVector([]).values, [])
        XCTAssertEqual(StoreVector(base64: "not base64!!").values, [])
    }

    private var gallery: [(productId: String, appearances: [ShelfAppearance])] {
        [("cola", [appearance([1, 0, 0], color: [1, 0, 0, 0])]),
         ("cola-zero", [appearance([0.97, 0.25, 0], color: [0.9, 0, 0, 0.1])]),
         ("juice", [appearance([0, 1, 0], color: [0, 1, 0, 0])])]
    }

    func testMatchedWhenClearWinner() {
        let q = appearance([0.0, 0.98, 0.1], color: [0, 1, 0, 0])
        guard case .matched(let c) = ShelfProductMatcher.match(query: q, gallery: gallery) else { return XCTFail("expected match") }
        XCTAssertEqual(c.productId, "juice")
    }

    func testLookAlikeIsUncertainNotForcedToOne() {
        // Between cola and cola-zero: both close, margin too small.
        let q = appearance([0.99, 0.12, 0], color: [0.95, 0, 0, 0.05])
        let out = ShelfProductMatcher.match(query: q, gallery: gallery)
        guard case .uncertain(let list) = out else { return XCTFail("expected uncertain, got \(out)") }
        XCTAssertEqual(Set(list.map(\.productId)), ["cola", "cola-zero"])
        XCTAssertLessThanOrEqual(list.count, 3)
    }

    func testUnregisteredProductIsNotForcedToNearest() {
        let q = appearance([0, 0, 1], color: [0, 0, 1, 0])
        guard case .unregistered(let best) = ShelfProductMatcher.match(query: q, gallery: gallery) else { return XCTFail() }
        XCTAssertNotNil(best)
        XCTAssertEqual(ShelfProductMatcher.match(query: q, gallery: []), .noGallery)
        XCTAssertEqual(ShelfProductMatcher.match(query: appearance([]), gallery: gallery), .noGallery, "no usable appearance")
    }

    func testStabilizerNeedsAMajority() {
        var s = ShelfMatchStabilizer(window: 5, required: 3)
        let a = ShelfMatchOutcome.matched(ShelfMatchCandidate(productId: "a", distance: 0.1))
        let b = ShelfMatchOutcome.unregistered(bestDistance: 0.9)
        s.add(a); s.add(b); s.add(a)
        XCTAssertNil(s.stable)
        s.add(a)
        XCTAssertEqual(s.stable?.key, "m:a")
        s.add(b); s.add(b)
        XCTAssertEqual(s.stable?.key, "x", "window is now [b, a, a, b, b]: b has the majority")
        s.reset()
        XCTAssertNil(s.stable)
    }

    func testThresholdCalibrator() {
        let same: [Float] = [0.02, 0.04, 0.05, 0.06, 0.08, 0.09, 0.1, 0.11, 0.12, 0.15]
        let different: [Float] = [0.4, 0.5, 0.55, 0.6, 0.7, 0.75, 0.8, 0.9, 0.95, 1.0]
        let r = StoreThresholdCalibrator.calibrate(same: same, different: different)!
        XCTAssertTrue(r.separable)
        XCTAssertLessThan(r.matchMax, r.uncertainMax)
        XCTAssertGreaterThanOrEqual(r.sameRecall, 0.9)
        XCTAssertNil(StoreThresholdCalibrator.calibrate(same: [0.1], different: [0.5]), "too little data")
    }

    // MARK: Aggregation (duplicates, variants, blur, few observations)

    private func obs(u: Float, v: Float, look: [Float], sharp: Float = 200, t: Double = 0, w: Float = 0.1,
                     unc: Float = 0.02, ref: String = "c") -> ShelfObservation {
        ShelfObservation(time: t, u: u, v: v, world: Vec3(u, v, -2), uncertaintyM: unc, widthM: w, heightM: 0.2,
                         appearance: appearance(look, color: look), sharpness: sharp, cropRef: ref)
    }

    func testDuplicateDetectionsAcrossFramesBecomeOneProduct() {
        var agg = ShelfObservationAggregator()
        for i in 0..<6 {
            agg.add(obs(u: 1.00 + Float(i) * 0.004, v: 0.80, look: [1, 0, 0, 0], t: Double(i), ref: "a\(i)"))
        }
        let res = agg.finalize()
        XCTAssertEqual(res.candidates.count, 1)
        XCTAssertEqual(res.candidates[0].observationCount, 6)
        XCTAssertEqual(res.candidates[0].u, 1.01, accuracy: 0.01)
        XCTAssertTrue(res.rejected.isEmpty)
    }

    func testTwoProductsSideBySideStayApart() {
        var agg = ShelfObservationAggregator()
        for i in 0..<4 {
            agg.add(obs(u: 0.5, v: 0.8, look: [1, 0, 0, 0], t: Double(i)))
            agg.add(obs(u: 0.9, v: 0.8, look: [1, 0, 0, 0], t: Double(i)))   // same look, 0.4 m away: a second facing
        }
        XCTAssertEqual(agg.finalize().candidates.count, 2)
    }

    func testDifferentLookAtTheSamePlaceIsKeptSeparateAndFlagged() {
        var agg = ShelfObservationAggregator()
        for i in 0..<4 {
            agg.add(obs(u: 0.5, v: 0.8, look: [1, 0, 0, 0], t: Double(i)))
        }
        for i in 0..<4 {
            agg.add(obs(u: 0.51, v: 0.8, look: [0, 0, 0, 1], t: Double(i)))   // another product occluding / overlapping
        }
        let c = agg.finalize().candidates
        XCTAssertEqual(c.count, 2)
        XCTAssertTrue(c.contains { $0.reviewReasons.contains("다른 제품과 겹쳐 보여요") })
    }

    func testBlurryAndBriefRegionsAreRejectedWithReasons() {
        var agg = ShelfObservationAggregator()
        for i in 0..<5 { agg.add(obs(u: 0.2, v: 0.5, look: [1, 0, 0, 0], sharp: 5, t: Double(i))) }          // blurry
        for i in 0..<2 { agg.add(obs(u: 1.8, v: 0.5, look: [0, 1, 0, 0], sharp: 300, t: Double(i))) }        // seen twice
        for i in 0..<4 { agg.add(obs(u: 1.0, v: 0.5, look: [0, 0, 1, 0], sharp: 300, t: Double(i))) }        // fine
        let res = agg.finalize()
        XCTAssertEqual(res.candidates.count, 1)
        XCTAssertEqual(Set(res.rejected.map(\.reason)), [.blurry, .tooFewObservations])
    }

    func testUncertainPositionIsKeptButFlagged() {
        var agg = ShelfObservationAggregator()
        for i in 0..<4 { agg.add(obs(u: 0.2, v: 0.5, look: [1, 0, 0, 0], t: Double(i), unc: 0.3)) }
        let c = agg.finalize().candidates
        XCTAssertEqual(c.count, 1)
        XCTAssertTrue(c[0].needsReview)
        XCTAssertTrue(c[0].reviewReasons.contains("위치가 불확실해요"))
    }

    // MARK: Grouping, applying a recording, re-recording

    private func candidate(u: Float, v: Float, look: [Float], count: Int = 5) -> ShelfCandidate {
        ShelfCandidate(u: u, v: v, widthM: 0.1, heightM: 0.2, uncertaintyM: 0.03, observationCount: count, firstTime: 0,
                       lastTime: 1, medianSharpness: 200, appearances: [appearance(look, color: look)], cropRefs: ["c"],
                       world: Vec3(u, v, -2), needsReview: false, reviewReasons: [])
    }

    private func shelf() -> ShelfLayout {
        ShelfLayout(id: "s1", name: "매대 1", plane: frontPlane(), tierBoundaries: [0.5, 1.0], createdAt: Date(timeIntervalSince1970: 0),
                    updatedAt: Date(timeIntervalSince1970: 0), photoFileName: nil)
    }

    private func naming() -> ShelfDataUpdater.Naming {
        var p = 0, q = 0
        return ShelfDataUpdater.Naming(newProductId: { p += 1; return "prod\(p)" }, newPlacementId: { q += 1; return "pl\(q)" },
                                       productName: { "제품 \($0)" })
    }

    func testSameProductInTwoPlacesIsOneProductWithTwoPositions() {
        let cands = [candidate(u: 0.5, v: 0.3, look: [1, 0, 0, 0]), candidate(u: 1.7, v: 1.3, look: [1, 0.01, 0, 0]),
                     candidate(u: 1.1, v: 0.3, look: [0, 1, 0, 0])]
        let groups = ShelfProductGrouper.group(cands)
        XCTAssertEqual(groups.count, 2)
        let big = groups.first { $0.candidateIndices.count == 2 }!
        XCTAssertEqual(Set(big.candidateIndices), [0, 1])
        let r = ShelfDataUpdater.apply(candidates: cands, groups: groups, cropFileNames: [["a.jpg"], ["b.jpg"], ["c.jpg"]],
                                       shelf: shelf(), coverage: ShelfRecordingCoverage(minU: 0, maxU: 3, minV: 0, maxV: 2),
                                       now: Date(timeIntervalSince1970: 100), to: StoreShelfData.empty(storeId: "st"), naming: naming())
        XCTAssertEqual(r.data.products.count, 2)
        XCTAssertEqual(r.data.placements.count, 3)
        let multi = r.data.products.first { r.data.placements(ofProduct: $0.id).count == 2 }!
        XCTAssertEqual(Set(r.data.placements(ofProduct: multi.id).map(\.tier)), [0, 2])
        XCTAssertEqual(r.summary.newProducts, 2)
    }

    func testLookAlikeVariantsAreSeparateProductsFlaggedForReview() {
        let cands = [candidate(u: 0.5, v: 0.3, look: [1, 0, 0, 0]), candidate(u: 0.9, v: 0.3, look: [0.78, 0.55, 0, 0])]
        let groups = ShelfProductGrouper.group(cands, thresholds: .init(sameMax: 0.1, similarMax: 0.5))
        XCTAssertEqual(groups.count, 2)
        XCTAssertFalse(groups[0].similarGroups.isEmpty)
        let r = ShelfDataUpdater.apply(candidates: cands, groups: groups, cropFileNames: [["a.jpg"], ["b.jpg"]], shelf: shelf(),
                                       coverage: ShelfRecordingCoverage(minU: 0, maxU: 3, minV: 0, maxV: 2),
                                       now: Date(), to: StoreShelfData.empty(storeId: "st"), naming: naming(),
                                       thresholds: .init(sameMax: 0.1, similarMax: 0.5))
        XCTAssertEqual(r.data.products.count, 2)
        XCTAssertTrue(r.data.products.allSatisfy { $0.needsReview && $0.similarProductIds.count == 1 })
    }

    func testRerecordingUpdatesMovesAndMarksMissing() {
        let t0 = Date(timeIntervalSince1970: 100), t1 = Date(timeIntervalSince1970: 500)
        let first = [candidate(u: 0.5, v: 0.3, look: [1, 0, 0, 0]), candidate(u: 1.1, v: 0.3, look: [0, 1, 0, 0]),
                     candidate(u: 2.0, v: 0.3, look: [0, 0, 1, 0])]
        let g1 = ShelfProductGrouper.group(first)
        var data = ShelfDataUpdater.apply(candidates: first, groups: g1, cropFileNames: [["a"], ["b"], ["c"]], shelf: shelf(),
                                          coverage: ShelfRecordingCoverage(minU: 0, maxU: 3, minV: 0, maxV: 2), now: t0,
                                          to: StoreShelfData.empty(storeId: "st"), naming: naming()).data
        XCTAssertEqual(data.placements.count, 3)
        // Re-record: product 0 stays (slightly shifted), product 1 moved to u = 1.5, product 2 gone, one new product.
        let second = [candidate(u: 0.52, v: 0.3, look: [1, 0, 0, 0]), candidate(u: 1.5, v: 0.3, look: [0, 1, 0, 0]),
                      candidate(u: 2.5, v: 0.3, look: [0.5, 0.5, 0.5, 0.5])]
        var n = 100
        let nm = ShelfDataUpdater.Naming(newProductId: { n += 1; return "p\(n)" }, newPlacementId: { n += 1; return "q\(n)" }, productName: { "제품 \($0)" })
        let r = ShelfDataUpdater.apply(candidates: second, groups: ShelfProductGrouper.group(second), cropFileNames: [["a2"], ["b2"], ["d"]],
                                       shelf: shelf(), coverage: ShelfRecordingCoverage(minU: 0, maxU: 3, minV: 0, maxV: 2), now: t1,
                                       to: data, naming: nm)
        data = r.data
        XCTAssertEqual(r.summary.updatedPlacements, 1)
        XCTAssertEqual(r.summary.newPlacements, 2, "the moved product and the new one")
        XCTAssertEqual(r.summary.markedNotObserved, 2, "old position of the moved product, and the gone one")
        XCTAssertEqual(data.products.count, 4, "three originals (the moved one keeps its identity) and one new product")
        let stayed = data.placements.first { abs($0.u - 0.5) < 0.1 }!
        XCTAssertEqual(stayed.lastObservedAt, t1)
        XCTAssertEqual(stayed.status, .present)
        XCTAssertEqual(data.placements.filter { $0.status == .notObservedOnRescan }.count, 2)
        XCTAssertEqual(data.placements.count, 5, "nothing is deleted automatically")
    }

    func testTierClustering() {
        let b = ShelfTierClustering.boundaries(heights: [0.30, 0.32, 0.31, 0.95, 0.97, 1.60, 1.62])
        XCTAssertEqual(b.count, 2)
        XCTAssertEqual(b[0], 0.625, accuracy: 0.05)
        XCTAssertTrue(ShelfTierClustering.boundaries(heights: [0.3]).isEmpty)
        XCTAssertEqual(shelf().tier(forV: 0.3), 0)
        XCTAssertEqual(shelf().tier(forV: 0.7), 1)
        XCTAssertEqual(shelf().tier(forV: 1.4), 2)
        XCTAssertEqual(shelf().tierLabel(forV: 1.4), "3번째 칸")
    }

    func testPlacementChooserPrefersPresentAndNearest() {
        func pl(_ id: String, x: Float, status: ShelfPlacementStatus) -> ShelfPlacement {
            ShelfPlacement(id: id, productId: "p", shelfId: "s", u: 0, v: 0, tier: 0, world: Vec3(x, 1, 0), widthM: 0.1, heightM: 0.2,
                           uncertaintyM: 0.02, observationCount: 3, firstObservedAt: Date(), lastObservedAt: Date(), status: status, needsReview: false)
        }
        let cam = Vec3(0, 1.4, 0)
        let list = [pl("far", x: 6, status: .present), pl("near-missing", x: 1, status: .notObservedOnRescan), pl("mid", x: 3, status: .present)]
        XCTAssertEqual(ShelfPlacementChooser.nearest(list, to: cam)?.id, "mid")
        XCTAssertEqual(ShelfPlacementChooser.nearest([list[1]], to: cam)?.id, "near-missing")
        XCTAssertNil(ShelfPlacementChooser.nearest([], to: cam))
        // A transform moves the saved coordinates before the distance is taken.
        XCTAssertEqual(ShelfPlacementChooser.nearest(list, to: cam, transform: Rigid.translation(Vec3(-6, 0, 0)))?.id, "far")
    }

    // MARK: Walkable route

    func testRouteGoesAroundTheShelfAndNeverThroughIt() {
        // A shelf block in the middle (x in [-1, 1], z in [-0.3, 0.3]); the walked trail loops around it.
        let obstacle = ShelfObstacle(corners: [FloorPoint(x: -1, z: -0.3), FloorPoint(x: 1, z: -0.3),
                                               FloorPoint(x: 1, z: 0.3), FloorPoint(x: -1, z: 0.3)])
        var trail: [FloorPoint] = []
        let loop: [(Float, Float)] = [(-2, 1.2), (2, 1.2), (2, -1.2), (-2, -1.2), (-2, 1.2)]
        for i in 0..<(loop.count - 1) {
            let a = loop[i], b = loop[i + 1]
            for k in 0...20 {
                let t = Float(k) / 20
                trail.append(FloorPoint(x: a.0 + (b.0 - a.0) * t, z: a.1 + (b.1 - a.1) * t))
            }
        }
        let map = StoreWalkableMap.build(trail: trail, obstacles: [obstacle])!
        let from = FloorPoint(x: 0, z: 1.2), to = FloorPoint(x: 0, z: -1.2)
        let route = map.route(from: from, to: to)!
        XCTAssertFalse(map.crossesObstacle(route))
        XCTAssertGreaterThan(StoreRouteProgress.length(route), 4.0, "straight line is 2.4 m; the detour is longer")
        XCTAssertLessThan(StoreRouteProgress.length(route), 9)
        // The straight segment would cross the shelf; this is exactly what the route must not do.
        XCTAssertTrue(map.crossesObstacle([from, to]))
    }

    func testNoRouteFromOrToUnwalkedSpace() {
        let trail = (0...20).map { FloorPoint(x: Float($0) * 0.1, z: 0) }
        let map = StoreWalkableMap.build(trail: trail, obstacles: [])!
        XCTAssertNotNil(map.route(from: FloorPoint(x: 0, z: 0), to: FloorPoint(x: 2, z: 0)))
        XCTAssertNil(map.route(from: FloorPoint(x: 0, z: 0), to: FloorPoint(x: 2, z: 8)), "nobody walked there")
        XCTAssertNil(StoreWalkableMap.build(trail: [FloorPoint(x: 0, z: 0)], obstacles: []), "one sample is no trail")
    }

    func testDisconnectedTrailsGiveNoRoute() {
        var trail: [FloorPoint] = (0...10).map { FloorPoint(x: Float($0) * 0.2, z: 0) }
        trail += (0...10).map { FloorPoint(x: Float($0) * 0.2, z: 6) }
        let map = StoreWalkableMap.build(trail: trail, obstacles: [])!
        XCTAssertNil(map.route(from: FloorPoint(x: 0, z: 0), to: FloorPoint(x: 1, z: 6)))
    }

    func testTrailRecorderThinsSamples() {
        var rec = StoreTrailRecorder(minStep: 0.2)
        for i in 0..<100 { rec.add(position: Vec3(Float(i) * 0.01, 1.4, 0), time: Double(i)) }
        XCTAssertTrue((4...6).contains(rec.samples.count), "one sample per ~0.2 m over about 1 m, got \(rec.samples.count)")
        XCTAssertEqual(StoreTrailRecorder.floorY(detectedHorizontalPlaneHeights: [0.02, 0.9, -0.01]), -0.01)
        XCTAssertNil(StoreTrailRecorder.floorY(detectedHorizontalPlaneHeights: []))
    }

    func testRouteProgress() {
        let path = [FloorPoint(x: 0, z: 0), FloorPoint(x: 2, z: 0), FloorPoint(x: 2, z: 2)]
        XCTAssertEqual(StoreRouteProgress.remaining(path, position: FloorPoint(x: 0.1, z: 0)).count, 2)
        XCTAssertEqual(StoreRouteProgress.remaining(path, position: FloorPoint(x: 1.0, z: 0.1), reach: 0.5).count, 3, "not at a waypoint yet")
        XCTAssertEqual(StoreRouteProgress.remaining(path, position: FloorPoint(x: 1.8, z: 0.1), reach: 0.5).count, 1, "passed the corner")
        XCTAssertEqual(StoreRouteProgress.length(path), 4, accuracy: 1e-5)
    }

    // MARK: Alignment

    func testAlignmentNeedsAMapOrASign() {
        XCTAssertEqual(StoreSpaceAlignment.decide(worldMapRestored: false, imageObservation: nil), .failed(.notRestored))
        let s = StoreSpaceAlignment.decide(worldMapRestored: true, imageObservation: nil)
        XCTAssertEqual(s.transform, .identity)
        XCTAssertTrue(s.isAligned)
        XCTAssertNil(StoreAlignmentState.restoring.transform, "nothing is drawn while restoring")
        XCTAssertNil(StoreAlignmentState.failed(.notRestored).transform)
    }

    func testReferenceImageRealignsASessionWithoutAMap() {
        // The session origin moved: the world is rotated 30 degrees and shifted. The sign is where the map says, plus that move.
        let saved = Rigid.yaw(0.2, translation: Vec3(2, 1, -3))
        let move = Rigid.yaw(0.52, translation: Vec3(-1, 0, 0.5))
        let live = move.multiplied(by: saved)
        let obs = StoreReferenceImageObservation(savedPose: saved, livePose: live)
        let state = StoreSpaceAlignment.decide(worldMapRestored: false, imageObservation: obs)
        guard case .aligned(let method, let t, let verified, let disagrees) = state else { return XCTFail() }
        XCTAssertEqual(method, .referenceImage)
        XCTAssertTrue(verified)
        XCTAssertFalse(disagrees)
        // A saved shelf point lands where the move put it.
        let p = Vec3(0.3, 0.8, -2.2)
        let expected = move.apply(point: p)
        let got = t.apply(point: p)
        XCTAssertEqual(got.distance(to: expected), 0, accuracy: 1e-4)
    }

    func testMapAndSignAgreeOrDisagree() {
        let saved = Rigid.yaw(0.1, translation: Vec3(1, 1, -1))
        let agreeing = StoreReferenceImageObservation(savedPose: saved, livePose: Rigid.translation(Vec3(0.05, 0, 0)).multiplied(by: saved))
        guard case .aligned(let m1, let t1, _, let d1) = StoreSpaceAlignment.decide(worldMapRestored: true, imageObservation: agreeing) else { return XCTFail() }
        XCTAssertEqual(m1, .worldMap)
        XCTAssertEqual(t1, .identity)
        XCTAssertFalse(d1)
        let off = StoreReferenceImageObservation(savedPose: saved, livePose: Rigid.translation(Vec3(0.8, 0, 0)).multiplied(by: saved))
        guard case .aligned(let m2, _, _, let d2) = StoreSpaceAlignment.decide(worldMapRestored: true, imageObservation: off) else { return XCTFail() }
        XCTAssertEqual(m2, .referenceImage)
        XCTAssertTrue(d2, "a map that disagrees with the physical sign is reported")
    }

    // MARK: Guidance

    func testBearingLeftRightBehind() {
        // Camera at origin looking down -Z.
        let cam = Rigid.identity
        XCTAssertEqual(StoreGuidanceMath.bearing(camera: cam, target: Vec3(0, 0, -5))!.rightDegrees, 0, accuracy: 0.1)
        XCTAssertEqual(StoreGuidanceMath.bearing(camera: cam, target: Vec3(3, 0, 0))!.rightDegrees, 90, accuracy: 0.1)
        XCTAssertEqual(StoreGuidanceMath.bearing(camera: cam, target: Vec3(-3, 0, 0))!.rightDegrees, -90, accuracy: 0.1)
        XCTAssertEqual(abs(StoreGuidanceMath.bearing(camera: cam, target: Vec3(0, 0, 4))!.rightDegrees), 180, accuracy: 0.1)
        XCTAssertEqual(StoreGuidanceMath.bearing(camera: cam, target: Vec3(0, 0, -5))!.distance, 5, accuracy: 1e-4)
        // Turned 90 degrees left: the old forward target is now on the right.
        let left = Rigid.yaw(.pi / 2)
        XCTAssertEqual(StoreGuidanceMath.bearing(camera: left, target: Vec3(0, 0, -5))!.rightDegrees, 90, accuracy: 0.5)
    }

    func testTierBandAndStandPoint() {
        let plane = frontPlane()
        let r = StoreGuidanceMath.tierRange(boundaries: [0.5, 1.0], tier: 1)
        XCTAssertEqual(r.lowerBound, 0.5, accuracy: 1e-5)
        XCTAssertEqual(r.upperBound, 1.0, accuracy: 1e-5)
        let corners = StoreGuidanceMath.tierBandCorners(plane: plane, uRange: 0.2...1.2, vRange: r)
        XCTAssertEqual(corners.count, 4)
        XCTAssertTrue(corners.allSatisfy { abs(plane.coordinates(of: $0).offset) < 1e-5 })
        let stand = StoreGuidanceMath.standPoint(placementWorld: plane.worldPoint(u: 1, v: 0.7), plane: plane, distance: 0.9)
        XCTAssertEqual(plane.coordinates(of: stand).offset, 0.9, accuracy: 1e-5)
        XCTAssertEqual(StoreGuidanceKind.straightDirection.userLabel, "직선 방향 안내")
        XCTAssertEqual(StoreGuidanceKind.walkableRoute(waypoints: []).userLabel, "통로 경로 안내")
    }

    func testShelfDataCodableRoundTrip() throws {
        var data = StoreShelfData.empty(storeId: "st")
        data.shelves = [shelf()]
        data.products = [ShelfProduct(id: "p", name: "제품 1", createdAt: Date(timeIntervalSince1970: 5), imageFileNames: ["a.jpg"],
                                      embeddings: [StoreVector([1, 2, 3])], colorDescriptors: [StoreVector([0.5, 0.5])],
                                      similarProductIds: [], needsReview: false, reviewReasons: [])]
        data.walkTrail = [ShelfWalkSample(x: 1, y: 1.4, z: 2, time: 3)]
        data.floorY = -0.02
        let enc = JSONEncoder()
        let bytes = try enc.encode(data)
        let back = try JSONDecoder().decode(StoreShelfData.self, from: bytes)
        XCTAssertEqual(back, data)
        XCTAssertEqual(back.products[0].embeddings[0].values, [1, 2, 3])
    }
}
