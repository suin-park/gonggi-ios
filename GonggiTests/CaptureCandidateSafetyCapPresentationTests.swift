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
        XCTAssertEqual(CaptureQuietUIPresenter.statusLine(for: q), "공간 기록 중")
        XCTAssertNotEqual(
            CaptureQuietUIPresenter.statusLine(for: q),
            "새 사진이 더 이상 저장되지 않습니다"
        )
        XCTAssertNil(CaptureQuietUIPresenter.toastHint(for: q))
    }

    func testCapReachedReplacesRecordingStatusAndDoesNotClaimDiskCount() {
        let q = quality(enqueueCount: cap)
        XCTAssertTrue(q.candidateSafetyCapReached)
        XCTAssertEqual(CaptureQuietUIPresenter.phase(for: q), .storageCapReached)
        let line = CaptureQuietUIPresenter.statusLine(for: q)
        XCTAssertEqual(line, "새 사진이 더 이상 저장되지 않습니다")
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
            "새 사진이 더 이상 저장되지 않습니다"
        )
        XCTAssertNotEqual(
            CaptureQuietUIPresenter.statusLine(for: readyButCapped),
            "공간이 충분히 기록됐어요"
        )
    }

    func testIncompleteCapSummaryIsPartialNotFullyReadyAndHidesContinue() {
        XCTAssertEqual(
            CaptureSummaryPresentation.heroTitle(
                completionState: .notReady,
                terminalContinuityOK: false,
                candidateSafetyCapReached: true
            ),
            "촬영 데이터가 부분 저장되었어요"
        )
        XCTAssertNotEqual(
            CaptureSummaryPresentation.heroTitle(
                completionState: .notReady,
                terminalContinuityOK: false,
                candidateSafetyCapReached: true
            ),
            "촬영이 완료되었어요"
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
                .contains("새 사진이 더 이상 저장되지 않습니다")
        )
        XCTAssertFalse(
            CaptureSummaryPresentation.earlyFinishDialogTitle(candidateSafetyCapReached: true)
                .contains("추가 촬영")
        )
    }

    func testFullyReadyCapStillAllowsCompletionHeroWithoutContinue() {
        XCTAssertEqual(
            CaptureSummaryPresentation.heroTitle(
                completionState: .ready,
                terminalContinuityOK: true,
                candidateSafetyCapReached: true
            ),
            "촬영이 완료되었어요"
        )
        XCTAssertFalse(
            CaptureSummaryPresentation.shouldOfferContinueCapture(candidateSafetyCapReached: true)
        )
    }
}
