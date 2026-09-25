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
        // Before the document commits, WebKit's own request timeout applies (slow HTML ≠ no response).
        XCTAssertNil(s.watchdog(now: t0.addingTimeInterval(GaussianViewerSession.noResponseSeconds + 60)))
        s.noteNavigationCommitted(at: t0)
        XCTAssertNil(s.watchdog(now: t0.addingTimeInterval(5)))
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

    func testAdvancingDownloadNeverTimesOut() {
        var s = GaussianViewerSession()
        s.noteNavigationCommitted()
        s.applyStage("downloading")
        // A slow download: one percent step every 50 s for a long time is still progress.
        for pct in 1...5 {
            s.applyProgress(percent: pct)
            XCTAssertNil(s.watchdog(now: Date().addingTimeInterval(50)))
        }
    }

    func testBackgroundTimeIsExcludedFromTimeouts() {
        var s = GaussianViewerSession()
        s.noteNavigationCommitted()
        s.applyStage("downloading")
        s.applyProgress(percent: 10)
        let t = Date()
        s.pause(at: t)
        XCTAssertNil(s.watchdog(now: t.addingTimeInterval(600)), "paused while backgrounded")
        s.resume(at: t.addingTimeInterval(600))
        XCTAssertNil(s.watchdog(now: t.addingTimeInterval(610)), "10 s of foreground time after 10 min away")
        XCTAssertEqual(s.backgrounded, 1)
        XCTAssertGreaterThanOrEqual(s.backgroundMs, 600_000)

        s.applyStage("preparing")
        let p = Date()
        s.pause(at: p.addingTimeInterval(1))
        s.resume(at: p.addingTimeInterval(1 + 3600))
        XCTAssertNil(s.watchdog(now: p.addingTimeInterval(3600 + 30)))
        XCTAssertEqual(
            s.watchdog(now: p.addingTimeInterval(3600 + GaussianViewerSession.prepareTimeoutSeconds + 2)),
            .prepareTimeout
        )
    }

    func testRecoveryReloadThatNeverAnswersFails() {
        var s = GaussianViewerSession()
        s.markReady()
        XCTAssertTrue(s.requestRecovery(.webContentProcessTerminated))
        s.beginReload(manual: false)
        let t = Date()
        s.noteNavigationCommitted(at: t)
        XCTAssertEqual(
            s.watchdog(now: t.addingTimeInterval(GaussianViewerSession.noResponseSeconds + 1)),
            .recoveryExhausted(.webContentProcessTerminated)
        )
    }

    func testSoftScriptErrorDoesNotFailButIsRecorded() throws {
        var s = GaussianViewerSession()
        s.noteNavigationCommitted()
        s.applyStage("preparing")
        s.noteSoftError("GAUSSIAN_VIEWER_WINDOW_ERROR")
        XCTAssertEqual(s.phase, .preparing)
        s.fail(.prepareTimeout)
        let code = try XCTUnwrap(s.telemetryPayload()["failureCode"] as? String)
        XCTAssertEqual(code, "PREPARE_TIMEOUT|GAUSSIAN_VIEWER_WINDOW_ERROR")
        XCTAssertLessThanOrEqual(code.count, 80)
    }

    func testTelemetryHasNoURLsAndReportsRecovered() throws {
        var s = GaussianViewerSession()
        s.profile = ["plyName": "viewer-y-up.ply", "bytesTotal": NSNumber(value: 207_573_304), "splats": NSNumber(value: 836_982)]
        s.markReady()
        _ = s.requestRecovery(.webGLContextLost)
        s.markReady()
        let payload = s.telemetryPayload()
        XCTAssertEqual(payload["outcome"] as? String, "recovered")
        let timings = try XCTUnwrap(payload["timings"] as? [String: Any])
        XCTAssertNotNil(timings["nativeBackgroundMs"] as? Int)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))
        let json = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("http"))
        XCTAssertFalse(json.contains("Bearer"))
    }
}
