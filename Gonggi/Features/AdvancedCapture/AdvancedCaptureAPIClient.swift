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
        let url = try Self.apiURL(base: config.apiBaseURL, path: "/api/gonggi/advanced-capture/analyze")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
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

        let json = try Self.jsonObject(from: data)
        let ok = json["ok"] as? Bool ?? false
        let errorCode = json["errorCode"] as? String
        guard ok else {
            throw AdvancedCaptureError.server(Self.userFacingServerCode(errorCode))
        }
        return AdvancedCaptureAnalyzeStartResponse(
            ok: true,
            sessionId: (json["sessionId"] as? String) ?? sessionId,
            jobId: (json["jobId"] as? String) ?? sessionId,
            status: Self.mapStatus(json["status"] as? String),
            reused: (json["reused"] as? Bool) ?? false
        )
    }

    func fetchStatus(jobId: String) async throws -> AdvancedCaptureStatusResponse {
        var components = URLComponents(
            url: try Self.apiURL(base: config.apiBaseURL, path: "/api/gonggi/advanced-capture/status"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "id", value: jobId)]
        guard let url = components.url else { throw AdvancedCaptureError.network }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
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

        let json = try Self.jsonObject(from: data)
        let ok = json["ok"] as? Bool ?? false
        let errorCode = json["errorCode"] as? String
        guard ok else {
            throw AdvancedCaptureError.server(Self.userFacingServerCode(errorCode))
        }

        var guidePlan: AdvancedCaptureGuidePlan?
        if let result = json["result"] as? [String: Any],
           let planObj = result["guidePlan"] {
            let planData = try JSONSerialization.data(withJSONObject: planObj)
            guidePlan = AdvancedCaptureCopy.sanitize(
                try JSONDecoder().decode(AdvancedCaptureGuidePlan.self, from: planData)
            )
        }

        return AdvancedCaptureStatusResponse(
            ok: true,
            status: Self.mapStatus(json["status"] as? String),
            guidePlan: guidePlan,
            errorCode: errorCode
        )
    }

    /// Avoid `appendingPathComponent("a/b/c")` — Foundation percent-encodes `/` as `%2F` and 404s with HTML.
    private static func apiURL(base: URL, path: String) throws -> URL {
        let root = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: root + normalizedPath) else {
            throw AdvancedCaptureError.network
        }
        return url
    }

    private static func jsonObject(from data: Data) throws -> [String: Any] {
        guard !data.isEmpty else {
            throw AdvancedCaptureError.unknown("서버 응답이 비어 있어요.")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AdvancedCaptureError.unknown("서버 응답 형식을 읽지 못했어요. 잠시 후 다시 시도해 주세요.")
        }
        return obj
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

    private static func userFacingServerCode(_ code: String?) -> String {
        switch code {
        case "space_not_ready":
            return "공간이 아직 준비되지 않았어요. LatLong 생성이 끝난 뒤 다시 시도해 주세요."
        case "missing_latlong":
            return "LatLong 이미지를 서버에서 찾지 못했어요."
        case "missing_inputs":
            return "촬영 원본을 서버에서 찾지 못했어요."
        case "feature_disabled":
            return "3D 공간으로 확장이 잠시 비활성화되어 있어요."
        case "forbidden", "auth_required":
            return "로그인이 필요하거나 이 공간에 대한 권한이 없어요."
        case "astra_failed":
            return "분석 서버에서 오류가 났어요."
        case let c?:
            return c
        default:
            return "analyze_failed"
        }
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
            guidePlan: AdvancedCaptureCopy.sanitize(.mockDefault(sessionId: jobId)),
            errorCode: nil
        )
    }
}
