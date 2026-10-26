import XCTest
@testable import Gonggi

/// Photo density / pace check (3.1(39)): V1_061 (good) and V1_062 (blurry) end-of-capture numbers.
final class CaptureDensityCheckTests: XCTestCase {
    private func quality(photos: Int, areaM2: Double, goodCells: Int, avgSpeed: Double, speed: Double = 0.2,
                         completion: CaptureCompletionState = .notReady) -> CaptureQualityState {
        var q = CaptureQualityState.zero
        q.capturePhase = .coverageFill
        q.trackingQuality = 0.95
        q.spatialKeyframeEnqueueCount = photos
        q.coveredAreaM2 = areaM2
        q.wellCoveredCellCount = goodCells
        q.sessionAverageSpeedMps = avgSpeed
        q.motionSpeed = speed
        q.completionState = completion
        return q
    }

    private var blurryV1062: CaptureQualityState { quality(photos: 291, areaM2: 22.4, goodCells: 4, avgSpeed: 0.34) }
    private var goodV1061: CaptureQualityState { quality(photos: 520, areaM2: 12.0, goodCells: 13, avgSpeed: 0.26, completion: .ready) }

    func testBlurryCaptureIsFlaggedWithTheFastWalkFirst() {
        XCTAssertEqual(CaptureDensityCheck.issues(for: blurryV1062), [.movedFast, .sparsePhotos, .fewWellCoveredAreas])
        XCTAssertTrue(CaptureSummaryPresentation.finishNeedsConfirm(quality: blurryV1062))
        XCTAssertEqual(CaptureSummaryPresentation.finishConfirmTitle(quality: blurryV1062), CaptureDensityCheck.finishWarningTitle)
        XCTAssertEqual(CaptureSummaryPresentation.finishConfirmMessage(quality: blurryV1062), CaptureDensityCheck.reason(.movedFast))
    }

    func testGoodCaptureFinishesWithoutAsking() {
        XCTAssertEqual(CaptureDensityCheck.issues(for: goodV1061), [])
        XCTAssertFalse(CaptureSummaryPresentation.finishNeedsConfirm(quality: goodV1061))
        XCTAssertNil(CaptureSummaryPresentation.finishConfirmMessage(quality: goodV1061))
    }

    func testReadyButSparseStillAsks() {
        var q = blurryV1062
        q.completionState = .ready
        XCTAssertTrue(CaptureSummaryPresentation.finishNeedsConfirm(quality: q))
    }

    func testEarlyCaptureIsNotJudged() {
        let q = quality(photos: 40, areaM2: 2.5, goodCells: 1, avgSpeed: 0.5)
        XCTAssertEqual(CaptureDensityCheck.issues(for: q), [])
        XCTAssertNil(CaptureDensityCheck.liveGuide(for: q))
        XCTAssertEqual(CaptureSummaryPresentation.finishConfirmTitle(quality: q),
                       CaptureSummaryPresentation.earlyFinishDialogTitle(candidateSafetyCapReached: false))
    }

    func testPhotoLimitKeepsItsOwnDialog() {
        var q = blurryV1062
        q.candidateSafetyCapReached = true
        XCTAssertEqual(CaptureSummaryPresentation.finishConfirmTitle(quality: q),
                       CaptureSummaryPresentation.earlyFinishDialogTitle(candidateSafetyCapReached: true))
        XCTAssertNil(CaptureSummaryPresentation.finishConfirmMessage(quality: q))
    }

    func testLiveGuideSlowDownOrStay() {
        var q = blurryV1062
        q.motionSpeed = 0.45
        let fast = CaptureQuietUIPresenter.guide(for: q)
        XCTAssertEqual(fast.title, L("Walk more slowly"))
        XCTAssertEqual(fast.tone, .warning)
        q.motionSpeed = 0.1
        let slow = CaptureQuietUIPresenter.guide(for: q)
        XCTAssertEqual(slow.title, L("Capture this area a little longer"))
        XCTAssertEqual(slow.tone, .normal)
        XCTAssertEqual(CaptureQuietUIPresenter.guide(for: quality(photos: 520, areaM2: 12, goodCells: 13, avgSpeed: 0.26)).title,
                       L("Point freely around the space"), "dense capture keeps the normal tips")
    }
}
