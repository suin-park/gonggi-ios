import Foundation

// MARK: - Backend abstraction (3D Locker integration point)

struct CreateSpaceRequest: Equatable {
    var name: String
    var visibility: String
    /// Declared upload size for signed PUT (video-gaussian create).
    var videoByteSize: Int? = nil
    var videoFilename: String = "original.mov"
    var videoContentType: String = "video/quicktime"
    var durationSec: Double? = nil
    var qualityProfile: String = "capture_dense_v2"
    /// Client-owned key for create retry / diagnostics.
    var idempotencyKey: String? = nil
    /// Spatial package only — JPEG keyframe count hint.
    var frameCount: Int? = nil
    /// "object" when the package carries object.json (product capture); nil = space. The server picks the profile.
    var captureKind: String? = nil
}

struct CreateSpaceResponse: Equatable {
    let spaceId: String
    let jobId: String
    let uploadURL: URL?
    var idempotencyKey: String? = nil
}

struct UploadCaptureRequest: Equatable {
    let jobId: String
    let localCaptureURL: URL
    let metadata: CaptureUploadMetadata
}

struct CaptureUploadMetadata: Equatable, Codable {
    var durationSec: Double
    var coverage: Double
    var frameCount: Int
    var deviceHasLiDAR: Bool
    var qualitySummary: [String: Double]
}

protocol SpaceGenerationService: Sendable {
    func createSpace(_ request: CreateSpaceRequest) async throws -> CreateSpaceResponse
    func uploadCapture(_ request: UploadCaptureRequest) async throws
    func startGeneration(jobId: String) async throws
    func fetchStatus(jobId: String) async throws -> GenerationJobStatus
    func cancel(jobId: String) async
}

enum SpaceGenerationError: LocalizedError {
    case networkUnavailable
    case unauthorized
    case jobNotFound
    case uploadFailed
    case unknown(String)
    /// Structured create/start failure for diagnostics (user sees sanitized copy).
    case server(code: String, httpStatus: Int)

    var errorDescription: String? {
        switch self {
        case .networkUnavailable: return L("Can't connect to the network.")
        case .unauthorized: return L("Please sign in.")
        case .jobNotFound: return L("Couldn't find the job.")
        case .uploadFailed: return L("Upload failed.")
        // Raw server text / codes stay in `backendErrorCode` and the logs; users get a localized line.
        case .unknown, .server:
            return L("Something went wrong. Please try again.")
        }
    }

    var backendErrorCode: String? {
        switch self {
        case .server(let code, _): return code
        case .unknown(let msg): return msg
        default: return nil
        }
    }

    var httpStatus: Int? {
        switch self {
        case .server(_, let status): return status
        case .unauthorized: return 401
        default: return nil
        }
    }
}
