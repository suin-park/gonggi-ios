import XCTest
@testable import Gonggi

final class ServerGenerationProfileMapperTests: XCTestCase {
    func testDirectP1GuideMapsToCaptureDenseV2() {
        let mapped = ServerGenerationProfileMapper.resolveServerProfile(
            guideQualityProfile: "capture_default_p1"
        )
        XCTAssertEqual(mapped, "capture_dense_v2")
        XCTAssertNotEqual(mapped, "capture_default_p1")
    }

    func testMainlineProfilesPassthrough() {
        for profile in ["capture_dense_v2", "fullres_max", "fullres_max_raw", "fullres_dense_d1"] {
            XCTAssertEqual(
                ServerGenerationProfileMapper.resolveServerProfile(guideQualityProfile: profile),
                profile
            )
        }
    }

    func testUnknownFallsBackToDefault() {
        XCTAssertEqual(
            ServerGenerationProfileMapper.resolveServerProfile(guideQualityProfile: "not_a_real_profile"),
            ServerGenerationProfileMapper.defaultServerProfile
        )
    }

    func testNilUsesDefault() {
        XCTAssertEqual(
            ServerGenerationProfileMapper.resolve(from: nil),
            "capture_dense_v2"
        )
    }

    func testSanitizeRejectsGuideIdentity() {
        XCTAssertEqual(
            ServerGenerationProfileMapper.sanitize("capture_default_p1"),
            "capture_dense_v2"
        )
    }

    func testDefaultP1PlanMapsViaGuidePlan() {
        let plan = AdvancedCaptureGuidePlan.defaultP1Plan(sessionId: "test-session")
        XCTAssertEqual(plan.qualityProfile, "capture_default_p1")
        XCTAssertEqual(
            ServerGenerationProfileMapper.resolve(from: plan),
            "capture_dense_v2"
        )
    }
}

final class SpaceGenerationErrorPresenterTests: XCTestCase {
    func testQualityProfileInvalidIsSanitized() {
        let error = SpaceGenerationError.server(code: "QUALITY_PROFILE_INVALID", httpStatus: 400)
        let message = SpaceGenerationErrorPresenter.userMessage(for: error)
        XCTAssertFalse(message.contains("QUALITY_PROFILE"))
        XCTAssertTrue(message.contains("3D 공간 생성을 시작하지 못했어요"))
    }

    func testUnknownRawCodeIsSanitized() {
        let error = SpaceGenerationError.unknown("QUALITY_PROFILE_INVALID")
        let message = SpaceGenerationErrorPresenter.userMessage(for: error)
        XCTAssertFalse(message.contains("QUALITY_PROFILE"))
    }
}

final class CaptureDiagnosticsAccumulatorTests: XCTestCase {
    func testGuidanceHistoryRecordsActionChangesOnly() {
        let acc = CaptureDiagnosticsAccumulator()
        acc.reset()
        var q = CaptureQualityState.zero
        q.overlapAvailable = true
        q.overlapScore = 0.6
        q.overlapState = .good
        q.qualityCoverage = 0.4
        q.sharpnessScore = 0.8
        q.sharpnessState = .sharp
        q.trackingQuality = 1
        q.motionSpeed = 0.1

        acc.ingest(action: .continueCapture, phase: .perimeter, quality: q, trackingNormal: true)
        acc.ingest(action: .continueCapture, phase: .perimeter, quality: q, trackingNormal: true)
        q.overlapScore = 0.19
        q.overlapState = .lost
        acc.ingest(action: .returnToPreviousArea, phase: .perimeter, quality: q, trackingNormal: true)
        acc.ingest(action: .returnToPreviousArea, phase: .perimeter, quality: q, trackingNormal: true)
        q.overlapScore = 0.61
        q.overlapState = .good
        acc.ingest(action: .continueCapture, phase: .perimeter, quality: q, trackingNormal: true)

        XCTAssertEqual(acc.events.count, 3)
        XCTAssertEqual(acc.events[0].action, GuidanceAction.continueCapture.rawValue)
        XCTAssertEqual(acc.events[1].action, GuidanceAction.returnToPreviousArea.rawValue)
        XCTAssertEqual(acc.events[1].overlap, 0.19, accuracy: 0.001)
        XCTAssertEqual(acc.events[2].action, GuidanceAction.continueCapture.rawValue)
    }

    func testFinishedByRawValues() {
        XCTAssertEqual(CaptureFinishedBy.readyCompletion.rawValue, "readyCompletion")
        XCTAssertEqual(CaptureFinishedBy.manualEarlyFinish.rawValue, "manualEarlyFinish")
    }
}

final class CaptureUIPresentationRingTests: XCTestCase {
    func testRingUsesCompletionIconsNotActionIcons() {
        XCTAssertEqual(
            CaptureUIPresenter.ringSystemImage(for: .notReady, action: .returnToPreviousArea),
            "viewfinder"
        )
        XCTAssertEqual(
            CaptureUIPresenter.ringSystemImage(for: .nearlyReady, action: .moveLaterally),
            "checkmark.circle"
        )
        XCTAssertEqual(
            CaptureUIPresenter.ringSystemImage(for: .ready, action: .continueCapture),
            "checkmark"
        )
    }
}
