import XCTest
@testable import Gonggi

/// Automatic photo selection and the import of a server analysis draft. Simulated inputs only: these tests say nothing
/// about how well the thresholds work on real captures.
final class StoreShelfCoreTests8: XCTestCase {
    // MARK: Auto capture

    private func frame(t: Double, x: Float = 0, yaw: Float = 0, sharp: Float = 200, tracking: Bool = true, dist: Float? = 1.2,
                       thumb: UInt8 = 100) -> AutoCaptureFrame {
        AutoCaptureFrame(time: t, pose: Rigid.yaw(yaw, translation: Vec3(x, 1.3, 0)), trackingNormal: tracking, sharpness: sharp,
                         thumbnail: [UInt8](repeating: thumb, count: 24 * 32), centreDistance: dist)
    }

    private func texture(_ seed: Int) -> [UInt8] {
        (0..<(24 * 32)).map { UInt8(truncatingIfNeeded: ($0 &* 37 &+ seed &* 91) % 251) }
    }

    func testFirstSteadySharpFrameIsSavedAndTheSameViewIsNot() {
        var s = AutoCaptureSelector()
        XCTAssertTrue(s.consider(frame(t: 0)).save)
        for i in 1..<40 {
            let d = s.consider(frame(t: Double(i) * 0.1))
            XCTAssertFalse(d.save, "standing still must not produce more photos")
        }
        XCTAssertEqual(s.savedCount, 1)
    }

    func testSlowSweepSavesPhotosByDistanceAndNotEveryFrame() {
        var s = AutoCaptureSelector()
        var saved = 0
        // 0.2 m/s along the shelf for 12 s at 10 analysed frames per second.
        for i in 0..<120 {
            let t = Double(i) * 0.1
            if s.consider(frame(t: t, x: Float(t) * 0.2)).save { saved += 1 }
        }
        XCTAssertGreaterThanOrEqual(saved, 8)
        XCTAssertLessThanOrEqual(saved, 12, "about one photo per 0.25 m of travel, not one per frame")
    }

    func testFastMotionBlurAndLostTrackingAreNotSavedAndSayWhy() {
        var s = AutoCaptureSelector()
        XCTAssertTrue(s.consider(frame(t: 0)).save)
        let fast = s.consider(frame(t: 0.1, x: 0.3))   // 3 m/s
        XCTAssertFalse(fast.save)
        XCTAssertEqual(fast.hint, .tooFast)
        XCTAssertEqual(s.consider(frame(t: 1.2, x: 0.5, sharp: 5)).hint, .blurry)
        XCTAssertEqual(s.consider(frame(t: 1.4, x: 0.52, tracking: false)).hint, .trackingLost)
        XCTAssertEqual(s.consider(frame(t: 1.6, x: 0.54, dist: 5)).hint, .tooFar)
        XCTAssertEqual(s.consider(frame(t: 1.8, x: 0.56, dist: 0.1)).hint, .tooClose)
        XCTAssertEqual(s.savedCount, 1)
    }

    func testHintsAreAbsentWhenNothingIsWrong() {
        var s = AutoCaptureSelector()
        _ = s.consider(frame(t: 0))
        XCTAssertEqual(s.consider(frame(t: 0.2, x: 0.01)).hint, .none)
    }

    func testPhotoCapAndLowOverlapMark() {
        var cfg = AutoCaptureConfig()
        cfg.maxPhotos = 2
        var s = AutoCaptureSelector(config: cfg)
        var f0 = frame(t: 0)
        f0.thumbnail = texture(1)
        XCTAssertTrue(s.consider(f0).save)
        var f1 = frame(t: 2, yaw: 0.5)
        f1.thumbnail = texture(7)
        let d1 = s.consider(f1)
        XCTAssertTrue(d1.save)
        XCTAssertEqual(d1.reason, "turned")
        XCTAssertTrue(d1.lowOverlap, "an unrelated picture means the photos barely overlap")
        let d2 = s.consider(frame(t: 4, x: 1))
        XCTAssertFalse(d2.save)
        XCTAssertEqual(d2.hint, .limitReached)
    }

