import XCTest
@testable import Gonggi

/// Duplicate-free registration (parallax-aware tracking, structure rejection), product names read from the package,
/// and the search session. Pure logic: runs on Linux (Tools/StoreShelfLogicCheck) and in the app's unit tests.
/// These tests use SIMULATED geometry and text lines; they say nothing about accuracy on real photos.
final class StoreShelfCoreTests6: XCTestCase {
    // MARK: Helpers

    private func look(_ v: [Float]) -> ShelfAppearance { ShelfAppearance(embedding: v, color: v) }

    private func frontPlane() -> ShelfPlane {
        ShelfPlane.fromBaseline(a: Vec3(-1, 0, -2), b: Vec3(1, 0, -2), viewer: Vec3(0, 1.4, 0))!
    }

    private func camera(x: Float, y: Float = 1.3, z: Float = 0) -> StoreCameraModel {
        StoreCameraModel(fx: 1000, fy: 1000, cx: 500, cy: 500, width: 1000, height: 1000,
                         cameraToWorld: Rigid.translation(Vec3(x, y, z)))
    }

    /// One observation of a physical point `depth` metres behind the shelf front, seen from a camera at x.
    private func view(of point: Vec3, from cam: StoreCameraModel, plane: ShelfPlane, look l: [Float], frame: Int,
                      sharp: Float = 200) -> ShelfObservation? {
        guard let px = cam.project(point),
              let fix = ShelfPositionEstimator.estimate(plane: plane, camera: cam, pixelU: px.u, pixelV: px.v),
              let g = ShelfPositionEstimator.viewGeometry(plane: plane, camera: cam, fix: fix) else { return nil }
        var o = ShelfObservation(time: Double(frame) * 0.4, u: fix.u, v: fix.v, world: fix.world, uncertaintyM: fix.uncertaintyM,
                                 widthM: 0.08, heightM: 0.2, appearance: look(l), sharpness: sharp, cropRef: "f\(frame)")
        o.frameIndex = frame
        o.viewTanU = g.tanU
        o.viewTanV = g.tanV
        o.rayPerDepth = g.rayPerDepth
        return o
    }

    private func line(_ text: String, _ conf: Float = 0.9, h: Float = 0.2, y: Float = 0.3) -> ShelfTextLine {
        ShelfTextLine(text: text, confidence: conf, heightFraction: h, centerY: y)
    }

    // MARK: Structure rejection

    func testStripsAndStructuresAreRejectedProductsAreKept() {
        func ev(w: Float, h: Float, aspect: Float, std: Float) -> ShelfRegionEvidence {
            ShelfRegionEvidence(widthM: w, heightM: h, aspect: aspect, lumaStd: std, clipped: false)
        }
        XCTAssertEqual(ShelfRegionFilter.assess(ev(w: 0.07, h: 0.12, aspect: 1.7, std: 45)), .accept, "a can")
        XCTAssertEqual(ShelfRegionFilter.assess(ev(w: 0.30, h: 0.03, aspect: 10, std: 40)), .reject(.tooSmallPhysically), "light strip")
        XCTAssertEqual(ShelfRegionFilter.assess(ev(w: 0.08, h: 0.50, aspect: 6.2, std: 40)), .reject(.extremeAspect), "door edge")
        XCTAssertEqual(ShelfRegionFilter.assess(ev(w: 0.80, h: 0.45, aspect: 1.8, std: 40)), .reject(.tooLargePhysically), "shelf level")
        XCTAssertEqual(ShelfRegionFilter.assess(ev(w: 0.10, h: 0.20, aspect: 2, std: 3)), .reject(.flatTexture), "flat white or black")
        XCTAssertEqual(ShelfRegionFilter.assess(ev(w: 0.07, h: 0.25, aspect: 3.6, std: 30)), .accept, "a bottle")
        // size unknown: only shape and texture decide
        XCTAssertEqual(ShelfRegionFilter.assess(ShelfRegionEvidence(widthM: nil, heightM: nil, aspect: 2, lumaStd: 40, clipped: false)), .accept)
    }

