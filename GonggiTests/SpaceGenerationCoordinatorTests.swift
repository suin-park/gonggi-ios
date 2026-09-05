import XCTest
import UIKit
@testable import Gonggi

@MainActor
final class SpaceGenerationCoordinatorTests: XCTestCase {
    func testA_NineOfTenDoesNotStartGeneration() throws {
        let result = try makeResult(missing: .down)
        let api = CountingAPIClient()
        let coordinator = SpaceGenerationCoordinator(api: api)
        coordinator.start(from: result)
        XCTAssertEqual(coordinator.state, .failed(.captureIncomplete))
        XCTAssertEqual(api.createCount, 0)
        XCTAssertEqual(coordinator.uploadStartCount, 0)
        CaptureSessionStore.deleteSession(sessionId: result.sessionId)
    }

    func testB_TenOfTenStartsGenerationOnce() async throws {
        let result = try makeResult(missing: nil)
        let api = CountingAPIClient()
        let coordinator = SpaceGenerationCoordinator(api: api)
        coordinator.start(from: result)
        // Allow async upload to start
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(coordinator.uploadStartCount, 1)
        XCTAssertEqual(api.createCount, 1)
        coordinator.start(from: result)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(coordinator.uploadStartCount, 1, "duplicate completion must not re-start")
        CaptureSessionStore.deleteSession(sessionId: result.sessionId)
    }

    func testC_ValidateDoesNotRequireResultView() throws {
        // DirectionCaptureView no longer presents DirectionCaptureResultView in production flow;
        // coordinator is the next hop after 10/10.
        let result = try makeResult(missing: nil)
        let validated = SpaceGenerationCoordinator.validateCaptureFiles(result: result)
        XCTAssertTrue(validated.isSuccess)
        CaptureSessionStore.deleteSession(sessionId: result.sessionId)
    }

    func testD_CreateStoresJobId() async throws {
        let result = try makeResult(missing: nil)
        let api = CountingAPIClient()
        let coordinator = SpaceGenerationCoordinator(api: api)
        coordinator.start(from: result)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(coordinator.jobId, result.sessionId)
        CaptureSessionStore.deleteSession(sessionId: result.sessionId)
    }

    func testH_FailedMapsToErrorState() async throws {
        let result = try makeResult(missing: nil)
        let api = CountingAPIClient()
        api.failCreate = true
        let coordinator = SpaceGenerationCoordinator(api: api)
        coordinator.start(from: result)
        try await Task.sleep(nanoseconds: 400_000_000)
        if case .failed = coordinator.state {
            // ok
        } else {
            XCTFail("expected failed state, got \(coordinator.state)")
        }
        CaptureSessionStore.deleteSession(sessionId: result.sessionId)
    }

    func testJ_DuplicateStartIgnored() async throws {
        let result = try makeResult(missing: nil)
        let api = CountingAPIClient()
        let coordinator = SpaceGenerationCoordinator(api: api)
        coordinator.start(from: result)
        coordinator.start(from: result)
        coordinator.start(from: result)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(api.createCount, 1)
        CaptureSessionStore.deleteSession(sessionId: result.sessionId)
    }

    // MARK: - Helpers

    private func makeResult(missing: DirectionName?) throws -> DirectionCaptureResult {
        let sessionId = "dir-test-\(UUID().uuidString)"
        let dir = try CaptureSessionStore.createDirectionCaptureDirectory(sessionId: sessionId)
        var images: [(DirectionName, UIImage)] = []
        for name in DirectionName.captureOrder {
            if name == missing { continue }
            let img = DirectionCaptureEngine.makeMockImage(direction: name)
            let url = dir.appendingPathComponent(name.fileName)
            guard let data = img.jpegData(compressionQuality: 0.8) else {
                throw NSError(domain: "test", code: 1)
            }
            try data.write(to: url)
            images.append((name, img))
        }
        let report = DirectionCaptureReport(
            sessionId: sessionId,
            createdAt: "now",
            captures: []
        )
        return DirectionCaptureResult(
            sessionId: sessionId,
            report: report,
            images: images,
            directoryURL: dir
        )
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

final class CountingAPIClient: SpaceRecordAPIClienting, @unchecked Sendable {
    var createCount = 0
    var failCreate = false

    func create(
        sessionId: String,
        imageFiles: [(direction: String, fileURL: URL)]
    ) async throws -> SpaceRecordCreateResponse {
        createCount += 1
        if failCreate { throw SpaceRecordClientError.network }
        return SpaceRecordCreateResponse(sessionId: sessionId, jobId: sessionId, status: "queued")
    }

    func regenerate(
        sessionId: String,
        imageFiles: [(direction: String, fileURL: URL)]
    ) async throws -> SpaceRecordCreateResponse {
        try await create(sessionId: sessionId, imageFiles: imageFiles)
    }

    func fetchStatus(jobId: String) async throws -> SpaceRecordStatusResponse {
        SpaceRecordStatusResponse(status: "generating")
    }

    func downloadImage(from url: URL, to destination: URL) async throws {}
}
