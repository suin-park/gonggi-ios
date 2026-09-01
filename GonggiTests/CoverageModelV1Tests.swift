import simd
import XCTest
@testable import Gonggi

final class CoverageModelV1Tests: XCTestCase {
    func testSingleObservationNotGood() {
        var model = CoverageModelV1()
        let t = matrix_identity_float4x4
        model.observe(cameraTransform: t, motionQuality: 1.0)
        let area = model.areas.first!
        XCTAssertNotEqual(area.state, .good)
        XCTAssertEqual(area.observationCount, 1)
    }

    func testMultipleViewsCanReachGood() {
        var model = CoverageModelV1()
        for i in 0..<8 {
            var t = matrix_identity_float4x4
            let angle = Float(i) * 0.4
            t.columns.2 = SIMD4<Float>(sin(angle), 0, -cos(angle), 0)
            t.columns.0 = SIMD4<Float>(cos(angle), 0, sin(angle), 0)
            model.observe(cameraTransform: t, motionQuality: 0.9)
        }
        let goodCount = model.areas.filter { $0.state == .good }.count
        XCTAssertGreaterThan(goodCount, 0)
    }

    func testOverallCoverageIncreases() {
        var model = CoverageModelV1()
        XCTAssertEqual(model.overallCoverage, 0)
        for i in 0..<5 {
            var t = matrix_identity_float4x4
            t.columns.3 = SIMD4<Float>(Float(i) * 0.6, 0, 0, 1)
            model.observe(cameraTransform: t, motionQuality: 0.8)
        }
        XCTAssertGreaterThan(model.overallCoverage, 0)
    }

    func testLiDARAloneDoesNotMarkGood() {
        var model = CoverageModelV1()
        model.observe(cameraTransform: matrix_identity_float4x4, motionQuality: 1.0)
        XCTAssertNotEqual(model.areas.first?.state, .good)
    }
}
