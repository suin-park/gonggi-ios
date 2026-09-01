import simd
import XCTest
@testable import Gonggi

final class CaptureMathTests: XCTestCase {
    func testTranslationDistance() {
        var a = matrix_identity_float4x4
        var b = matrix_identity_float4x4
        b.columns.3 = SIMD4<Float>(1, 0, 0, 1)
        let d = CaptureMath.translationMeters(from: a, to: b)
        XCTAssertEqual(d, 1, accuracy: 0.001)
    }

    func testRotationDeltaZeroForSameOrientation() {
        let t = matrix_identity_float4x4
        let delta = CaptureMath.rotationDeltaRadians(from: t, to: t)
        XCTAssertEqual(delta, 0, accuracy: 0.001)
    }

    func testViewBucketStable() {
        let t = matrix_identity_float4x4
        let b1 = CaptureMath.viewBucket(for: t)
        let b2 = CaptureMath.viewBucket(for: t)
        XCTAssertEqual(b1, b2)
    }

    func testGridCellIdQuantization() {
        let id1 = CaptureMath.gridCellId(position: SIMD3<Float>(0.1, 0.1, 0.1))
        let id2 = CaptureMath.gridCellId(position: SIMD3<Float>(0.4, 0.4, 0.4))
        XCTAssertEqual(id1, id2)
        let id3 = CaptureMath.gridCellId(position: SIMD3<Float>(0.6, 0.1, 0.1))
        XCTAssertNotEqual(id1, id3)
    }

    func testSpeeds() {
        let (v, w) = CaptureMath.speeds(translationM: 1, rotationRad: 0.5, deltaTimeSec: 1)
        XCTAssertEqual(v, 1, accuracy: 0.001)
        XCTAssertEqual(w, 0.5, accuracy: 0.001)
    }
}
