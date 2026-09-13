import XCTest
@testable import Gonggi

@MainActor
final class PrimaryGuidancePresenterTests: XCTestCase {
    func testOverlapLostSuppressesAstraAndShowsReturnGuidance() {
        var quality = CaptureQualityState.zero
        quality.trackingQuality = 0.95
        quality.overlapAvailable = true
        quality.overlapState = .lost
        quality.guidanceAction = .returnToPreviousArea
        quality.completionState = .notReady
        quality.qualityCoverage = 0.58

        let state = CaptureUIPresenter.primaryGuidance(
            quality: quality,
            astraSegmentInstruction: "같은 영역을 바라보며 옆으로 조금 이동해주세요"
        )

        XCTAssertEqual(state.source, .live)
        XCTAssertTrue(state.title.contains("다시 보이도록") || state.title.contains("돌아가"))
        XCTAssertNotEqual(state.title, "같은 영역을 바라보며 옆으로 조금 이동해주세요")
        XCTAssertEqual(state.direction, .returnBack)
        XCTAssertEqual(state.statusLabel, "공간 기록 중")
        XCTAssertFalse(state.title.contains("%"))
    }

    func testCalmPathUsesAstraWhenNoLiveIssue() {
        var quality = CaptureQualityState.zero
        quality.trackingQuality = 0.95
        quality.overlapAvailable = true
        quality.overlapState = .good
        quality.guidanceAction = .continueCapture
        quality.completionState = .notReady
        quality.qualityCoverage = 0.4
        quality.motionSpeed = 0.1

        let astra = "벽을 따라 천천히 이동하세요"
        let state = CaptureUIPresenter.primaryGuidance(
            quality: quality,
            astraSegmentInstruction: astra
        )
        XCTAssertEqual(state.source, .astra)
        XCTAssertEqual(state.title, astra)
    }

    func testReadyMapsStatusAndFinishTitle() {
        var quality = CaptureQualityState.zero
        quality.trackingQuality = 0.95
        quality.completionState = .ready
        quality.guidanceAction = .captureComplete
        quality.qualityCoverage = 0.8

        let state = CaptureUIPresenter.primaryGuidance(quality: quality)
        XCTAssertTrue(state.isReadyToFinish)
        XCTAssertEqual(state.finishButtonTitle, "기록 완료")
        XCTAssertEqual(state.statusLabel, "3D 공간을 만들 준비가 됐어요")
        XCTAssertEqual(state.source, .completion)
    }

    func testLiveCorrectionOutranksStaleReadyCompletion() {
        var quality = CaptureQualityState.zero
        quality.trackingQuality = 0.95
        quality.completionState = .ready
        quality.qualityCoverage = 0.8
        quality.motionSpeed = 0.9
        quality.guidanceAction = .slowDown
        quality.overlapAvailable = true
        quality.overlapState = .good

        let state = CaptureUIPresenter.primaryGuidance(quality: quality)
        XCTAssertEqual(state.source, .live)
        XCTAssertEqual(state.action, .slowDown)
        XCTAssertFalse(state.isReadyToFinish)
        XCTAssertFalse(state.title.contains("준비가 됐어요"))
        XCTAssertEqual(state.statusLabel, "공간 기록 중")
    }

    func testHoldControllerKeepsNormalGuidanceBriefly() {
        let hold = PrimaryGuidanceHoldController()
        let t0 = Date()

        var q = CaptureQualityState.zero
        q.guidanceAction = .continueCapture
        q.completionState = .notReady
        q.trackingQuality = 0.9
        let first = CaptureUIPresenter.primaryGuidance(quality: q)
        _ = hold.resolve(first, at: t0)

        q.guidanceAction = .scanNewArea
        let second = CaptureUIPresenter.primaryGuidance(quality: q)
        let held = hold.resolve(second, at: t0.addingTimeInterval(0.5))
        XCTAssertEqual(held.identityKey, first.identityKey)

        let released = hold.resolve(second, at: t0.addingTimeInterval(3.0))
        XCTAssertEqual(released.identityKey, second.identityKey)
    }

    func testCriticalInterruptsHold() {
        let hold = PrimaryGuidanceHoldController()
        let t0 = Date()

        var q = CaptureQualityState.zero
        q.guidanceAction = .continueCapture
        q.completionState = .notReady
        q.trackingQuality = 0.9
        let first = CaptureUIPresenter.primaryGuidance(quality: q)
        _ = hold.resolve(first, at: t0)

        q.guidanceAction = .returnToPreviousArea
        q.overlapAvailable = true
        q.overlapState = .lost
        let critical = CaptureUIPresenter.primaryGuidance(quality: q)
        let shown = hold.resolve(critical, at: t0.addingTimeInterval(0.2))
        XCTAssertEqual(shown.action, .returnToPreviousArea)
        XCTAssertEqual(shown.severity, .critical)
    }

    func testStatusLabelsForCompletionStates() {
        XCTAssertEqual(CaptureUIPresenter.statusLabel(for: .notReady), "공간 기록 중")
        XCTAssertEqual(CaptureUIPresenter.statusLabel(for: .nearlyReady), "거의 다 기록했어요")
        XCTAssertEqual(CaptureUIPresenter.statusLabel(for: .ready), "3D 공간을 만들 준비가 됐어요")
    }
}
