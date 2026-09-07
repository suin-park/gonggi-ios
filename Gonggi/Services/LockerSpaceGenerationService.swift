import Foundation

/// Shared app config for 3D Locker / Gonggi HTTP + OAuth.
/// Google client id comes from Info.plist (`GoogleClientID` ← Config/Auth.xcconfig). Do not hardcode.
struct AppConfiguration: Sendable {
    var apiBaseURL: URL
    var sessionCookieName: String
    /// iOS OAuth client id (`….apps.googleusercontent.com`).
    var googleClientID: String
    /// Reverse-DNS URL scheme for ASWebAuthenticationSession / Google redirect.
    var googleReversedClientID: String

    static func reversedGoogleClientID(from clientID: String) -> String {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.split(separator: ".").reversed().joined(separator: ".")
    }

    static func loadProduction() -> AppConfiguration {
        let clientID = (Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reversedFromPlist = (Bundle.main.object(forInfoDictionaryKey: "GoogleReversedClientID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reversed = reversedFromPlist.isEmpty ? reversedGoogleClientID(from: clientID) : reversedFromPlist
        return AppConfiguration(
            apiBaseURL: URL(string: "https://www.3d-locker.com")!,
            sessionCookieName: "whik_session",
            googleClientID: clientID,
            googleReversedClientID: reversed
        )
    }

    static let production = AppConfiguration.loadProduction()

    var isGoogleSignInConfigured: Bool {
        !googleClientID.isEmpty && googleClientID.contains("apps.googleusercontent.com")
    }
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
