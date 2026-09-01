import Foundation

/// Future: HTTP client for 3D Locker `apps/cloud` video-gaussian API.
/// Do not hardcode URLs in views — inject via AppConfiguration.
struct AppConfiguration: Sendable {
    var apiBaseURL: URL
    var sessionCookieName: String

    static let production = AppConfiguration(
        apiBaseURL: URL(string: "https://www.3d-locker.com")!,
        sessionCookieName: "whik_session"
    )
}

/// Placeholder for real backend wiring (createSpace → upload → start → poll).
final class LockerSpaceGenerationService: SpaceGenerationService, @unchecked Sendable {
    private let config: AppConfiguration

    init(config: AppConfiguration = .production) {
        self.config = config
    }

    func createSpace(_ request: CreateSpaceRequest) async throws -> CreateSpaceResponse {
        throw SpaceGenerationError.unknown("LockerSpaceGenerationService not implemented — use MockSpaceGenerationService")
    }

    func uploadCapture(_ request: UploadCaptureRequest) async throws {
        throw SpaceGenerationError.unknown("Not implemented")
    }

    func startGeneration(jobId: String) async throws {
        throw SpaceGenerationError.unknown("Not implemented")
    }

    func fetchStatus(jobId: String) async throws -> GenerationJobStatus {
        throw SpaceGenerationError.jobNotFound
    }

    func cancel(jobId: String) async {}
}
