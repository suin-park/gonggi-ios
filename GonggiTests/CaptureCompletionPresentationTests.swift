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
            L("Capture complete")
        )
        XCTAssertEqual(
            CaptureSummaryPresentation.heroTitle(
                completionState: .notReady,
                terminalContinuityOK: false
            ),
            L("Capture saved")
        )
        XCTAssertEqual(
            CaptureSummaryPresentation.heroTitle(
                completionState: .nearlyReady,
                terminalContinuityOK: false
            ),
            L("Capture saved")
        )
        XCTAssertEqual(
            CaptureSummaryPresentation.createButtonTitle(weakTerminal: true),
            L("Create with current data")
        )
        XCTAssertEqual(
            CaptureSummaryPresentation.continueButtonTitle(weakTerminal: true),
            L("Strengthen the connection")
        )
        XCTAssertEqual(
            CaptureSummaryPresentation.createButtonTitle(weakTerminal: false),
            L("Create the space now")
        )
        XCTAssertEqual(
            CaptureSummaryPresentation.heroTitle(
                completionState: .notReady,
                terminalContinuityOK: false,
                candidateSafetyCapReached: true
            ),
            L("Part of the capture was saved")
        )
    }
}
