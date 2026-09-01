import Foundation

/// Simulates 3D Locker video-gaussian pipeline for UI development.
actor MockSpaceGenerationService: SpaceGenerationService {
    private var jobs: [String: GenerationJobStatus] = [:]

    func createSpace(_ request: CreateSpaceRequest) async throws -> CreateSpaceResponse {
        try await Task.sleep(nanoseconds: 400_000_000)
        let spaceId = "space-\(UUID().uuidString.prefix(8))"
        let jobId = "job-\(UUID().uuidString.prefix(8))"
        jobs[jobId] = initialStatus(jobId: jobId, spaceId: spaceId)
        return CreateSpaceResponse(
            spaceId: spaceId,
            jobId: jobId,
            uploadURL: URL(string: "https://mock.3d-locker.local/upload/\(jobId)")
        )
    }

    func uploadCapture(_ request: UploadCaptureRequest) async throws {
        try await Task.sleep(nanoseconds: 1_200_000_000)
        guard var job = jobs[request.jobId] else { throw SpaceGenerationError.jobNotFound }
        job.steps[0].status = .completed
        job.steps[1].status = .active(progress: 0.05)
        job.overallProgress = 0.2
        jobs[request.jobId] = job
    }

    func startGeneration(jobId: String) async throws {
        guard jobs[jobId] != nil else { throw SpaceGenerationError.jobNotFound }
        Task { await self.simulateProgress(jobId: jobId) }
    }

    func fetchStatus(jobId: String) async throws -> GenerationJobStatus {
        guard let job = jobs[jobId] else { throw SpaceGenerationError.jobNotFound }
        return job
    }

    func cancel(jobId: String) async {
        jobs.removeValue(forKey: jobId)
    }

    private func initialStatus(jobId: String, spaceId: String) -> GenerationJobStatus {
        GenerationJobStatus(
            jobId: jobId,
            spaceId: spaceId,
            steps: ProcessingStepKind.allCases.map {
                ProcessingStepState(kind: $0, status: $0 == .upload ? .active(progress: 0) : .waiting)
            },
            estimatedMinutesRemaining: 8,
            overallProgress: 0.05
        )
    }

    private func simulateProgress(jobId: String) async {
        let ticks = 40
        for i in 1...ticks {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard var job = jobs[jobId] else { return }
            let p = Double(i) / Double(ticks)
            job.overallProgress = p
            job.estimatedMinutesRemaining = max(1, Int((1 - p) * 8))

            if p < 0.25 {
                job.steps[0].status = .completed
                job.steps[1].status = .active(progress: p / 0.25)
            } else if p < 0.55 {
                job.steps[0].status = .completed
                job.steps[1].status = .completed
                job.steps[2].status = .active(progress: (p - 0.25) / 0.30)
            } else if p < 0.95 {
                job.steps[0].status = .completed
                job.steps[1].status = .completed
                job.steps[2].status = .completed
                job.steps[3].status = .active(progress: (p - 0.55) / 0.40)
            } else {
                job.steps = job.steps.map { ProcessingStepState(kind: $0.kind, status: .completed) }
                job.estimatedMinutesRemaining = 0
            }
            jobs[jobId] = job
        }
    }
}