    func testPictureChangeAloneCanTriggerASave() {
        var s = AutoCaptureSelector()
        var a = frame(t: 0)
        a.thumbnail = texture(1)
        XCTAssertTrue(s.consider(a).save)
        var b = frame(t: 2)
        b.thumbnail = texture(5)
        let d = s.consider(b)
        XCTAssertTrue(d.save)
        XCTAssertEqual(d.reason, "changed")
    }

    func testImageChangeIgnoresUniformBrightnessChange() {
        let a = texture(3)
        let brighter = a.map { UInt8(min(255, Int($0) + 20)) }
        XCTAssertLessThan(AutoCaptureSelector.imageChange(a, brighter), 0.08)
        XCTAssertGreaterThan(AutoCaptureSelector.imageChange(a, texture(9)), 0.1)
    }

    // MARK: Import

    private var ids: Int = 0
    private func newId() -> String {
        ids += 1
        return "id\(ids)"
    }

    private let hooks = AnalysisImportHooks(
        productImage: { photoId, _ in AnalysisProductImage(jpeg: Data(photoId.utf8), embedding: [1, 0, 0], color: [1]) },
        shelfPhoto: { Data($0.utf8) })

    private func box() -> RemoteBox { RemoteBox(x0: 0.1, y0: 0.1, x1: 0.4, y1: 0.6) }

    private func shelf(_ key: String, position: [Float]? = [1, 1, -2], status: String = "confirmed") -> RemoteDraftShelf {
        RemoteDraftShelf(
            key: key, name: nil, kind: "shelf", representativePhotoId: "p1", evidencePhotoIds: ["p1"],
            regions: [RemoteDraftRegion(photoId: "p1", box: box())], facing: "toward_camera",
            spatial: position.map {
                RemoteShelfSpatial(position: $0, normal: [0, 0, 1], standPoint: [$0[0], 1.3, $0[2] + 0.9], source: "plane_intersection",
                                   status: status, supportingPhotoIds: ["p1", "p2"], spreadM: 0.05)
            },
            locationStatus: position == nil ? "unknown" : status, lastObservedAt: "2026-10-13T01:02:03.000Z")
    }

    private func product(_ key: String, name: String?, status: String = "read", reasons: [String] = []) -> RemoteDraftProduct {
        RemoteDraftProduct(
            key: key, nameOriginal: name, brand: nil, variant: nil, volumeText: "500ml", volumeValue: 500, volumeUnit: "ml",
            printedText: name.map { [$0] } ?? [], nameReadStatus: status, confirmed: [], unconfirmed: [],
            representative: RemoteDraftRegion(photoId: "p1", box: box()),
            sightings: [RemoteDraftSighting(photoId: "p1", box: box(), shelfRef: "S1")], needsReview: !reasons.isEmpty,
            reviewReasons: reasons, matchedStoreProductId: nil, nameKey: nil)
    }

    private func obs(_ product: String, _ shelf: String?, count: Int?, basis: String = "counted") -> RemoteDraftObservation {
        RemoteDraftObservation(productKey: product, shelfKey: shelf, visibleCount: count, countBasis: basis, evidencePhotoIds: ["p1"],
                               observedAt: "2026-10-13T01:02:03Z")
    }

    private func run(_ draft: RemoteAnalysisDraft, existing: StoreShelfData = .empty(storeId: "st")) -> AnalysisImportResult {
        AnalysisImporter.importDraft(draft: draft, existing: existing, storeId: "st", capturedAt: Date(timeIntervalSince1970: 0),
                                     walkTrail: [], newId: { self.newId() }, hooks: hooks)
    }

