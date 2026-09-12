import XCTest
@testable import Gonggi

final class GuidanceRuleEngineTests: XCTestCase {
    func testHighAngularVelocityPrefersSlowDown() {
        var engine = GuidanceRuleEngine()
        var quality = CaptureQualityState.zero
        quality.angularVelocity = 1.5
        quality.trackingQuality = 0.9
        quality.overlapAvailable = true
        quality.overlapState = .good
        let decision = engine.evaluateDecision(quality: quality, trackingLimited: false)
        XCTAssertEqual(decision.action, .slowDown)
        XCTAssertEqual(decision.message, CaptureGuidanceCopy.message(for: .slowDown))
    }

    func testTrackingLimitedPriority() {
        var engine = GuidanceRuleEngine()
        var quality = CaptureQualityState.zero
        quality.angularVelocity = 1.5
        quality.motionSpeed = 0.8
        quality.overlapAvailable = true
        quality.overlapState = .lost
        let decision = engine.evaluateDecision(quality: quality, trackingLimited: true)
        XCTAssertEqual(decision.action, .trackingRecovery)
    }

    func testOverlapLostReturnToPrevious() {
        var engine = GuidanceRuleEngine()
        var quality = CaptureQualityState.zero
        quality.trackingQuality = 0.95
        quality.overlapAvailable = true
        quality.overlapState = .lost
        let decision = engine.evaluateDecision(quality: quality, trackingLimited: false)
        XCTAssertEqual(decision.action, .returnToPreviousArea)
    }

    func testInsufficientBaselineImprove() {
        var engine = GuidanceRuleEngine()
        var quality = CaptureQualityState.zero
        quality.trackingQuality = 0.95
        quality.overlapAvailable = true
        quality.overlapState = .good
        quality.observedCoverage = 0.2
        quality.translationBaselineGrade = .insufficient
        quality.motionSpeed = 0.1
        quality.angularVelocity = 0.1
        let decision = engine.evaluateDecision(quality: quality, trackingLimited: false)
        XCTAssertTrue(
            decision.action == .improveBaseline || decision.action == .moveLaterally,
            "Expected baseline/lateral guidance, got \(decision.action)"
        )
    }

    func testCooldownPreventsSpam() {
        var engine = GuidanceRuleEngine()
        engine.cooldownSec = 10
        var quality = CaptureQualityState.zero
        quality.angularVelocity = 1.5
        quality.trackingQuality = 0.9
        _ = engine.evaluateDecision(quality: quality, trackingLimited: false)
        quality.angularVelocity = 0.1
        quality.motionSpeed = 0.1
        let second = engine.evaluateDecision(quality: quality, trackingLimited: false)
        XCTAssertEqual(second.action, .slowDown)
    }
}
