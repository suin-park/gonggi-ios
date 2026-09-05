import Foundation

enum SpaceRecordState: Equatable {
    case idle
    case capturing
    case preparing
    case uploading
    case generating
    case loadingResult
    case viewing
    case failed(SpaceRecordFailure)
}

enum SpaceRecordFailure: Equatable {
    case captureIncomplete
    case network
    case generationFailed
    case invalidResult
    case timeout

    var userMessage: String {
        switch self {
        case .captureIncomplete:
            return "공간 기록을 완료하지 못했습니다."
        case .network:
            return "네트워크에 연결할 수 없습니다."
        case .generationFailed, .invalidResult, .timeout:
            return "공간 생성에 실패했습니다."
        }
    }
}

struct SpaceRecordCreateResponse: Equatable {
    var sessionId: String
    var jobId: String
    var status: String
}

struct SpaceRecordStatusResponse: Equatable {
    var status: String
    var imageUrl: String?
    var width: Int?
    var height: Int?
    var errorCode: String?
}

protocol SpaceRecordAPIClienting: Sendable {
    func create(sessionId: String, imageFiles: [(direction: String, fileURL: URL)]) async throws -> SpaceRecordCreateResponse
    func regenerate(sessionId: String, imageFiles: [(direction: String, fileURL: URL)]) async throws -> SpaceRecordCreateResponse
    func fetchStatus(jobId: String) async throws -> SpaceRecordStatusResponse
    func downloadImage(from url: URL, to destination: URL) async throws
}
