import XCTest
@testable import Gonggi

final class GuidanceRuleEngineTests: XCTestCase {
    func testHighAngularVelocityMessage() {
        var engine = GuidanceRuleEngine()
        var quality = CaptureQualityState.zero
        quality.angularVelocity = 1.5
        quality.trackingQuality = 0.9
        let msg = engine.evaluate(quality: quality, trackingLimited: false)
        XCTAssertEqual(msg, "천천히 회전하세요")
    }

    func testTrackingLimitedPriority() {
        var engine = GuidanceRuleEngine()
        var quality = CaptureQualityState.zero
        quality.angularVelocity = 1.5
        quality.motionSpeed = 0.8
        let msg = engine.evaluate(quality: quality, trackingLimited: true)
        XCTAssertEqual(msg, "카메라를 천천히 움직여 위치를 다시 잡아주세요")
    }

    func testCooldownPreventsSpam() {
        var engine = GuidanceRuleEngine()
        engine.cooldownSec = 10
        var quality = CaptureQualityState.zero
        quality.angularVelocity = 1.5
        _ = engine.evaluate(quality: quality, trackingLimited: false)
        quality.angularVelocity = 0.1
        quality.motionSpeed = 0.1
        let second = engine.evaluate(quality: quality, trackingLimited: false)
        XCTAssertEqual(second, "천천히 회전하세요")
    }

    func testAngleDiversityRule() {
        var engine = GuidanceRuleEngine()
        var quality = CaptureQualityState.zero
        quality.areas = [
            AreaCoverage(id: "0_0_0", observationCount: 3, uniqueViewCount: 1, angleDiversity: 0.1, state: .insufficient),
        ]
        let decision = engine.bestDecision(quality: quality, trackingLimited: false)
        XCTAssertTrue(
            decision.message.contains("각도") || decision.message.contains("영역"),
            "Expected area or angle guidance"
        )
    }
}
