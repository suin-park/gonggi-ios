import Foundation
import XCTest
@testable import Gonggi

final class CaptureCandidateSafetyCapPresentationTests: XCTestCase {
    private let cap = SpatialCaptureConfig.candidateSafetyCap

    private func quality(
        enqueueCount: Int,
        completion: CaptureCompletionState = .notReady,
        terminalOK: Bool = false,
        reconstructionReady: Bool = false
    ) -> CaptureQualityState {
        var q = CaptureQualityState.zero
        q.capturePhase = .coverageFill
        q.trackingQuality = 0.95
        q.completionState = completion
        q.reconstructionReady = reconstructionReady
        q.terminalContinuityOK = terminalOK
        q.spatialKeyframeEnqueueCount = enqueueCount
        q.candidateSafetyCapReached = enqueueCount >= cap
        return q
    }

    func testNearCapStillShowsRecordingStatusNotStopCopy() {
        XCTAssertEqual(cap, 520)
        let q = quality(enqueueCount: cap - 1)
        XCTAssertFalse(q.candidateSafetyCapReached)
        XCTAssertEqual(CaptureQuietUIPresenter.phase(for: q), .capturing)
        XCTAssertEqual(CaptureQuietUIPresenter.statusLine(for: q), L("Capturing the space"))
        XCTAssertNotEqual(
            CaptureQuietUIPresenter.statusLine(for: q),
            L("New photos are no longer being saved")
        )
        XCTAssertNil(CaptureQuietUIPresenter.toastHint(for: q))
    }

    func testCapReachedReplacesRecordingStatusAndDoesNotClaimDiskCount() {
        let q = quality(enqueueCount: cap)
        XCTAssertTrue(q.candidateSafetyCapReached)
        XCTAssertEqual(CaptureQuietUIPresenter.phase(for: q), .storageCapReached)
        let line = CaptureQuietUIPresenter.statusLine(for: q)
        XCTAssertEqual(line, L("New photos are no longer being saved"))
        XCTAssertFalse(line.contains("520"))
        XCTAssertFalse(line.contains("장"))
        XCTAssertEqual(CaptureQuietUIPresenter.toastHint(for: q), line)
        // Cap wins over ready copy — user must see saves have stopped.
        let readyButCapped = quality(
            enqueueCount: cap,
            completion: .ready,
            terminalOK: true,
            reconstructionReady: true
        )
        XCTAssertEqual(
            CaptureQuietUIPresenter.statusLine(for: readyButCapped),
            L("New photos are no longer being saved")
        )
        XCTAssertNotEqual(
            CaptureQuietUIPresenter.statusLine(for: readyButCapped),
            L("The space is fully captured")
        )
    }

    func testIncompleteCapSummaryIsPartialNotFullyReadyAndHidesContinue() {
        XCTAssertEqual(
            CaptureSummaryPresentation.heroTitle(
                completionState: .notReady,
                terminalContinuityOK: false,
                candidateSafetyCapReached: true
            ),
            L("Part of the capture was saved")
        )
        XCTAssertNotEqual(
            CaptureSummaryPresentation.heroTitle(
                completionState: .notReady,
                terminalContinuityOK: false,
                candidateSafetyCapReached: true
            ),
            L("Capture complete")
        )
        let subtitle = CaptureSummaryPresentation.heroSubtitle(
            completionState: .notReady,
            terminalContinuityOK: false,
            candidateSafetyCapReached: true
        )
        XCTAssertNotNil(subtitle)
        XCTAssertTrue(subtitle!.contains("한도"))
        XCTAssertFalse(subtitle!.contains("520"))
        XCTAssertFalse(
            CaptureSummaryPresentation.shouldOfferContinueCapture(candidateSafetyCapReached: true)
        )
        XCTAssertTrue(
            CaptureSummaryPresentation.shouldOfferContinueCapture(candidateSafetyCapReached: false)
        )
        XCTAssertTrue(
            CaptureSummaryPresentation.earlyFinishDialogTitle(candidateSafetyCapReached: true)
                .contains(L("New photos are no longer being saved"))
        )
        XCTAssertFalse(
            CaptureSummaryPresentation.earlyFinishDialogTitle(candidateSafetyCapReached: true)
                .contains(L("Capture more"))
        )
    }

    func testFullyReadyCapStillAllowsCompletionHeroWithoutContinue() {
        XCTAssertEqual(
            CaptureSummaryPresentation.heroTitle(
                completionState: .ready,
                terminalContinuityOK: true,
                candidateSafetyCapReached: true
            ),
            L("Capture complete")
        )
        XCTAssertFalse(
            CaptureSummaryPresentation.shouldOfferContinueCapture(candidateSafetyCapReached: true)
        )
    }
}