    func testContainerOfSeveralProductsAndPartOfOneAreDropped() {
        func r(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> StoreImageSpace.PixelRect {
            StoreImageSpace.PixelRect(minU: a, minV: b, maxU: c, maxV: d)
        }
        let items: [ShelfRegionArbiter.Item] = [
            .init(rect: r(0, 0, 600, 300), score: 0.6, plausible: true),      // 0: the shelf level holding three products
            .init(rect: r(20, 20, 150, 280), score: 0.7, plausible: true),    // 1
            .init(rect: r(200, 20, 330, 280), score: 0.7, plausible: true),   // 2
            .init(rect: r(380, 20, 510, 280), score: 0.7, plausible: true),   // 3
            .init(rect: r(40, 60, 120, 120), score: 0.5, plausible: true),    // 4: the label of product 1
        ]
        let out = ShelfRegionArbiter.resolve(items)
        XCTAssertEqual(out.containers, [0])
        XCTAssertEqual(out.parts, [4])
        XCTAssertEqual(out.kept, [1, 2, 3])
    }

    func testNeighboursAreNotParts() {
        func r(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> StoreImageSpace.PixelRect {
            StoreImageSpace.PixelRect(minU: a, minV: b, maxU: c, maxV: d)
        }
        let items: [ShelfRegionArbiter.Item] = [
            .init(rect: r(0, 0, 100, 200), score: 0.7, plausible: true),
            .init(rect: r(105, 0, 205, 200), score: 0.7, plausible: true),
        ]
        XCTAssertEqual(ShelfRegionArbiter.resolve(items).kept, [0, 1])
    }

    // MARK: Parallax-aware tracking

    /// A product inside a refrigerator (0.4 m behind the front plane) seen from cameras spread over 1.6 m of walking.
    func testItemBehindThePlaneStaysOneProductAcrossViews() throws {
        let plane = frontPlane()
        let point = plane.worldPoint(u: 1.0, v: 0.8, offset: -0.4)
        let truth = plane.coordinates(of: point)
        var agg = ShelfObservationAggregator()
        let xs: [Float] = [0.2, 1.8, 0.6, 1.4, 1.0, 0.3, 1.7, 0.9]
        for (i, x) in xs.enumerated() {
            let o = try XCTUnwrap(view(of: point, from: camera(x: x), plane: plane, look: [1, 0, 0, 0], frame: i))
            agg.add(o)
        }
        let res = agg.finalize()
        XCTAssertEqual(res.candidates.count, 1, "one physical product is one candidate")
        XCTAssertEqual(res.candidates[0].observationCount, xs.count)
        XCTAssertEqual(res.candidates[0].u, truth.u, accuracy: 0.04)
        XCTAssertEqual(res.candidates[0].v, truth.v, accuracy: 0.04)
        XCTAssertEqual(try XCTUnwrap(res.candidates[0].depthBehindPlaneM), 0.4, accuracy: 0.1)
        XCTAssertEqual(res.candidates[0].world.distance(to: point), 0, accuracy: 0.06, "world position is the real item, not its shadow on the plane")
    }

    /// The failure this fixes, reproduced: without depth handling the same views fall apart into several "products".
    func testWithoutDepthHandlingTheSameViewsFragment() throws {
        let plane = frontPlane()
        let point = plane.worldPoint(u: 1.0, v: 0.8, offset: -0.4)
        var cfg = ShelfAggregationConfig()
        cfg.maxDepthBehindPlaneM = 0
        var agg = ShelfObservationAggregator(config: cfg)
        for (i, x) in ([0.2, 1.8, 0.6, 1.4, 1.0, 0.3, 1.7, 0.9] as [Float]).enumerated() {
            agg.add(try XCTUnwrap(view(of: point, from: camera(x: x), plane: plane, look: [1, 0, 0, 0], frame: i)))
        }
        XCTAssertGreaterThan(agg.finalize().candidates.count + agg.finalize().rejected.count, 1)
    }

    func testTwoNeighbouringProductsBehindThePlaneStayApart() throws {
        let plane = frontPlane()
        let p1 = plane.worldPoint(u: 0.90, v: 0.8, offset: -0.4)
        let p2 = plane.worldPoint(u: 1.20, v: 0.8, offset: -0.4)
        var agg = ShelfObservationAggregator()
        var frame = 0
        for x: Float in [0.2, 1.8, 0.6, 1.4, 1.0, 0.3] {
            agg.add(try XCTUnwrap(view(of: p1, from: camera(x: x), plane: plane, look: [1, 0, 0, 0], frame: frame)))
            agg.add(try XCTUnwrap(view(of: p2, from: camera(x: x), plane: plane, look: [0, 1, 0, 0], frame: frame)))
            frame += 1
        }
        XCTAssertEqual(agg.finalize().candidates.count, 2)
    }

    func testTwoIdenticalLookingItemsInOneFrameAreTwoItems() throws {
        let plane = frontPlane()
        let p1 = plane.worldPoint(u: 1.00, v: 0.8, offset: 0)
        let p2 = plane.worldPoint(u: 1.07, v: 0.8, offset: 0)   // the same product, next facing
        var agg = ShelfObservationAggregator()
        for (f, x) in ([0.5, 0.7, 0.9, 1.1, 1.3] as [Float]).enumerated() {
            agg.add(try XCTUnwrap(view(of: p1, from: camera(x: x), plane: plane, look: [1, 0, 0, 0], frame: f)))
            agg.add(try XCTUnwrap(view(of: p2, from: camera(x: x), plane: plane, look: [1, 0, 0, 0], frame: f)))
        }
        XCTAssertEqual(agg.finalize().candidates.count, 2, "two detections of one frame are never merged")
    }

    func testStrayViewOfAnAcceptedProductIsNotAnUnsavedArea() throws {
        let plane = frontPlane()
        let point = plane.worldPoint(u: 1.0, v: 0.8, offset: 0)
        var agg = ShelfObservationAggregator()
        for (i, x) in ([0.6, 0.8, 1.0, 1.2, 1.4] as [Float]).enumerated() {
            agg.add(try XCTUnwrap(view(of: point, from: camera(x: x), plane: plane, look: [1, 0, 0, 0], frame: i)))
        }
        // A blurry single view of the same spot with a slightly different look (a different angle).
        var stray = try XCTUnwrap(view(of: point, from: camera(x: 1.0), plane: plane, look: [0.8, 0.45, 0, 0], frame: 20, sharp: 4))
        stray.u += 0.02
        agg.add(stray)
        let res = agg.finalize()
        XCTAssertEqual(res.candidates.count, 1)
        XCTAssertTrue(res.rejected.isEmpty)
    }

    func testSeveralWeakViewsOfOneSpotAreCountedOnce() throws {
        let plane = frontPlane()
        let point = plane.worldPoint(u: 0.4, v: 0.5, offset: 0)
        var agg = ShelfObservationAggregator()
        // Two single glimpses 5 cm apart in different looks: neither is accepted, and they are one unsaved area.
        agg.add(try XCTUnwrap(view(of: point, from: camera(x: 0.5), plane: plane, look: [1, 0, 0, 0], frame: 0)))
        var b = try XCTUnwrap(view(of: point, from: camera(x: 0.6), plane: plane, look: [0, 0, 1, 0], frame: 1))
        b.u += 0.05
        agg.add(b)
        XCTAssertEqual(agg.finalize().rejected.count, 1)
    }

    func testRepresentativeImageIsSharpAndWholeNotJustSharp() {
        func o(_ ref: String, sharp: Float, completeness: Float, i: Int) -> ShelfObservation {
            var x = ShelfObservation(time: Double(i), u: 1, v: 1, world: .zero, uncertaintyM: 0.02, widthM: 0.1, heightM: 0.2,
                                     appearance: look([1, 0, 0, 0]), sharpness: sharp, cropRef: ref)
            x.completeness = completeness
            x.frameIndex = i
            return x
        }
        var agg = ShelfObservationAggregator()
        agg.add(o("cut", sharp: 400, completeness: 0.4, i: 0))   // sharpest but cut by the image border
        agg.add(o("whole", sharp: 250, completeness: 1, i: 1))
        agg.add(o("soft", sharp: 120, completeness: 1, i: 2))
        let c = agg.finalize().candidates
        XCTAssertEqual(c[0].cropRefs.first, "whole")
    }

    // MARK: Names

    func testKoreanNameVolumeAndBrandFromRepeatedReads() throws {
        let reads: [[ShelfTextLine]] = (0..<4).map { i in
            [line("코카콜라", 0.92, h: 0.22, y: 0.35), line("제로", 0.88, h: 0.12, y: 0.55), line("500ml", 0.9, h: 0.06, y: 0.8),
             line(i == 0 ? "영양성분 1회 제공량" : "유통기한 2026.10.20", 0.9, h: 0.04, y: 0.9)]
        }
        let n = try XCTUnwrap(ShelfProductNameExtractor.extract(observations: reads))
        XCTAssertEqual(n.displayName, "코카콜라 제로")
        XCTAssertEqual(n.volume, "500ml")
        XCTAssertTrue(n.hasHangul)
        XCTAssertFalse(n.needsConfirmation)
        XCTAssertEqual(n.variant, "제로")
        XCTAssertEqual(n.brand, "코카콜라")
    }

    func testEnglishNameKeepsItsOriginalSpelling() throws {
        let reads: [[ShelfTextLine]] = [
            [line("Coca-Cola", 0.9, h: 0.2, y: 0.3), line("ZERO SUGAR", 0.8, h: 0.1, y: 0.5)],
            [line("Coca-Cola", 0.95, h: 0.2, y: 0.3), line("ZERO SUGAR", 0.85, h: 0.1, y: 0.5)],
        ]
        let n = try XCTUnwrap(ShelfProductNameExtractor.extract(observations: reads))
        XCTAssertEqual(n.displayName, "Coca-Cola ZERO SUGAR")
        XCTAssertTrue(n.hasLatin)
        XCTAssertFalse(n.hasHangul)
    }

    func testMixedKoreanEnglishNameIsKeptAsPrinted() throws {
        let reads: [[ShelfTextLine]] = [
            [line("농심", 0.9, h: 0.15, y: 0.2), line("Shin Ramyun", 0.9, h: 0.18, y: 0.4)],
            [line("농심", 0.9, h: 0.15, y: 0.2), line("Shin Ramyun", 0.9, h: 0.18, y: 0.4)],
            [line("농심", 0.85, h: 0.15, y: 0.2), line("Shin Ramyun", 0.9, h: 0.18, y: 0.4)],
        ]
        let n = try XCTUnwrap(ShelfProductNameExtractor.extract(observations: reads))
        XCTAssertEqual(n.displayName, "농심 Shin Ramyun")
        XCTAssertTrue(n.hasHangul)
        XCTAssertTrue(n.hasLatin)
    }

    func testNutritionDatesPricesAndAdsAreNeverAName() {
        let junk = ["영양성분표", "1회 제공량 30g", "유통기한 2026.12.01", "제조일자 25.10.01", "특가 1+1", "1,500원", "신제품 출시", "냉장보관 하세요",
                    "원재료명 및 함량", "고객센터 080-123-4567", "www.example.com", "Nutrition Facts", "할인 30%", "Best before"]
        for j in junk { XCTAssertTrue(ShelfProductNameExtractor.isNoise(j), j) }
        let reads = (0..<4).map { _ in junk.map { line($0, 0.95, h: 0.2) } }
        XCTAssertNil(ShelfProductNameExtractor.extract(observations: reads), "nothing but noise: no name is invented")
    }

    func testNameWordsThatContainAdOrNutritionSyllablesStayUsable() throws {
        XCTAssertFalse(ShelfProductNameExtractor.isNoise("저지방 우유"))
        XCTAssertFalse(ShelfProductNameExtractor.isNoise("New Balance"))
        XCTAssertFalse(ShelfProductNameExtractor.isNoise("Express Mart"))
        let reads: [[ShelfTextLine]] = (0..<2).map { _ in [line("서울우유", 0.9, h: 0.2, y: 0.3), line("저지방", 0.9, h: 0.1, y: 0.5)] }
        let n = try XCTUnwrap(ShelfProductNameExtractor.extract(observations: reads))
        XCTAssertEqual(n.displayName, "서울우유 저지방")
    }

    func testSingleWeakReadIsNotAName() {
        XCTAssertNil(ShelfProductNameExtractor.extract(observations: [[line("코카콜라", 0.6, h: 0.1)]]))
        // A single, large, confident read is accepted but flagged for confirmation.
        let n = ShelfProductNameExtractor.extract(observations: [[line("코카콜라", 0.95, h: 0.25)]])
        XCTAssertEqual(n?.displayName, "코카콜라")
        XCTAssertEqual(n?.needsConfirmation, true)
    }

    func testOcrSpellingVariantsAreOneLineAndTheBestSpellingWins() throws {
        let reads: [[ShelfTextLine]] = [
            [line("코카골라", 0.55, h: 0.2)], [line("코카콜라", 0.93, h: 0.2)], [line("코카콜라", 0.9, h: 0.2)],
        ]
        let n = try XCTUnwrap(ShelfProductNameExtractor.extract(observations: reads))
        XCTAssertEqual(n.displayName, "코카콜라")
        XCTAssertEqual(n.support, 3)
    }

    func testTextSettlesOnlyAmongTheListedCandidates() {
        let names = ["a": ["코카콜라제로"], "b": ["코카콜라"], "c": ["펩시"]]
        XCTAssertEqual(ShelfTextResolver.resolve(candidates: ["a", "c"], names: names, readLines: ["코카콜라 제로"]), "a")
        XCTAssertNil(ShelfTextResolver.resolve(candidates: ["a", "b"], names: names, readLines: ["코카콜라"]), "two candidates fit: no decision")
        XCTAssertNil(ShelfTextResolver.resolve(candidates: ["c"], names: names, readLines: ["코카콜라"]))
    }

    // MARK: Products: names, barcodes, protection

    private func candidate(u: Float, v: Float = 0.3, look l: [Float], name: ShelfExtractedName? = nil, barcodes: [String] = [],
                           count: Int = 5) -> ShelfCandidate {
        var c = ShelfCandidate(u: u, v: v, widthM: 0.1, heightM: 0.2, uncertaintyM: 0.03, observationCount: count, firstTime: 0,
                               lastTime: 1, medianSharpness: 200, appearances: [look(l)], cropRefs: ["c"], world: Vec3(u, v, -2),
                               needsReview: false, reviewReasons: [])
        c.name = name
        c.barcodes = barcodes
        return c
    }

    private func name(_ s: String, conf: Float = 0.9, support: Int = 3, confirm: Bool = false) -> ShelfExtractedName {
        ShelfExtractedName(displayName: s, brand: nil, variant: nil, volume: nil, confidence: conf, support: support, hasHangul: true,
                           hasLatin: false, needsConfirmation: confirm, tokens: [ShelfProductNameExtractor.key(s)])
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

    private func apply(_ cands: [ShelfCandidate], to data: StoreShelfData = .empty(storeId: "st")) -> StoreShelfData {
        let groups = ShelfProductGrouper.group(cands)
        return ShelfDataUpdater.apply(candidates: cands, groups: groups, cropFileNames: cands.map { _ in ["a.jpg"] }, shelf: shelf(),
                                      coverage: ShelfRecordingCoverage(minU: 0, maxU: 5, minV: 0, maxV: 2), now: Date(timeIntervalSince1970: 50),
                                      to: data, naming: naming()).data
    }

    func testReadNameIsSavedAndPlaceholderIsFlaggedWhenUnread() {
        let d = apply([candidate(u: 0.5, look: [1, 0, 0, 0], name: name("코카콜라 제로")), candidate(u: 1.5, look: [0, 1, 0, 0])])
        let named = d.products.first { $0.name == "코카콜라 제로" }
        XCTAssertNotNil(named)
        XCTAssertEqual(named?.nameSource, ShelfNameSource.auto)
        XCTAssertEqual(named?.needsReview, false)
        let unread = d.products.first { ShelfProductNameExtractor.isPlaceholder($0.name) }
        XCTAssertEqual(unread?.reviewReasons.contains(ShelfNameReview.unread), true)
        XCTAssertEqual(unread?.needsReview, true)
    }

    func testWeakNameAsksForConfirmationOnly() {
        let d = apply([candidate(u: 0.5, look: [1, 0, 0, 0], name: name("코카콜라", conf: 0.7, support: 1, confirm: true))])
        XCTAssertEqual(d.products[0].reviewReasons, [ShelfNameReview.confirm])
    }

    func testManagersNameIsNeverOverwrittenByARecording() {
        var d = apply([candidate(u: 0.5, look: [1, 0, 0, 0], name: name("코카콜라"))])
        d.products[0].name = "내가 붙인 이름"
        d.products[0].nameSource = ShelfNameSource.manual
        let again = apply([candidate(u: 0.5, look: [1, 0, 0, 0], name: name("펩시콜라", conf: 0.99))], to: d)
        XCTAssertEqual(again.products.count, 1, "the same look: the same product")
        XCTAssertEqual(again.products[0].name, "내가 붙인 이름")
        // legacy data (no nameSource) with a typed name is protected too
        var legacy = d
        legacy.products[0].nameSource = nil
        let again2 = apply([candidate(u: 0.5, look: [1, 0, 0, 0], name: name("펩시콜라", conf: 0.99))], to: legacy)
        XCTAssertEqual(again2.products[0].name, "내가 붙인 이름")
    }

    func testPlaceholderIsReplacedByALaterReading() {
        let first = apply([candidate(u: 0.5, look: [1, 0, 0, 0])])
        XCTAssertTrue(ShelfProductNameExtractor.isPlaceholder(first.products[0].name))
        let second = apply([candidate(u: 0.5, look: [1, 0, 0, 0], name: name("오뚜기 진라면"))], to: first)
        XCTAssertEqual(second.products.count, 1)
        XCTAssertEqual(second.products[0].name, "오뚜기 진라면")
        XCTAssertFalse(second.products[0].reviewReasons.contains(ShelfNameReview.unread))
    }

    func testDifferentReadNamesKeepSameLookingProductsApart() {
        let cands = [candidate(u: 0.5, look: [1, 0, 0, 0], name: name("코카콜라")), candidate(u: 0.9, look: [1, 0, 0, 0], name: name("코카콜라 제로"))]
        XCTAssertEqual(ShelfProductGrouper.group(cands).count, 2)
        XCTAssertEqual(ShelfProductGrouper.relation(cands[0], cands[1]), .similar)
    }

    func testSameReadNameJoinsViewsThatLookSlightlyDifferent() {
        let a = candidate(u: 0.5, look: [1, 0, 0, 0], name: name("코카콜라 제로"))
        let b = candidate(u: 1.8, v: 1.3, look: [0.8, 0.6, 0, 0], name: name("코카콜라 제로"))
        XCTAssertGreaterThan(ShelfProductGrouper.appearanceDistance(a, b) ?? 0, 0.2)
        XCTAssertEqual(ShelfProductGrouper.group([a, b]).count, 1, "one product, two display positions")
    }

    func testBarcodesDecideBothWays() {
        let a = candidate(u: 0.5, look: [1, 0, 0, 0], barcodes: ["8801234567890"])
        let sameCode = candidate(u: 1.5, look: [0, 1, 0, 0], barcodes: ["8801234567890"])
        let otherCode = candidate(u: 2.5, look: [1, 0.02, 0, 0], barcodes: ["8809999999999"])
        XCTAssertEqual(ShelfProductGrouper.relation(a, sameCode), .same)
        XCTAssertNotEqual(ShelfProductGrouper.relation(a, otherCode), .same)
    }

    func testOneProductInTwoPlacesStaysOneProductWithTwoPositions() {
        let d = apply([candidate(u: 0.5, v: 0.3, look: [1, 0, 0, 0], name: name("코카콜라")),
                       candidate(u: 2.5, v: 1.3, look: [1, 0, 0, 0], name: name("코카콜라"))])
        XCTAssertEqual(d.products.count, 1)
        XCTAssertEqual(d.placements.count, 2)
    }

    func testOldSavedDataStillDecodes() throws {
        let old = """
        {"id":"p","name":"제품 1","createdAt":0,"imageFileNames":[],"embeddings":[],"colorDescriptors":[],
         "similarProductIds":[],"needsReview":false,"reviewReasons":[]}
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let p = try dec.decode(ShelfProduct.self, from: Data(old.utf8))
        XCTAssertNil(p.nameSource)
        XCTAssertFalse(p.nameIsProtected, "a placeholder is not protected")
    }

    // MARK: Search session

    private func matched(_ id: String) -> ShelfMatchOutcome { .matched(ShelfMatchCandidate(productId: id, distance: 0.1)) }
    private func uncertain(_ ids: [String]) -> ShelfMatchOutcome {
        .uncertain(ids.map { ShelfMatchCandidate(productId: $0, distance: 0.3) })
    }

    func testStableMatchLocksOnceAndLaterFramesAreIgnored() {
        var s = ShelfSearchSession()
        var events: [ShelfSearchSession.Event] = []
        for i in 0..<4 { if let e = s.ingest(matched("a"), time: Double(i)) { events.append(e) } }
        XCTAssertEqual(events, [.locked(productId: "a", source: .image)])
        // while walking to the target the camera sees other products: nothing changes
        for i in 4..<20 { XCTAssertNil(s.ingest(matched("b"), time: Double(i))) }
        XCTAssertEqual(s.lockedProductId, "a")
        XCTAssertEqual(s.lockCount, 1)
        XCTAssertTrue(s.recognitionPaused)
    }

    func testAlternatingResultsNeverLock() {
        var s = ShelfSearchSession()
        for i in 0..<30 { _ = s.ingest(matched(i % 2 == 0 ? "a" : "b"), time: Double(i)) }
        XCTAssertEqual(s.state, .searching)
        XCTAssertEqual(s.lockCount, 0)
    }

    func testOneLuckyFrameDoesNotLock() {
        var s = ShelfSearchSession()
        _ = s.ingest(matched("a"), time: 0)
        _ = s.ingest(.unregistered(bestDistance: 0.6), time: 1)
        _ = s.ingest(.unregistered(bestDistance: 0.6), time: 2)
        XCTAssertNotEqual(s.lockedProductId, "a")
    }

    func testUncertainShowsCandidatesAndNeverLocksByItself() {
        var s = ShelfSearchSession()
        var last: ShelfSearchSession.Event?
        for i in 0..<5 { if let e = s.ingest(uncertain(["a", "b"]), time: Double(i)) { last = e } }
        XCTAssertEqual(last, .candidates)
        XCTAssertFalse(s.isLocked)
        // text from the package settles it, but only among the listed candidates
        XCTAssertNil(s.settleWithText(productId: "zzz"))
        XCTAssertEqual(s.settleWithText(productId: "b"), .locked(productId: "b", source: .text))
    }

    func testUnregisteredIsShownAndNeverForcedToTheNearest() {
        var s = ShelfSearchSession()
        var events: [ShelfSearchSession.Event] = []
        for i in 0..<6 { if let e = s.ingest(.unregistered(bestDistance: 0.7), time: Double(i)) { events.append(e) } }
        XCTAssertEqual(events, [.unregistered])
        XCTAssertEqual(s.state, .unregistered)
    }

    func testStaleCandidatesClearWhenNoProductIsInView() {
        var s = ShelfSearchSession()
        for i in 0..<5 { _ = s.ingest(uncertain(["a", "b"]), time: Double(i)) }
        var cleared = false
        for _ in 0..<6 { if s.ingestEmpty() == .cleared { cleared = true } }
        XCTAssertTrue(cleared)
        XCTAssertEqual(s.state, .searching)
    }

    func testReleaseAllowsAnotherProductAndBlocksTheSameOneBriefly() {
        var s = ShelfSearchSession()
        for i in 0..<4 { _ = s.ingest(matched("a"), time: Double(i)) }
        XCTAssertEqual(s.release(now: 10), .released)
        XCTAssertEqual(s.state, .searching)
        // the camera still looks at "a": not locked again inside the cool-down
        for i in 0..<6 { XCTAssertNil(s.ingest(matched("a"), time: 10 + Double(i) * 0.4)) }
        XCTAssertFalse(s.isLocked)
        // another product locks normally
        var lockedB = false
        for i in 0..<6 { if s.ingest(matched("b"), time: 12 + Double(i) * 0.4) != nil { lockedB = true } }
        XCTAssertTrue(lockedB)
        XCTAssertEqual(s.lockedProductId, "b")
        // after the cool-down "a" can be found again
        _ = s.release(now: 20)
        for i in 0..<6 { _ = s.ingest(matched("a"), time: 30 + Double(i)) }
        XCTAssertEqual(s.lockedProductId, "a")
    }

    func testManualLockAndNoGalleryAreHandled() {
        var s = ShelfSearchSession()
        XCTAssertNil(s.ingest(.noGallery, time: 0))
        XCTAssertEqual(s.lock(productId: "n", source: .name), .locked(productId: "n", source: .name))
        XCTAssertNil(s.ingest(matched("a"), time: 1))
    }

    func testPhotoResultIsShownAtOnce() {
        var s = ShelfSearchSession()
        XCTAssertEqual(s.present(matched("a"), source: .photo), .locked(productId: "a", source: .photo))
        var s2 = ShelfSearchSession()
        XCTAssertEqual(s2.present(uncertain(["a", "b"]), source: .photo), .candidates)
        XCTAssertFalse(s2.isLocked)
        var s3 = ShelfSearchSession()
        XCTAssertEqual(s3.present(.unregistered(bestDistance: 0.9), source: .photo), .unregistered)
    }

    func testNameSearchFindsReadTextAndCatalogNames() {
        var p1 = ShelfProduct(id: "p1", name: "제품 4", createdAt: Date(), imageFileNames: [], embeddings: [], colorDescriptors: [],
                              similarProductIds: [], needsReview: false, reviewReasons: [])
        p1.ocrTokens = ["코카콜라제로", "cocacola"]
        let p2 = ShelfProduct(id: "p2", name: "펩시", createdAt: Date(), imageFileNames: [], embeddings: [], colorDescriptors: [],
                              similarProductIds: [], needsReview: false, reviewReasons: [])
        XCTAssertEqual(ShelfNameSearch.search("코카콜라", products: [p1, p2]).map(\.id), ["p1"], "text read on the pack is searchable")
        XCTAssertEqual(ShelfNameSearch.search("coca", products: [p1, p2]).map(\.id), ["p1"])
        XCTAssertEqual(ShelfNameSearch.search("공식명", products: [p1, p2], aliases: ["p2": ["공식명 500ml"]]).map(\.id), ["p2"])
    }
}
