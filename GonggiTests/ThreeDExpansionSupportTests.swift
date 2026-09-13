import XCTest
@testable import Gonggi

final class ThreeDExpansionSupportTests: XCTestCase {
    func testSessionKeyPrefersSessionId() {
        var space = SpaceRecord.sampleArchive[0]
        space.sessionId = "sess-9"
        XCTAssertEqual(ThreeDExpansionSupport.sessionKey(for: space), "sess-9")
    }

    func testExpandableRequiresReadySource() {
        var processing = SpaceRecord.sampleArchive[0]
        processing.status = .processing
        processing.localLatLongPath = "/tmp/x.jpg"
        XCTAssertFalse(ThreeDExpansionSupport.hasExpandable360Source(processing))

        var ready = SpaceRecord.sampleArchive[0]
        ready.status = .ready
        ready.localLatLongPath = nil
        ready.remoteImageURL = "https://example.com/a.jpg"
        XCTAssertTrue(ThreeDExpansionSupport.hasExpandable360Source(ready))
    }

    @MainActor
    func testExcludesCompleted3D() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("3d_exp_test_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = AdvancedCaptureAnalysisStore(fileURL: tmp)
        let now = Date()
        store.upsert(
            AdvancedCaptureAnalysisRecord(
                sessionId: "done-1",
                jobId: "done-1",
                status: .ready,
                createdAt: now,
                updatedAt: now,
                guidePlan: .mockDefault(sessionId: "done-1"),
                linkedGaussianSpaceId: "gauss-1",
                linkedGaussianJobId: "gj-1"
            )
        )

        var space = SpaceRecord.sampleArchive[0]
        space.id = "done-1"
        space.sessionId = "done-1"
        space.status = .ready
        space.remoteImageURL = "https://example.com/a.jpg"

        XCTAssertTrue(ThreeDExpansionSupport.is3DAlreadyComplete(sessionKey: "done-1", store: store))
        XCTAssertFalse(ThreeDExpansionSupport.isEligibleFor3DExpansion(space, store: store))
        XCTAssertTrue(ThreeDExpansionSupport.expandableSpaces(from: [space], store: store).isEmpty)
    }

    @MainActor
    func testIncludesReadyWithout3D() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("3d_exp_test2_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = AdvancedCaptureAnalysisStore(fileURL: tmp)

        var space = SpaceRecord.sampleArchive[0]
        space.id = "lat-1"
        space.sessionId = "lat-1"
        space.status = .ready
        space.remoteImageURL = "https://example.com/a.jpg"

        XCTAssertTrue(ThreeDExpansionSupport.isEligibleFor3DExpansion(space, store: store))
        XCTAssertEqual(ThreeDExpansionSupport.expandableSpaces(from: [space], store: store).count, 1)
    }

    @MainActor
    func testCachedGuidePlanReused() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("3d_exp_cache_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = AdvancedCaptureAnalysisStore(fileURL: tmp)
        let now = Date()
        store.upsert(
            AdvancedCaptureAnalysisRecord(
                sessionId: "cached-1",
                jobId: "cached-1",
                status: .ready,
                createdAt: now,
                updatedAt: now,
                guidePlan: .mockDefault(sessionId: "cached-1")
            )
        )
        let plan = ThreeDExpansionSupport.cachedGuidePlan(sessionId: "cached-1", store: store)
        XCTAssertNotNil(plan)
        XCTAssertFalse(plan?.segments.isEmpty ?? true)
    }

    func testUnusablePlanRejectedForCache() {
        let empty = AdvancedCaptureGuidePlan(
            segments: [],
            globalTips: [],
            estimatedTotalSec: nil,
            qualityProfile: nil,
            riskFlags: []
        )
        XCTAssertFalse(ThreeDExpansionSupport.isUsableGuidePlan(empty))

        let blankInstruction = AdvancedCaptureGuidePlan(
            segments: [
                AdvancedCaptureGuideSegment(
                    id: "s",
                    instructionKo: "   ",
                    targetYawDeg: nil,
                    targetPitchDeg: nil,
                    pathHint: nil,
                    durationSecMin: nil,
                    durationSecMax: nil,
                    coverageGoal: nil
                )
            ],
            globalTips: [],
            estimatedTotalSec: nil,
            qualityProfile: nil,
            riskFlags: []
        )
        XCTAssertFalse(ThreeDExpansionSupport.isUsableGuidePlan(blankInstruction))
        XCTAssertTrue(ThreeDExpansionSupport.isUsableGuidePlan(.mockDefault(sessionId: "ok")))
    }

    func testDefaultP1PlanIsUsableWithoutAstra() {
        let plan = AdvancedCaptureGuidePlan.defaultP1Plan(sessionId: "def-1")
        XCTAssertTrue(ThreeDExpansionSupport.isUsableGuidePlan(plan))
        XCTAssertGreaterThanOrEqual(plan.segments.count, 4)
        XCTAssertTrue(plan.riskFlags.contains("default_plan"))
        XCTAssertEqual(plan.qualityProfile, "capture_default_p1")
    }

    func testPrepareConfigTimeoutsAreBounded() {
        XCTAssertEqual(ThreeDExpansionSupport.PrepareConfig.softTimeoutSec, 30, accuracy: 0.01)
        XCTAssertEqual(ThreeDExpansionSupport.PrepareConfig.hardTimeoutSec, 60, accuracy: 0.01)
        XCTAssertLessThan(ThreeDExpansionSupport.PrepareConfig.hardTimeoutSec, 120)
    }

    @MainActor
    func testReadyButEmptyPlanDoesNotCache() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("3d_exp_bad_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = AdvancedCaptureAnalysisStore(fileURL: tmp)
        let now = Date()
        store.upsert(
            AdvancedCaptureAnalysisRecord(
                sessionId: "bad-1",
                jobId: "bad-1",
                status: .ready,
                createdAt: now,
                updatedAt: now,
                guidePlan: AdvancedCaptureGuidePlan(
                    segments: [],
                    globalTips: [],
                    estimatedTotalSec: nil,
                    qualityProfile: nil,
                    riskFlags: []
                )
            )
        )
        XCTAssertNil(ThreeDExpansionSupport.cachedGuidePlan(sessionId: "bad-1", store: store))
    }
}