    func testImportBuildsShelvesProductsAndPlacementsFromMeasuredPositions() {
        let r = run(RemoteAnalysisDraft(
            shelves: [shelf("s1")],
            products: [product("n1", name: "코카콜라 제로"), product("n2", name: "농심 신라면")],
            observations: [obs("n1", "s1", count: 3), obs("n2", "s1", count: nil, basis: "cannot_count")]))
        XCTAssertEqual(r.data.shelves.count, 1)
        XCTAssertEqual(r.data.products.map(\.name).sorted(), ["농심 신라면", "코카콜라 제로"])
        XCTAssertEqual(r.data.placements.count, 2)
        let cola = r.data.products.first { $0.name == "코카콜라 제로" }!
        XCTAssertEqual(cola.nameSource, ShelfNameSource.auto)
        XCTAssertFalse(cola.needsReview)
        XCTAssertEqual(cola.volumeText, "500ml")
        XCTAssertEqual(cola.embeddings.count >= 1, true)
        let place = r.data.placements(ofProduct: cola.id)[0]
        XCTAssertEqual(place.visibleCount, 3)
        XCTAssertEqual(place.world, Vec3(1, 1, -2), "the placement is at the measured shelf, not at the camera")
        XCTAssertEqual(r.data.shelves[0].locationStatus, "confirmed")
        XCTAssertEqual(r.data.shelves[0].plane.normal, Vec3(0, 0, 1))
        XCTAssertEqual(r.data.shelves[0].plane.uAxis.x, 1, accuracy: 1e-5, "u runs left to right for a customer in front of the shelf")
        XCTAssertEqual(r.summary.shelvesWithoutPosition, 0)
    }

    func testUnreadNameStaysAPlaceholderWithAReviewReason() {
        let r = run(RemoteAnalysisDraft(
            shelves: [shelf("s1")],
            products: [product("n1", name: nil, status: "unreadable", reasons: ["이름을 읽지 못했어요"])],
            observations: [obs("n1", "s1", count: 1)]))
        let p = r.data.products[0]
        XCTAssertTrue(ShelfProductNameExtractor.isPlaceholder(p.name))
        XCTAssertNil(p.nameSource)
        XCTAssertEqual(p.reviewReasons, [ShelfNameReview.unread])
        XCTAssertTrue(p.needsReview)
        XCTAssertEqual(r.summary.productsNeedingReview, 1)
    }

    func testPartialNameAsksForConfirmationOnly() {
        let r = run(RemoteAnalysisDraft(shelves: [shelf("s1")], products: [product("n1", name: "코카콜", status: "partial")],
                                        observations: [obs("n1", "s1", count: 1)]))
        XCTAssertEqual(r.data.products[0].reviewReasons, [ShelfNameReview.confirm])
    }

    func testShelfWithoutAMeasuredPositionIsKeptButNeverAGuidanceTarget() {
        let r = run(RemoteAnalysisDraft(shelves: [shelf("s1", position: nil)], products: [product("n1", name: "새우깡")],
                                        observations: [obs("n1", "s1", count: 2)]))
        XCTAssertEqual(r.data.shelves[0].locationStatus, "unknown")
        XCTAssertFalse(r.data.shelves[0].isGuidable)
        XCTAssertEqual(r.summary.shelvesWithoutPosition, 1)
        XCTAssertTrue(r.data.placements[0].needsReview)
        let planner = StoreGuidancePlanner(data: r.data)
        XCTAssertNil(planner.plan(placement: r.data.placements[0], alignment: .identity, cameraLive: .zero), "no route or marker to an unknown place")
    }

    func testProductWithoutAShelfIsFlaggedNotInvented() {
        let r = run(RemoteAnalysisDraft(shelves: [shelf("s1")], products: [product("n1", name: "새우깡")], observations: []))
        XCTAssertTrue(r.data.placements.isEmpty)
        XCTAssertEqual(r.summary.productsWithoutShelf, 1)
        XCTAssertTrue(r.data.products[0].reviewReasons.contains("어느 매대에 있는지 확인되지 않았어요"))
    }

