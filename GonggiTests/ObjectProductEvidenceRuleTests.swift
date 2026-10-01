import XCTest
@testable import Gonggi

/// The shared product-extent rule (rule v1) on synthetic label maps. No Vision here: the rule takes a label map, so the
/// same source is exercised on Linux and macOS and compiled into the offline validation tool.
final class ObjectProductEvidenceRuleTests: XCTestCase {
    private let w = 64
    private let h = 48

    private struct Canvas {
        var labels: [UInt8]
        var luma: [UInt8]
        let w: Int
        let h: Int

        init(w: Int, h: Int, background: UInt8 = 80) {
            self.w = w
            self.h = h
            labels = [UInt8](repeating: 0, count: w * h)
            luma = [UInt8](repeating: background, count: w * h)
        }

        /// Fills the normalised rectangle [x0, x1) x [y0, y1).
        mutating func fill(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, id: UInt8, luma value: UInt8) {
            let px0 = Int((x0 * Double(w)).rounded()), px1 = Int((x1 * Double(w)).rounded())
            let py0 = Int((y0 * Double(h)).rounded()), py1 = Int((y1 * Double(h)).rounded())
            for y in max(0, py0)..<min(h, py1) {
                for x in max(0, px0)..<min(w, px1) {
                    labels[y * w + x] = id
                    luma[y * w + x] = value
                }
            }
        }

        /// Sets luma only (a bright strip the segmenter did not label).
        mutating func paintLuma(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, value: UInt8) {
            let px0 = Int((x0 * Double(w)).rounded()), px1 = Int((x1 * Double(w)).rounded())
            let py0 = Int((y0 * Double(h)).rounded()), py1 = Int((y1 * Double(h)).rounded())
            for y in max(0, py0)..<min(h, py1) {
                for x in max(0, px0)..<min(w, px1) {
                    luma[y * w + x] = value
                }
            }
        }
    }

