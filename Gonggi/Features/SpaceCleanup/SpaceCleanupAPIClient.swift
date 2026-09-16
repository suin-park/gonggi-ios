import Foundation

enum SpaceCleanupAPIError: Error, Equatable {
    case consentRequired
    case offline
    case unauthorized
    case notFound
    case invalidResponse
    case server(status: Int)

    var userMessage: String {
        switch self {
        case .consentRequired: return "AI 이용 동의가 필요합니다."
        case .offline: return "네트워크 연결을 확인해 주세요."
        case .unauthorized: return "로그인이 필요합니다."
        case .notFound: return "작업을 찾을 수 없습니다."
        case .invalidResponse: return "서버 응답을 확인하지 못했습니다."
        case .server: return "요청을 처리하지 못했습니다."
        }
    }
}

protocol SpaceCleanupServing: Sendable {
    func createJob(request: SpaceCleanupCreateRequest, idempotencyKey: String) async throws -> SpaceCleanupJobDTO
    func fetchJob(id: String) async throws -> SpaceCleanupJobDTO
    func confirmJob(id: String, removalTarget: String) async throws -> SpaceCleanupJobDTO
    func retryJob(id: String) async throws -> SpaceCleanupJobDTO
}

actor SpaceCleanupAPIClient: SpaceCleanupServing {
    private let config: AppConfiguration
    private let session: URLSession

    init(config: AppConfiguration = .production, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func createJob(request: SpaceCleanupCreateRequest, idempotencyKey: String) async throws -> SpaceCleanupJobDTO {
        var req = try makeRequest(path: ["api", "gonggi", "space-cleanups"], method: "POST")
        req.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        req.httpBody = try JSONEncoder().encode(request)
        return try await decodeJob(req)
    }

    func fetchJob(id: String) async throws -> SpaceCleanupJobDTO {
        let req = try makeRequest(path: ["api", "gonggi", "space-cleanups", id], method: "GET")
        return try await decodeJob(req)
    }

    func confirmJob(id: String, removalTarget: String) async throws -> SpaceCleanupJobDTO {
        var req = try makeRequest(
            path: ["api", "gonggi", "space-cleanups", id, "confirm"],
            method: "POST"
        )
        struct Body: Encodable {
            var removalTarget: String
        }
        req.httpBody = try JSONEncoder().encode(Body(removalTarget: removalTarget))
        return try await decodeJob(req)
    }

    func retryJob(id: String) async throws -> SpaceCleanupJobDTO {
        var req = try makeRequest(
            path: ["api", "gonggi", "space-cleanups", id, "retry"],
            method: "POST"
        )
        req.httpBody = Data("{}".utf8)
        return try await decodeJob(req)
    }

    private struct Envelope: Codable {
        var ok: Bool?
        var job: SpaceCleanupJobDTO?
        var error: String?
        var message: String?
    }

    private func decodeJob(_ request: URLRequest) async throws -> SpaceCleanupJobDTO {
        let (data, http) = try await perform(request)
        try throwIfNeeded(http: http, data: data)
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data), let job = envelope.job {
            return job
        }
        if let job = try? JSONDecoder().decode(SpaceCleanupJobDTO.self, from: data) {
            return job
        }
        throw SpaceCleanupAPIError.invalidResponse
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SpaceCleanupAPIError.invalidResponse
            }
            return (data, http)
        } catch let error as SpaceCleanupAPIError {
            throw error
        } catch {
            throw SpaceCleanupAPIError.offline
        }
    }

    private func throwIfNeeded(http: HTTPURLResponse, data: Data) throws {
        if http.statusCode == 401 { throw SpaceCleanupAPIError.unauthorized }
        if http.statusCode == 404 { throw SpaceCleanupAPIError.notFound }
        if (200..<300).contains(http.statusCode) { return }
        throw SpaceCleanupAPIError.server(status: http.statusCode)
    }

    private func makeRequest(path: [String], method: String) throws -> URLRequest {
        let url = path.reduce(config.apiBaseURL) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        if let token = MobileAuthTokenStore.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
