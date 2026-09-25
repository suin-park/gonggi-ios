import XCTest
@testable import Gonggi

final class GaussianViewerSessionTests: XCTestCase {
    func testDownloadCompleteIsNotDisplayed() {
        var s = GaussianViewerSession()
        s.applyStage("downloading")
        s.applyProgress(percent: 100)
        XCTAssertEqual(s.phase, .downloading(percent: 100))
        s.applyStage("preparing")
        XCTAssertEqual(s.phase, .preparing)
        s.applyStage("displaying")
        XCTAssertEqual(s.phase, .displaying)
        XCTAssertFalse(s.everDisplayed)
        s.markReady()
        XCTAssertEqual(s.phase, .ready)
        XCTAssertEqual(s.outcome, "displayed")
    }

    func testStagesNeverRegressFromReady() {
        var s = GaussianViewerSession()
        s.markReady()
        s.applyStage("downloading")
        s.applyProgress(percent: 10)
        XCTAssertEqual(s.phase, .ready)
    }

    func testAutoRecoveryIsBoundedThenManualRetryResets() {
        var s = GaussianViewerSession()
        s.markReady()
        for _ in 0..<GaussianViewerSession.maxAutoRecoveries {
            XCTAssertTrue(s.requestRecovery(.webContentProcessTerminated))
            XCTAssertTrue(s.phase.isRecovering)
            s.beginReload(manual: false)
            XCTAssertTrue(s.phase.isRecovering, "auto reload keeps the recovering UI")
            s.markReady()
        }
        XCTAssertFalse(s.requestRecovery(.webContentProcessTerminated))
        XCTAssertEqual(s.phase, .failed(.recoveryExhausted(.webContentProcessTerminated)))
        XCTAssertEqual(s.processTerminated, GaussianViewerSession.maxAutoRecoveries + 1)

        s.beginReload(manual: true)
        XCTAssertEqual(s.phase, .connecting)
        XCTAssertEqual(s.manualRetries, 1)
        XCTAssertTrue(s.requestRecovery(.webGLContextLost))
    }

    func testFailureIsStickyUntilRetry() {
        var s = GaussianViewerSession()
        s.fail(.network)
        s.applyStage("preparing")
        XCTAssertEqual(s.phase, .failed(.network))
    }

    func testWatchdogReasons() {
        var s = GaussianViewerSession()
        let t0 = Date()
        XCTAssertNil(s.watchdog(now: t0))
        XCTAssertEqual(s.watchdog(now: t0.addingTimeInterval(GaussianViewerSession.noResponseSeconds + 1)), .noResponse)

        s.applyStage("downloading")
        s.applyProgress(percent: 40)
        XCTAssertNil(s.watchdog(now: Date().addingTimeInterval(5)))
        XCTAssertEqual(
            s.watchdog(now: Date().addingTimeInterval(GaussianViewerSession.downloadStallSeconds + 1)),
            .downloadStalled
        )

        s.applyStage("preparing")
        XCTAssertEqual(
            s.watchdog(now: Date().addingTimeInterval(GaussianViewerSession.prepareTimeoutSeconds + 1)),
            .prepareTimeout
        )

        s.markReady()
        XCTAssertNil(s.watchdog(now: Date().addingTimeInterval(3600)), "no timer-driven action once displayed")
    }

    func testRecoveryReloadThatNeverAnswersFails() {
        var s = GaussianViewerSession()
        s.markReady()
        XCTAssertTrue(s.requestRecovery(.webContentProcessTerminated))
        s.beginReload(manual: false)
        XCTAssertEqual(
            s.watchdog(now: Date().addingTimeInterval(GaussianViewerSession.noResponseSeconds + 1)),
            .recoveryExhausted(.webContentProcessTerminated)
        )
    }

    func testTelemetryHasNoURLsAndReportsRecovered() throws {
        var s = GaussianViewerSession()
        s.profile = ["plyName": "viewer-y-up.ply", "bytesTotal": NSNumber(value: 207_573_304), "splats": NSNumber(value: 836_982)]
        s.markReady()
        _ = s.requestRecovery(.webGLContextLost)
        s.markReady()
        let payload = s.telemetryPayload()
        XCTAssertEqual(payload["outcome"] as? String, "recovered")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))
        let json = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("http"))
        XCTAssertFalse(json.contains("Bearer"))
    }
}
