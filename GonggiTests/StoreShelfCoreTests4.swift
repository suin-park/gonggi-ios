import XCTest
@testable import Gonggi

/// Detection scoring arithmetic (pure; also runs on Linux).
final class StoreShelfCoreTests4: XCTestCase {
    private func r(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> StoreImageSpace.PixelRect {
        StoreImageSpace.PixelRect(minU: a, minV: b, maxU: c, maxV: d)
    }

    func testPerfectAndMissedAndFalsePositive() {
        let truth = [r(0, 0, 100, 200), r(120, 0, 220, 200), r(240, 0, 340, 200)]
        let preds = [r(2, 3, 98, 198), r(122, 1, 219, 202), r(500, 0, 560, 40)]   // third product missed, one tag detected
        let e = ShelfDetectionEvaluator.evaluate(predictions: preds, truth: truth)
        XCTAssertEqual(e.detected, 2)
        XCTAssertEqual(e.missed, 1)
        XCTAssertEqual(e.falsePositives, 1)
        XCTAssertEqual(e.merged, 0)
        XCTAssertEqual(e.split, 0)
        XCTAssertEqual(e.detectionRate, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(e.precision, 2.0 / 3.0, accuracy: 1e-9)
    }

    func testMergedProductsAreCounted() {
        let truth = [r(0, 0, 100, 200), r(110, 0, 210, 200)]
        let preds = [r(0, 0, 210, 200)]    // one region over two products
        let e = ShelfDetectionEvaluator.evaluate(predictions: preds, truth: truth)
        XCTAssertEqual(e.merged, 1)
        XCTAssertEqual(e.detected, 0)
        XCTAssertEqual(e.missed, 2)
        XCTAssertEqual(e.falsePositives, 0)
    }

    func testSplitProductIsCounted() {
        let truth = [r(0, 0, 100, 200)]
        let preds = [r(0, 0, 100, 95), r(0, 105, 100, 200)]   // one product in two pieces, neither half matches on its own
        let e = ShelfDetectionEvaluator.evaluate(predictions: preds, truth: truth)
        XCTAssertEqual(e.split, 1)
        XCTAssertEqual(e.detected, 0)
        XCTAssertEqual(e.missed, 0)
        XCTAssertEqual(e.falsePositives, 0)
        XCTAssertEqual(e.wrongSegmentationRate, 1.0, accuracy: 1e-9)
    }

    func testAccumulate() {
        let a = ShelfDetectionEvaluator.evaluate(predictions: [r(0, 0, 10, 10)], truth: [r(0, 0, 10, 10)])
        let b = ShelfDetectionEvaluator.evaluate(predictions: [], truth: [r(0, 0, 10, 10)])
        let t = a + b
        XCTAssertEqual(t.truthCount, 2)
        XCTAssertEqual(t.detected, 1)
        XCTAssertEqual(t.missed, 1)
        XCTAssertEqual(t.detectionRate, 0.5, accuracy: 1e-9)
    }
}
