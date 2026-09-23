import Foundation
import XCTest
@testable import Gonggi

final class CaptureCompletionPresentationTests: XCTestCase {
    func testSummaryHeroCopyDistinguishesReadyFromSavedOnly() {
        XCTAssertEqual(
            CaptureSummaryPresentation.heroTitle(
                completionState: .ready,
                terminalContinuityOK: true
            ),
            "촬영이 완료되었어요"
        )
        XCTAssertEqual(
            CaptureSummaryPresentation.heroTitle(
                completionState: .notReady,
                terminalContinuityOK: false
            ),
            "촬영 데이터가 저장되었어요"
        )
        XCTAssertEqual(
            CaptureSummaryPresentation.heroTitle(
                completionState: .nearlyReady,
                terminalContinuityOK: false
            ),
            "촬영 데이터가 저장되었어요"
        )
        XCTAssertEqual(
            CaptureSummaryPresentation.createButtonTitle(weakTerminal: true),
            "현재 데이터로 생성"
        )
        XCTAssertEqual(
            CaptureSummaryPresentation.continueButtonTitle(weakTerminal: true),
            "연결 보강 촬영"
        )
        XCTAssertEqual(
            CaptureSummaryPresentation.createButtonTitle(weakTerminal: false),
            "이대로 공간 생성"
        )
        XCTAssertEqual(
            CaptureSummaryPresentation.heroTitle(
                completionState: .notReady,
                terminalContinuityOK: false,
                candidateSafetyCapReached: true
            ),
            "촬영 데이터가 부분 저장되었어요"
        )
    }
}