    private func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [CGPoint] {
        [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0), CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1)]
    }

    /// Box hull that sticks out of the top of the photo, and its bottom face near the lower edge.
    private var clippedHull: [CGPoint] { rect(0.12, -0.10, 0.88, 0.97) }
    private var baseFace: [CGPoint] {
        [CGPoint(x: 0.28, y: 0.80), CGPoint(x: 0.72, y: 0.80), CGPoint(x: 0.78, y: 0.95), CGPoint(x: 0.22, y: 0.95)]
    }

    private func evaluate(_ c: Canvas, hull: [CGPoint]? = nil, base: [CGPoint]? = nil, luma: Bool = true) -> ObjectProductEvidence {
        ObjectProductEvidenceRule.evaluate(.init(
            labels: c.labels, luma: luma ? c.luma : nil, width: c.w, height: c.h,
            hull: hull ?? clippedHull, baseFace: base ?? baseFace
        ))
    }

    private func wholeProduct() -> Canvas {
        var c = Canvas(w: w, h: h)
        c.fill(0.30, 0.15, 0.70, 0.90, id: 1, luma: 200)
        return c
    }

    // MARK: - Rule

    func testWholeProductInsideWithBoxSticksOutIsInFrameWithItsExtent() {
        guard case .productInFrame(let r) = evaluate(wholeProduct()) else {
            return XCTFail("expected positive evidence")
        }
        XCTAssertEqual(r.minX, 0.30, accuracy: 0.03)
        XCTAssertEqual(r.maxX, 0.70, accuracy: 0.03)
        XCTAssertEqual(r.minY, 0.15, accuracy: 0.03)
        XCTAssertEqual(r.maxY, 0.90, accuracy: 0.03)
    }

    func testProductAtThePhotoEdgeIsCutOff() {
        var c = Canvas(w: w, h: h)
        c.fill(0.0, 0.15, 0.50, 0.90, id: 1, luma: 200) // starts at the left edge
        XCTAssertEqual(evaluate(c), .productCutOff)
        var top = Canvas(w: w, h: h)
        top.fill(0.30, 0.0, 0.70, 0.80, id: 1, luma: 200) // an ear leaves the top
        XCTAssertEqual(evaluate(top), .productCutOff)
    }

    func testTwoCompetingObjectsInTheBoxAreNotDecided() {
        var c = wholeProduct()
        c.fill(0.72, 0.30, 0.88, 0.90, id: 2, luma: 150) // about 31% of the main object's area
        XCTAssertEqual(evaluate(c), .unknown(.multipleCandidates))
    }

    func testAnObjectLeavingTheBoxIsNotTheProduct() {
        var floor = Canvas(w: w, h: h)
        floor.fill(0.0, 0.55, 1.0, 0.99, id: 1, luma: 120) // a table or floor band across the whole photo
        floor.fill(0.30, 0.20, 0.70, 0.55, id: 1, luma: 120)
        XCTAssertEqual(evaluate(floor, hull: rect(0.30, 0.10, 0.70, 0.95)), .unknown(.maskLeavesBox))
    }

    func testNoForegroundOrNothingInTheBox() {
        XCTAssertEqual(evaluate(Canvas(w: w, h: h)), .unknown(.noCandidateInBox))
        var elsewhere = Canvas(w: w, h: h)
        elsewhere.fill(0.90, 0.02, 0.99, 0.10, id: 1, luma: 200)
        XCTAssertEqual(evaluate(elsewhere), .unknown(.noCandidateInBox))
    }

    func testAFragmentThatDoesNotStandOnTheBoxFootprintIsNotAccepted() {
        var c = Canvas(w: w, h: h)
        c.fill(0.30, 0.10, 0.70, 0.45, id: 1, luma: 200) // only the upper part; the footprint is empty
        XCTAssertEqual(evaluate(c), .unknown(.baseNotTouched))
    }

    func testObjectNotInsideTheBoxProjection() {
        var c = Canvas(w: w, h: h)
        let hull = rect(0.30, 0.20, 0.70, 0.95)
        c.fill(0.30, 0.20, 0.70, 0.90, id: 1, luma: 200)
        c.fill(0.70, 0.45, 0.95, 0.50, id: 1, luma: 200) // a tail running far outside the box
        XCTAssertEqual(evaluate(c, hull: hull), .unknown(.notInsideBox))
    }

    func testTooSmallOrTooLargeOrTooCloseToTheEdge() {
        var small = Canvas(w: w, h: h)
        small.fill(0.42, 0.70, 0.58, 0.88, id: 1, luma: 200)
        XCTAssertEqual(evaluate(small), .unknown(.sizeOutOfRange))
        var near = Canvas(w: w, h: h)
        near.fill(0.30, 1.0 / 48.0, 0.70, 0.90, id: 1, luma: 200) // one pixel below the touch band
        XCTAssertEqual(evaluate(near), .unknown(.tooCloseToEdge))
    }

    func testBoxBottomFaceOutsideThePhotoCannotBeChecked() {
        let c = wholeProduct()
        let lowBase = [CGPoint(x: 0.28, y: 1.10), CGPoint(x: 0.72, y: 1.10), CGPoint(x: 0.78, y: 1.30), CGPoint(x: 0.22, y: 1.30)]
        XCTAssertEqual(evaluate(c, base: lowBase), .unknown(.baseNotVisible))
        XCTAssertEqual(evaluate(c, base: [CGPoint(x: 0.5, y: 0.9)]), .unknown(.baseNotVisible), "a footprint needs at least 3 points")
    }

    /// The mask can miss part of the product. If the strip along a clipped edge looks like the product, do not say "whole".
    func testBrightStripAlongAClippedEdgeMeansTheProductMayContinue() {
        var c = wholeProduct()
        c.paintLuma(0.0, 0.0, 1.0, 0.05, value: 195) // unlabelled, but as bright as the product
        XCTAssertEqual(evaluate(c), .unknown(.productMayContinue))
        // A background-like strip is fine.
        var plain = wholeProduct()
        plain.paintLuma(0.0, 0.0, 1.0, 0.05, value: 82)
        if case .productInFrame = evaluate(plain) {} else { XCTFail("a background-like strip must not block") }
    }

    func testClippedBoxWithoutLumaFallsBackAndBadInputIsAFailure() {
        XCTAssertEqual(evaluate(wholeProduct(), luma: false), .unknown(.failed))
        let bad = ObjectProductEvidenceRule.evaluate(.init(
            labels: [0, 1, 2], luma: nil, width: 64, height: 48, hull: clippedHull, baseFace: baseFace
        ))
        XCTAssertEqual(bad, .unknown(.failed))
        let noHull = ObjectProductEvidenceRule.evaluate(.init(
            labels: wholeProduct().labels, luma: wholeProduct().luma, width: 64, height: 48, hull: [], baseFace: baseFace
        ))
        XCTAssertEqual(noHull, .unknown(.failed))
    }

    func testRuleVersionOneThresholdsAreTheOnesFixedBeforeValidation() {
        // docs/OBJECT_VISION_VALIDATION_CRITERIA.md fixes these before any result is seen; changing one here means
        // the validation no longer describes the shipped rule.
        let c = ObjectEvidenceRuleConfig.v1
        XCTAssertEqual(c.edgeBandFraction, 0.01)
        XCTAssertEqual(c.safeMarginFraction, 0.03)
        XCTAssertEqual(c.hullScale, 1.08)
        XCTAssertEqual(c.minCandidateAreaFraction, 0.01)
        XCTAssertEqual(c.dominantAreaRatio, 0.25)
        XCTAssertEqual(c.maxMaskOutsideHull, 0.35)
        XCTAssertEqual(c.minLongSide, 0.25)
        XCTAssertEqual(c.maxLongSide, 0.85)
        XCTAssertEqual(c.boxBoundsSlack, 0.10)
        XCTAssertEqual(c.baseMinVisible, 0.80)
        XCTAssertEqual(c.baseScale, 1.15)
        XCTAssertEqual(c.baseMinCoverage, 0.10)
        XCTAssertEqual(c.stripFraction, 0.03)
        XCTAssertEqual(c.continuityRatio, 0.6)
        XCTAssertEqual(c.continuityMinContrast, 3.0)
        XCTAssertEqual(c.continuityMinSamples, 50)
    }
}
