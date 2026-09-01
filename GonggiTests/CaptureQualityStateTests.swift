import XCTest
@testable import Gonggi

final class CaptureQualityStateTests: XCTestCase {
    func testZeroDefaults() {
        let q = CaptureQualityState.zero
        XCTAssertEqual(q.overallCoverage, 0)
        XCTAssertEqual(q.progressPercent, 0)
        XCTAssertEqual(q.blurScore, 1)
    }

    func testProgressPercentRounding() {
        var q = CaptureQualityState.zero
        q.overallCoverage = 0.856
        XCTAssertEqual(q.progressPercent, 86)
    }

    func testAreaCoverageCodable() throws {
        let area = AreaCoverage(
            id: "1_0_0",
            observationCount: 3,
            uniqueViewCount: 2,
            angleDiversity: 0.4,
            revisitCount: 1,
            coverageScore: 0.5,
            state: .acceptable
        )
        let data = try JSONEncoder().encode(area)
        let decoded = try JSONDecoder().decode(AreaCoverage.self, from: data)
        XCTAssertEqual(decoded, area)
    }
}