    func testManagersNameAndIdSurviveANewCaptureAndObservationsAreReplacedNotAdded() {
        var old = StoreShelfData.empty(storeId: "st")
        var kept = ShelfProduct(id: "old1", name: "우리 매장 콜라", createdAt: Date(), imageFileNames: [], embeddings: [], colorDescriptors: [],
                                similarProductIds: [], needsReview: false, reviewReasons: [])
        kept.nameSource = ShelfNameSource.manual
        old.products = [kept]
        let plane = ShelfPlane(origin: .zero, uAxis: Vec3(1, 0, 0), normal: Vec3(0, 0, 1))
        old.shelves = [ShelfLayout(id: "oldshelf", name: "매대 1", plane: plane, tierBoundaries: [], createdAt: Date(), updatedAt: Date(), photoFileName: nil)]
        old.placements = [ShelfPlacement(id: "oldpl", productId: "old1", shelfId: "oldshelf", u: 0, v: 0, tier: 0, world: .zero, widthM: 0.1,
                                         heightM: 0.2, uncertaintyM: 0.1, observationCount: 1, firstObservedAt: Date(), lastObservedAt: Date(),
                                         status: .present, needsReview: false, visibleCount: 9, countBasis: "counted")]
        // The new capture names the same product by its printed name "우리 매장 콜라" only through the manager's name.
        let r = run(RemoteAnalysisDraft(shelves: [shelf("s1")], products: [product("n1", name: "우리 매장 콜라")],
                                        observations: [obs("n1", "s1", count: 2)]), existing: old)
        XCTAssertEqual(r.data.products.count, 1)
        XCTAssertEqual(r.data.products[0].id, "old1")
        XCTAssertEqual(r.data.products[0].nameSource, ShelfNameSource.manual)
        XCTAssertEqual(r.data.placements.count, 1)
        XCTAssertEqual(r.data.placements[0].visibleCount, 2, "9 (old) and 2 (new) are not added up")
        XCTAssertFalse(r.data.shelves.contains { $0.id == "oldshelf" })
    }

    func testQuantityTextIsAboutTheTimeOfThePhotoNeverStock() {
        XCTAssertEqual(VisibleQuantityText.line(visibleCount: 3, basis: "counted"), "촬영 당시 3개 확인")
        XCTAssertEqual(VisibleQuantityText.line(visibleCount: 4, basis: "lower_bound"), "촬영 당시 4개 이상 확인")
        XCTAssertEqual(VisibleQuantityText.line(visibleCount: nil, basis: "cannot_count"), "수량은 확인되지 않았어요")
        XCTAssertEqual(VisibleQuantityText.line(visibleCount: 5, basis: "cannot_count"), "수량은 확인되지 않았어요")
        XCTAssertFalse(VisibleQuantityText.line(visibleCount: 3, basis: "counted").contains("재고"))
    }

    func testDraftJsonFromTheServerDecodes() throws {
        let json = """
        {"shelves":[{"key":"s1","name":null,"kind":"refrigerator","representativePhotoId":"p1","evidencePhotoIds":["p1"],
         "regions":[{"photoId":"p1","box":{"x0":0.1,"y0":0.1,"x1":0.9,"y1":0.9}}],"facing":"toward_camera",
         "spatial":{"position":[0.25,1.3,-2],"normal":[0,0,1],"standPoint":[0.25,1.3,-1.1],"source":"plane_intersection","status":"confirmed",
         "supportingPhotoIds":["p1","p2"],"spreadM":0.0},"locationStatus":"confirmed","lastObservedAt":"2026-10-13T02:00:00.000Z"}],
         "products":[{"key":"n1","nameOriginal":"새우깡","brand":null,"variant":null,"volumeText":"90g","volumeValue":90,"volumeUnit":"g",
         "printedText":[],"nameReadStatus":"read","confirmed":[],"unconfirmed":[],"representative":{"photoId":"p1","box":{"x0":0,"y0":0,"x1":1,"y1":1}},
         "sightings":[{"photoId":"p1","box":{"x0":0,"y0":0,"x1":1,"y1":1},"shelfRef":"S1"}],"needsReview":false,"reviewReasons":[],
         "matchedStoreProductId":null,"nameKey":"새우깡"}],
         "observations":[{"productKey":"n1","shelfKey":"s1","visibleCount":null,"countBasis":"cannot_count","evidencePhotoIds":["p1"],
         "observedAt":"2026-10-13T02:00:00.000Z"}]}
        """
        let d = try JSONDecoder().decode(RemoteAnalysisDraft.self, from: Data(json.utf8))
        XCTAssertEqual(d.products[0].nameOriginal, "새우깡")
        XCTAssertNil(d.observations[0].visibleCount)
        XCTAssertNotNil(AnalysisImporter.parseDate(d.shelves[0].lastObservedAt))
    }
}
