import Foundation

protocol CurtainPlacementServing: Sendable {
    func createJob(request: CurtainPlacementCreateRequest, idempotencyKey: String?) async throws -> CurtainPlacementJob
    func fetchJob(id: String) async throws -> CurtainPlacementJob
    func confirmWindow(jobId: String) async throws -> CurtainPlacementJob
    func reselectWindow(jobId: String, seedU: Double, seedV: Double) async throws -> CurtainPlacementJob
    func composite(jobId: String) async throws -> CurtainPlacementJob
}

actor MobileCurtainPlacementAPIClient: CurtainPlacementServing {
    private let config: AppConfiguration
    private let session: URLSession

    init(config: AppConfiguration = .production, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func createJob(request: CurtainPlacementCreateRequest, idempotencyKey: String?) async throws -> CurtainPlacementJob {
        guard request.aiConsentAccepted else { throw CurtainPlacementAPIError.consentRequired }
        var req = try makeRequest(path: ["api", "gonggi", "curtain-composites"], method: "POST")
        req.httpBody = try JSONEncoder().encode(request)
        if let idempotencyKey, !idempotencyKey.isEmpty {
            req.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        return try await decodeJob(from: req)
    }

    func fetchJob(id: String) async throws -> CurtainPlacementJob {
        let req = try makeRequest(path: ["api", "gonggi", "curtain-composites", id], method: "GET")
        return try await decodeJob(from: req)
    }

    func confirmWindow(jobId: String) async throws -> CurtainPlacementJob {
        var req = try makeRequest(
            path: ["api", "gonggi", "curtain-composites", jobId, "confirm"],
            method: "POST"
        )
        req.httpBody = Data("{}".utf8)
        return try await decodeJob(from: req)
    }

    func reselectWindow(jobId: String, seedU: Double, seedV: Double) async throws -> CurtainPlacementJob {
        var req = try makeRequest(
            path: ["api", "gonggi", "curtain-composites", jobId, "reselect"],
            method: "POST"
        )
        let body: [String: Double] = ["seedU": seedU, "seedV": seedV]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await decodeJob(from: req)
    }

    func composite(jobId: String) async throws -> CurtainPlacementJob {
        var req = try makeRequest(
            path: ["api", "gonggi", "curtain-composites", jobId, "composite"],
            method: "POST"
        )
        req.httpBody = Data("{}".utf8)
        return try await decodeJob(from: req)
    }

    private func decodeJob(from request: URLRequest) async throws -> CurtainPlacementJob {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CurtainPlacementAPIError.invalidResponse
        }
        if http.statusCode == 401 { throw CurtainPlacementAPIError.unauthorized }
        if http.statusCode == 404 { throw CurtainPlacementAPIError.notFound }
        if !(200..<300).contains(http.statusCode) {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = json?["error"] as? String ?? json?["code"] as? String
            throw CurtainPlacementAPIError.server(status: http.statusCode, code: code)
        }
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(CurtainPlacementJobResponse.self, from: data),
           let job = envelope.job {
            return job
        }
        if let job = try? decoder.decode(CurtainPlacementJob.self, from: data) {
            return job
        }
        throw CurtainPlacementAPIError.invalidResponse
    }

    private func makeRequest(path: [String], method: String) throws -> URLRequest {
        let url = path.reduce(config.apiBaseURL) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        if let token = MobileAuthTokenStore.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

/// Mock curtain job lifecycle for `-mock` / simulator without cloud.
actor CurtainPlacementMockClient: CurtainPlacementServing {
    private var jobs: [String: CurtainPlacementJob] = [:]
    private var pollCounts: [String: Int] = [:]

    func createJob(request: CurtainPlacementCreateRequest, idempotencyKey: String?) async throws -> CurtainPlacementJob {
        guard request.aiConsentAccepted else { throw CurtainPlacementAPIError.consentRequired }
        if let idempotencyKey,
           let existing = jobs.values.first(where: { $0.id.hasPrefix(stablePrefix(idempotencyKey)) }) {
            return existing
        }
        let id = "mock-curtain-\(UUID().uuidString.prefix(8))"
        let warnings = CurtainSeedMath.clientWarnings(u: request.seed.u, pitchDeg: request.seed.pitchDeg)
            .map(\.rawValue)
        let job = CurtainPlacementJob(
            id: id,
            status: "DETECTING_WINDOW",
            detectionId: "mock-det-\(id)",
            windowPolygon: nil,
            windowMaskAssetId: nil,
            confidence: nil,
            needsConfirmation: nil,
            warnings: warnings.isEmpty ? nil : warnings,
            compositeImageUrl: nil,
            originalImageUrl: nil,
            revisionId: nil,
            userFacingSummaryKo: nil,
            errorCode: nil
        )
        jobs[id] = job
        pollCounts[id] = 0
        return job
    }

    func fetchJob(id: String) async throws -> CurtainPlacementJob {
        guard var job = jobs[id] else { throw CurtainPlacementAPIError.notFound }
        let count = (pollCounts[id] ?? 0) + 1
        pollCounts[id] = count
        if job.status == "DETECTING_WINDOW", count >= 2 {
            job.status = "WINDOW_CONFIRMATION_REQUIRED"
            job.needsConfirmation = true
            job.confidence = 0.82
            job.windowPolygon = mockPolygon(around: job)
            jobs[id] = job
        } else if job.status == "COMPOSITING", count >= 1 {
            job.status = "COMPLETED"
            job.compositeImageUrl = "https://example.invalid/mock/curtain-composite.jpg"
            job.originalImageUrl = "https://example.invalid/mock/curtain-original.jpg"
            job.revisionId = "mock-rev-\(id)"
            jobs[id] = job
        }
        return job
    }

    func confirmWindow(jobId: String) async throws -> CurtainPlacementJob {
        guard var job = jobs[jobId] else { throw CurtainPlacementAPIError.notFound }
        job.status = "WINDOW_CONFIRMED"
        job.needsConfirmation = false
        jobs[jobId] = job
        return job
    }

    func reselectWindow(jobId: String, seedU: Double, seedV: Double) async throws -> CurtainPlacementJob {
        _ = seedU
        _ = seedV
        guard var job = jobs[jobId] else { throw CurtainPlacementAPIError.notFound }
        job.status = "DETECTING_WINDOW"
        job.windowPolygon = nil
        job.needsConfirmation = nil
        job.confidence = nil
        pollCounts[jobId] = 0
        jobs[jobId] = job
        return job
    }

    func composite(jobId: String) async throws -> CurtainPlacementJob {
        guard var job = jobs[jobId] else { throw CurtainPlacementAPIError.notFound }
        job.status = "COMPOSITING"
        pollCounts[jobId] = 0
        jobs[jobId] = job
        return job
    }

    private func stablePrefix(_ key: String) -> String {
        String(key.prefix(12))
    }

    private func mockPolygon(around job: CurtainPlacementJob) -> [CurtainUVPoint] {
        // Default window quad near panorama center for mock overlay.
        [
            CurtainUVPoint(u: 0.46, v: 0.38),
            CurtainUVPoint(u: 0.54, v: 0.38),
            CurtainUVPoint(u: 0.54, v: 0.62),
            CurtainUVPoint(u: 0.46, v: 0.62),
        ]
    }
}
