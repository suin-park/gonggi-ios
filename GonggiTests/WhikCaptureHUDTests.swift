import Foundation
import XCTest
@testable import Gonggi

/// Shared capture HUD (3.1(38)): the three capture modes map their state onto one guide card with the same tones.
final class WhikCaptureHUDTests: XCTestCase {
    private func spaceQuality(saved: Int = 0) -> CaptureQualityState {
        var q = CaptureQualityState.zero
        q.capturePhase = .coverageFill
        q.trackingQuality = 0.95
        q.spatialKeyframeEnqueueCount = saved
        return q
    }

    func testSpaceGuideShowsTheFreeCaptureTipWhenNothingNeedsFixing() {
        let g = CaptureQuietUIPresenter.guide(for: spaceQuality(saved: 0))
        XCTAssertEqual(g.title, L("Point freely around the space"))
        XCTAssertEqual(g.subtitle, L("Now and then, slowly point at the opposite side too"))
        XCTAssertEqual(g.tone, .normal)
        let later = CaptureQuietUIPresenter.guide(for: spaceQuality(saved: CaptureUIPresenter.captureTipEveryPhotos))
        XCTAssertNotEqual(later.subtitle, g.subtitle, "the tip changes as photos are saved")
    }

    func testSpaceGuideRecognizingReadyAndStorageCap() {
        var q = spaceQuality()
        q.capturePhase = .stabilizing
        XCTAssertEqual(CaptureQuietUIPresenter.guide(for: q).title, L("Recognizing the space"))

        q = spaceQuality(saved: 120)
        q.completionState = .ready
        let ready = CaptureQuietUIPresenter.guide(for: q)
        XCTAssertEqual(ready.tone, .done)
        XCTAssertEqual(ready.subtitle, L("Tap Capture complete, or keep capturing"))

        q = spaceQuality(saved: SpatialCaptureConfig.candidateSafetyCap)
        q.candidateSafetyCapReached = true
        let cap = CaptureQuietUIPresenter.guide(for: q)
        XCTAssertEqual(cap.tone, .warning)
        XCTAssertEqual(cap.title, L("New photos are no longer being saved"))
    }

    func testSpaceGuideCorrectionIsAWarning() {
        var q = spaceQuality(saved: 10)
        q.motionSpeed = 0.9
        let g = CaptureQuietUIPresenter.guide(for: q)
        XCTAssertEqual(g.tone, .warning)
        XCTAssertEqual(g.title, L("Move a little more slowly"))
    }

    func test360GuideByPhase() {
        let idle = DirectionCaptureView.guide(phase: .idle, phaseTitle: "", guideText: "", isPhotoPending: false)
        XCTAssertEqual(idle.title, L("Look around from one spot"))
        XCTAssertEqual(idle.subtitle, L("Tap Start capture to begin"))
        let turning = DirectionCaptureView.guide(phase: .capturingHorizontal, phaseTitle: L("One turn at eye level"),
                                                 guideText: "hint", isPhotoPending: false)
        XCTAssertEqual(turning.title, L("One turn at eye level"))
        XCTAssertEqual(turning.subtitle, "hint")
        XCTAssertEqual(turning.tone, .normal)
        XCTAssertEqual(DirectionCaptureView.guide(phase: .failed("x"), phaseTitle: "", guideText: "",
                                                  isPhotoPending: false).tone, .warning)
        XCTAssertEqual(DirectionCaptureView.guide(phase: .completed, phaseTitle: "", guideText: "",
                                                  isPhotoPending: false).tone, .done)
    }

    func testWarningIsHeldBrieflySoTheCardDoesNotFlicker() {
        var hold = WhikCaptureGuideHold()
        let t0 = Date(timeIntervalSince1970: 1000)
        let warn = WhikCaptureGuide(title: "slow", tone: .warning)
        let tip = WhikCaptureGuide(title: "tip")
        XCTAssertEqual(hold.resolve(warn, at: t0), warn)
        XCTAssertEqual(hold.resolve(tip, at: t0.addingTimeInterval(1)), warn)
        XCTAssertEqual(hold.resolve(tip, at: t0.addingTimeInterval(WhikCaptureGuideHold.holdSec + 0.1)), tip)
    }

    func testObjectFinishUsesTheSharedEndCaptureLabel() {
        XCTAssertEqual(ObjectCaptureCopy.finish, L("End capture"))
    }
}
