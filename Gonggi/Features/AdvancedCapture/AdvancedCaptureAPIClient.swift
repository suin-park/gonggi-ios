import Foundation

/// Client for Locker advanced-capture (Astra) analyze + status.
protocol AdvancedCaptureAPIClienting: Sendable {
    func startAnalyze(sessionId: String, force: Bool) async throws -> AdvancedCaptureAnalyzeStartResponse
    func fetchStatus(jobId: String) async throws -> AdvancedCaptureStatusResponse
}

struct AdvancedCaptureAnalyzeStartResponse: Equatable, Sendable {
    var ok: Bool
    var sessionId: String
    var jobId: String
    var status: AdvancedCaptureAnalysisStatus
    var reused: Bool
}

struct AdvancedCaptureStatusResponse: Equatable, Sendable {
    var ok: Bool
    var status: AdvancedCaptureAnalysisStatus
    var guidePlan: AdvancedCaptureGuidePlan?
    var errorCode: String?
}

/// Live HTTP client — POST/GET `/api/gonggi/advanced-capture/*`.
final class LockerAdvancedCaptureAPIClient: AdvancedCaptureAPIClienting, @unchecked Sendable {
    private let config: AppConfiguration
    private let session: URLSession

    init(config: AppConfiguration = .production, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func startAnalyze(sessionId: String, force: Bool = false) async throws -> AdvancedCaptureAnalyzeStartResponse {
        let url = config.apiBaseURL.appendingPathComponent("api/gonggi/advanced-capture/analyze")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = MobileAuthTokenStore.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        struct Body: Encodable {
            var sessionId: String
            var force: Bool
        }
        request.httpBody = try JSONEncoder().encode(Body(sessionId: sessionId, force: force))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AdvancedCaptureError.network
        }
        if http.statusCode == 401 {
            throw AdvancedCaptureError.unauthorized
        }
        let decoded = try JSONDecoder().decode(AnalyzeDTO.self, from: data)
        guard decoded.ok else {
            throw AdvancedCaptureError.server(decoded.errorCode ?? "analyze_failed")
        }
        return AdvancedCaptureAnalyzeStartResponse(
            ok: true,
            sessionId: decoded.sessionId ?? sessionId,
            jobId: decoded.jobId ?? sessionId,
            status: Self.mapStatus(decoded.status),
            reused: decoded.reused ?? false
        )
    }

    func fetchStatus(jobId: String) async throws -> AdvancedCaptureStatusResponse {
        var components = URLComponents(
            url: config.apiBaseURL.appendingPathComponent("api/gonggi/advanced-capture/status"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "id", value: jobId)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = MobileAuthTokenStore.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AdvancedCaptureError.network
        }
        if http.statusCode == 401 {
            throw AdvancedCaptureError.unauthorized
        }
        if http.statusCode == 404 {
            throw AdvancedCaptureError.jobNotFound
        }
        let decoded = try JSONDecoder().decode(StatusDTO.self, from: data)
        guard decoded.ok else {
            throw AdvancedCaptureError.server(decoded.errorCode ?? "status_failed")
        }
        return AdvancedCaptureStatusResponse(
            ok: true,
            status: Self.mapStatus(decoded.status),
            guidePlan: decoded.result?.guidePlan,
            errorCode: decoded.errorCode
        )
    }

    private static func mapStatus(_ raw: String?) -> AdvancedCaptureAnalysisStatus {
        switch raw {
        case "queued": return .queued
        case "analyzing", "generating": return .analyzing
        case "ready", "completed": return .ready
        case "failed": return .failed
        default: return .analyzing
        }
    }

    private struct AnalyzeDTO: Decodable {
        var ok: Bool
        var sessionId: String?
        var jobId: String?
        var status: String?
        var reused: Bool?
        var errorCode: String?
    }

    private struct StatusDTO: Decodable {
        var ok: Bool
        var status: String?
        var errorCode: String?
        var result: ResultDTO?
    }

    private struct ResultDTO: Decodable {
        var guidePlan: AdvancedCaptureGuidePlan?
    }
}

/// Offline / UI mock — completes after a short delay with `mockDefault` plan.
final class MockAdvancedCaptureAPIClient: AdvancedCaptureAPIClienting, @unchecked Sendable {
    private let delayNs: UInt64
    private var startedAt: [String: Date] = [:]
    private let lock = NSLock()

    init(delayNs: UInt64 = 1_500_000_000) {
        self.delayNs = delayNs
    }

    func startAnalyze(sessionId: String, force: Bool = false) async throws -> AdvancedCaptureAnalyzeStartResponse {
        lock.lock()
        startedAt[sessionId] = Date()
        lock.unlock()
        _ = force
        return AdvancedCaptureAnalyzeStartResponse(
            ok: true,
            sessionId: sessionId,
            jobId: sessionId,
            status: .queued,
            reused: false
        )
    }

    func fetchStatus(jobId: String) async throws -> AdvancedCaptureStatusResponse {
        lock.lock()
        let start = startedAt[jobId] ?? Date().addingTimeInterval(-10)
        lock.unlock()
        let elapsed = Date().timeIntervalSince(start)
        if elapsed < 1.2 {
            return AdvancedCaptureStatusResponse(ok: true, status: .analyzing, guidePlan: nil, errorCode: nil)
        }
        return AdvancedCaptureStatusResponse(
            ok: true,
            status: .ready,
            guidePlan: .mockDefault(sessionId: jobId),
            errorCode: nil
        )
    }
}
