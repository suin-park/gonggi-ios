import XCTest
@testable import Gonggi

final class AdvancedCaptureTests: XCTestCase {
    func testMockAPICompletesWithGuidePlan() async throws {
        let client = MockAdvancedCaptureAPIClient(delayNs: 0)
        let start = try await client.startAnalyze(sessionId: "sess-a", force: false)
        XCTAssertEqual(start.sessionId, "sess-a")
        // Force elapsed by using a client that treats start as past — sleep briefly.
        try await Task.sleep(nanoseconds: 1_300_000_000)
        let status = try await client.fetchStatus(jobId: "sess-a")
        XCTAssertEqual(status.status, .ready)
        XCTAssertFalse(status.guidePlan?.segments.isEmpty ?? true)
    }

    @MainActor
    func testAnalysisStoreRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("advanced_capture_test_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = AdvancedCaptureAnalysisStore(fileURL: tmp)
        let now = Date()
        store.upsert(
            AdvancedCaptureAnalysisRecord(
                sessionId: "s1",
                jobId: "s1",
                status: .analyzing,
                createdAt: now,
                updatedAt: now,
                guidePlan: nil,
                lastErrorCode: nil,
                lastErrorMessage: nil,
                linkedGaussianSpaceId: nil,
                linkedGaussianJobId: nil
            )
        )
        XCTAssertEqual(store.record(sessionId: "s1")?.status, .analyzing)
        store.update(sessionId: "s1") { rec in
            rec.status = .ready
            rec.guidePlan = .mockDefault(sessionId: "s1")
        }
        XCTAssertTrue(store.record(sessionId: "s1")?.canStartGuidedCapture == true)
    }
}
