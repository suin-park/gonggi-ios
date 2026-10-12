import XCTest
@testable import Gonggi

/// Recognition scoring and fixture label parsing (pure; also runs on Linux).
final class StoreShelfCoreTests5: XCTestCase {
    private func matched(_ id: String) -> ShelfMatchOutcome { .matched(ShelfMatchCandidate(productId: id, distance: 0.1)) }
    private func uncertain(_ ids: [String]) -> ShelfMatchOutcome {
        .uncertain(ids.map { ShelfMatchCandidate(productId: $0, distance: 0.3) })
    }

    func testRegisteredProductOutcomes() {
        let samples = [
            ShelfRecognitionSample(truthProductId: "cola", outcome: matched("cola")),          // correct
            ShelfRecognitionSample(truthProductId: "cola", outcome: matched("cola-zero")),     // wrong, a look-alike variant
            ShelfRecognitionSample(truthProductId: "juice", outcome: matched("water")),        // wrong, unrelated
            ShelfRecognitionSample(truthProductId: "tea", outcome: uncertain(["tea", "cola"])),// recoverable
            ShelfRecognitionSample(truthProductId: "tea", outcome: uncertain(["cola"])),       // not recoverable
            ShelfRecognitionSample(truthProductId: "milk", outcome: .unregistered(bestDistance: 0.9)),
        ]
        let e = ShelfRecognitionEvaluator.evaluate(samples, similar: [["cola", "cola-zero"]])
        XCTAssertEqual(e.registeredCount, 6)
        XCTAssertEqual(e.matchedCorrect, 1)
        XCTAssertEqual(e.matchedWrong, 2)
        XCTAssertEqual(e.matchedWrongVariant, 1)
        XCTAssertEqual(e.uncertainWithTruth, 1)
        XCTAssertEqual(e.uncertainWithoutTruth, 1)
        XCTAssertEqual(e.falseRejected, 1)
        XCTAssertEqual(e.top1Accuracy, 1.0 / 6.0, accuracy: 1e-9)
        XCTAssertEqual(e.reachableRate, 2.0 / 6.0, accuracy: 1e-9)
        XCTAssertEqual(e.wrongConfirmationRate, 2.0 / 3.0, accuracy: 1e-9)
    }

    func testUnregisteredProductOutcomes() {
        let samples = [
            ShelfRecognitionSample(truthProductId: nil, outcome: .unregistered(bestDistance: 0.8)),
            ShelfRecognitionSample(truthProductId: nil, outcome: matched("cola")),
            ShelfRecognitionSample(truthProductId: nil, outcome: uncertain(["cola", "tea"])),
            ShelfRecognitionSample(truthProductId: nil, outcome: .unregistered(bestDistance: nil)),
        ]
        let e = ShelfRecognitionEvaluator.evaluate(samples)
        XCTAssertEqual(e.unregisteredCount, 4)
        XCTAssertEqual(e.correctlyRejected, 2)
        XCTAssertEqual(e.falselyMatched, 1)
        XCTAssertEqual(e.shownAsUncertain, 1)
        XCTAssertEqual(e.unregisteredRejectionRate, 0.5, accuracy: 1e-9)
        XCTAssertEqual(e.falseMatchRateOnUnregistered, 0.25, accuracy: 1e-9)
        XCTAssertEqual(e.wrongConfirmationRate, 1.0, accuracy: 1e-9)
    }

    func testAccumulate() {
        let a = ShelfRecognitionEvaluator.evaluate([ShelfRecognitionSample(truthProductId: "a", outcome: matched("a"))])
        let b = ShelfRecognitionEvaluator.evaluate([ShelfRecognitionSample(truthProductId: nil, outcome: matched("a"))])
        let t = a + b
        XCTAssertEqual(t.registeredCount, 1)
        XCTAssertEqual(t.unregisteredCount, 1)
        XCTAssertEqual(t.wrongConfirmationRate, 0.5, accuracy: 1e-9)
    }

    func testLabelParsing() {
        let plain = Data(#"{"boxes": [[0,0,10,20],[30,40,50,60]]}"#.utf8)
        let p = ShelfPhotoLabels.parse(plain)
        XCTAssertEqual(p?.boxes.count, 2)
        XCTAssertEqual(p?.role, "register")
        XCTAssertEqual(p?.split, "eval")
        XCTAssertNil(p?.boxes[0].productId)

        let rich = Data(#"""
        {"role":"search","split":"tune","boxes":[{"rect":[1,2,3,4],"productId":"cola500"},{"rect":[5,6,7,8],"productId":null},
                                                   {"rect":[9,9,19,19],"productId":""}]}
        """#.utf8)
        let r = ShelfPhotoLabels.parse(rich)
        XCTAssertEqual(r?.role, "search")
        XCTAssertEqual(r?.split, "tune")
        XCTAssertEqual(r?.boxes.map(\.productId), ["cola500", nil, nil])
        XCTAssertEqual(r?.boxes[0].rect.maxV, 4)

        XCTAssertNil(ShelfPhotoLabels.parse(Data("{}".utf8)))
        XCTAssertNil(ShelfPhotoLabels.parse(Data(#"{"boxes":[[1,2,3]]}"#.utf8)))
    }
}
