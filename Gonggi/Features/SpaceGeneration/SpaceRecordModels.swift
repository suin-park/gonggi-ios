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

enum SpaceRecordFailure: Error, Equatable {
    case captureIncomplete
    case network
    case generationFailed
    case invalidResult
    case timeout

    var userMessage: String {
        switch self {
        case .captureIncomplete:
            return L("Couldn't finish the space capture.")
        case .network:
            return L("Can't connect to the network.")
        case .generationFailed, .invalidResult, .timeout:
            return L("Space creation failed.")
        }
    }
}

/// Create success requires jobId only — never latlong URL / dimensions.
/// Status polling handles completed results separately.
struct SpaceRecordCreateResponse: Equatable {
    var sessionId: String
    var jobId: String
    var status: String
}

/// Status / completed payload (result fields optional until completed).
struct SpaceRecordStatusResponse: Equatable {
    var status: String
    var imageUrl: String?
    var width: Int?
    var height: Int?
    var errorCode: String?
}

protocol SpaceRecordAPIClienting: Sendable {
    func create(
        sessionId: String,
        imageFiles: [(direction: String, fileURL: URL)],
        captureMetadataJSON: String?
    ) async throws -> SpaceRecordCreateResponse
    func regenerate(
        sessionId: String,
        imageFiles: [(direction: String, fileURL: URL)],
        captureMetadataJSON: String?
    ) async throws -> SpaceRecordCreateResponse
    func fetchStatus(jobId: String) async throws -> SpaceRecordStatusResponse
    func downloadImage(from url: URL, to destination: URL) async throws
}
