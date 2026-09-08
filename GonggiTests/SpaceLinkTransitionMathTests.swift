import XCTest
@testable import Gonggi

final class SpaceLinkTransitionMathTests: XCTestCase {
    func testShortestYawIsCappedForLargeDelta() {
        let delta = SpaceLinkTransitionMath.cappedShortestYawDelta(from: 0, to: 170)
        XCTAssertEqual(abs(delta), SpaceLinkTransitionMath.maxYawRotationDeg, accuracy: 0.01)
        XCTAssertGreaterThan(delta, 0)
    }

    func testShortestYawKeepsSmallDelta() {
        let delta = SpaceLinkTransitionMath.cappedShortestYawDelta(from: 10, to: 40)
        XCTAssertEqual(delta, 30, accuracy: 0.01)
    }

    func testShortestYawUsesSeamPath() {
        let delta = SpaceLinkTransitionMath.cappedShortestYawDelta(from: 170, to: -170)
        // +20° shortest across seam, under cap.
        XCTAssertEqual(delta, 20, accuracy: 0.5)
    }

    func testEaseInOutCubicBounds() {
        XCTAssertEqual(SpaceLinkTransitionMath.easeInOutCubic(0), 0, accuracy: 1e-6)
        XCTAssertEqual(SpaceLinkTransitionMath.easeInOutCubic(1), 1, accuracy: 1e-6)
        XCTAssertGreaterThan(SpaceLinkTransitionMath.easeInOutCubic(0.5), 0.4)
        XCTAssertLessThan(SpaceLinkTransitionMath.easeInOutCubic(0.5), 0.6)
    }
}
