import Foundation

/// Test double for staged create / upload / start failure injection.
actor FailureInjectingSpaceGenerationService: SpaceGenerationService {
    enum FailAt: Equatable {
        case create
        case upload
        case start
        case none
    }

    var failAt: FailAt = .none
    var createCount = 0
    var uploadCount = 0
    var startCount = 0
    var cancelCount = 0
    var lastIdempotencyKey: String?
    var uploadDelayNanoseconds: UInt64 = 0
    /// When set, create returns this upload URL (nil simulates missing presign).
    var uploadURLOverride: URL? = URL(string: "https://mock.example/upload")
    var fixedSpaceId = "space-fixed"
    var fixedJobId = "job-fixed"

    func createSpace(_ request: CreateSpaceRequest) async throws -> CreateSpaceResponse {
        createCount += 1
        lastIdempotencyKey = request.idempotencyKey
        if failAt == .create {
            throw SpaceGenerationError.server(code: "CREATE_INJECTED", httpStatus: 500)
        }
        return CreateSpaceResponse(
            spaceId: fixedSpaceId,
            jobId: fixedJobId,
            uploadURL: uploadURLOverride,
            idempotencyKey: request.idempotencyKey
        )
    }

    func uploadCapture(_ request: UploadCaptureRequest) async throws {
        uploadCount += 1
        if uploadDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: uploadDelayNanoseconds)
        }
        try Task.checkCancellation()
        if failAt == .upload {
            throw SpaceGenerationError.uploadFailed
        }
    }

    func startGeneration(jobId: String) async throws {
        startCount += 1
        if failAt == .start {
            throw SpaceGenerationError.server(code: "START_INJECTED", httpStatus: 500)
        }
    }

    func fetchStatus(jobId: String) async throws -> GenerationJobStatus {
        GenerationJobStatus(
            jobId: jobId,
            spaceId: fixedSpaceId,
            steps: [],
            estimatedMinutesRemaining: nil,
            overallProgress: 0.1
        )
    }

    func cancel(jobId: String) async {
        cancelCount += 1
    }
}
