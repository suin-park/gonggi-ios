import Foundation

// MARK: - Backend abstraction (3D Locker integration point)

struct CreateSpaceRequest: Equatable {
    var name: String
    var visibility: String
}

struct CreateSpaceResponse: Equatable {
    let spaceId: String
    let jobId: String
    let uploadURL: URL?
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

    var errorDescription: String? {
        switch self {
        case .networkUnavailable: return "네트워크에 연결할 수 없습니다."
        case .unauthorized: return "로그인이 필요합니다."
        case .jobNotFound: return "작업을 찾을 수 없습니다."
        case .uploadFailed: return "업로드에 실패했습니다."
        case .unknown(let msg): return msg
        }
    }
}
