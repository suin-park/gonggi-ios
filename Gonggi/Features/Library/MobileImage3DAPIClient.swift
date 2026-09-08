import Foundation

/// Phase 3B — Image-to-3D mobile API (presign / start / jobs). Separate from `MobileAssetsAPIClient`.
actor MobileImage3DAPIClient {
    private let config: AppConfiguration
    private let session: URLSession

    init(config: AppConfiguration = .production, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func presign(contentType: String = "image/jpeg", contentLength: Int) async throws -> Image3DPresignResponse {
        let body: [String: Any] = [
            "contentType": contentType,
            "contentLength": contentLength,
        ]
        let (data, status) = try await authorizedJSON(
            method: "POST",
            pathComponents: ["api", "mobile", "assets", "image-to-3d", "presign"],
            body: body,
            acceptStatus: { (200..<300).contains($0) }
        )
        if status == 401 { throw MobileImage3DAPIError.unauthorized }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MobileImage3DAPIError.invalidResponse
        }
        if let ok = json["ok"] as? Bool, ok == false {
            throw mapErrorJSON(json, status: status)
        }
        guard let uploadUrl = json["uploadUrl"] as? String,
              let sourceKey = json["sourceKey"] as? String
        else {
            throw MobileImage3DAPIError.invalidResponse
        }
        var headers: [String: String] = [:]
        if let h = json["headers"] as? [String: String] {
            headers = h
        } else if let h = json["headers"] as? [String: Any] {
            for (k, v) in h {
                if let s = v as? String { headers[k] = s }
            }
        }
        if headers["Content-Type"] == nil {
            headers["Content-Type"] = contentType
        }
        return Image3DPresignResponse(
            uploadUrl: uploadUrl,
            sourceKey: sourceKey,
            headers: headers,
            expiresIn: json["expiresIn"] as? Int,
            maxBytes: json["maxBytes"] as? Int
        )
    }

    /// Direct R2 PUT. Does not log the URL.
    func putJPEG(uploadUrl: String, data: Data, headers: [String: String]) async throws {
        guard let url = URL(string: uploadUrl) else { throw MobileImage3DAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = data
        request.timeoutInterval = 120
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MobileImage3DAPIError.network }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 403 {
                throw MobileImage3DAPIError.server(code: "PRESIGN_EXPIRED", message: "업로드가 만료됐어요", status: 403)
            }
            throw MobileImage3DAPIError.network
        }
    }

    func startGeneration(
        sourceKey: String,
        clientRequestId: String,
        assetName: String? = nil
    ) async throws -> Image3DStartResponse {
        var body: [String: Any] = [
            "sourceKey": sourceKey,
            "clientRequestId": clientRequestId,
        ]
        if let assetName, !assetName.isEmpty {
            body["assetName"] = assetName
        }
        let (data, status) = try await authorizedJSON(
            method: "POST",
            pathComponents: ["api", "mobile", "assets", "image-to-3d"],
            body: body,
            acceptStatus: { $0 == 200 || $0 == 202 || (400..<600).contains($0) }
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MobileImage3DAPIError.invalidResponse
        }
        if status == 401 { throw MobileImage3DAPIError.unauthorized }
        if !(200..<300).contains(status) {
            throw mapErrorJSON(json, status: status)
        }
        guard let jobId = json["jobId"] as? String,
              let jobStatus = json["status"] as? String
        else {
            throw MobileImage3DAPIError.invalidResponse
        }
        return Image3DStartResponse(
            jobId: jobId,
            assetId: json["assetId"] as? String,
            status: jobStatus,
            clientRequestId: json["clientRequestId"] as? String ?? clientRequestId,
            replay: (json["replay"] as? Bool) ?? (status == 200)
        )
    }

    func fetchActiveJobs() async throws -> [MobileGenerationJobDTO] {
        try await fetchJobs(queryItems: [URLQueryItem(name: "status", value: "active")])
    }

    func fetchJob(id: String) async throws -> MobileGenerationJobDTO {
        let (data, status) = try await authorizedJSON(
            method: "GET",
            pathComponents: ["api", "mobile", "generation-jobs", id],
            body: nil,
            acceptStatus: { (200..<300).contains($0) || $0 == 404 }
        )
        if status == 401 { throw MobileImage3DAPIError.unauthorized }
        if status == 404 {
            throw MobileImage3DAPIError.server(code: "JOB_NOT_FOUND", message: "작업을 찾을 수 없어요", status: 404)
        }
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(JobEnvelope.self, from: data) {
            return envelope.job
        }
        if let job = try? decoder.decode(MobileGenerationJobDTO.self, from: data) {
            return job
        }
        throw MobileImage3DAPIError.invalidResponse
    }

    private func fetchJobs(queryItems: [URLQueryItem]) async throws -> [MobileGenerationJobDTO] {
        let base = ["api", "mobile", "generation-jobs"].reduce(config.apiBaseURL) {
            $0.appendingPathComponent($1)
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        guard let url = components?.url else { throw MobileImage3DAPIError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        if let token = MobileAuthTokenStore.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MobileImage3DAPIError.network }
        if http.statusCode == 401 { throw MobileImage3DAPIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw MobileImage3DAPIError.server(code: "HTTP_\(http.statusCode)", message: "", status: http.statusCode)
        }
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(JobsEnvelope.self, from: data) {
            return envelope.jobs
        }
        if let jobs = try? decoder.decode([MobileGenerationJobDTO].self, from: data) {
            return jobs
        }
        throw MobileImage3DAPIError.invalidResponse
    }

    private func authorizedJSON(
        method: String,
        pathComponents: [String],
        body: [String: Any]?,
        acceptStatus: (Int) -> Bool
    ) async throws -> (Data, Int) {
        let url = pathComponents.reduce(config.apiBaseURL) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        if let token = MobileAuthTokenStore.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MobileImage3DAPIError.network }
        if !acceptStatus(http.statusCode), (200..<300).contains(http.statusCode) == false {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                throw mapErrorJSON(json, status: http.statusCode)
            }
            throw MobileImage3DAPIError.server(code: "HTTP_\(http.statusCode)", message: "", status: http.statusCode)
        }
        return (data, http.statusCode)
    }

    private func mapErrorJSON(_ json: [String: Any], status: Int) -> MobileImage3DAPIError {
        let code = (json["error"] as? String) ?? (json["code"] as? String) ?? "UNKNOWN"
        let message = (json["message"] as? String) ?? ""
        switch code {
        case "FEATURE_DISABLED":
            return .featureDisabled
        case "INSUFFICIENT_CREDITS":
            let required = (json["required"] as? Int) ?? (json["requiredCredits"] as? Int)
            let available = (json["available"] as? Int) ?? (json["currentCredits"] as? Int)
            return .insufficientCredits(required: required, available: available)
        case "GENERATION_LIMIT_REACHED":
            return .generationLimitReached
        case "RATE_LIMITED":
            return .rateLimited
        case "NSFW_IMAGE_BLOCKED":
            return .nsfwBlocked
        case "INVALID_SOURCE", "SOURCE_NOT_FOUND", "SOURCE_NOT_OWNED", "UNSUPPORTED_IMAGE", "FILE_TOO_LARGE",
             "CLIENT_REQUEST_ID_REQUIRED":
            return .invalidSource(code: code, message: friendlySourceMessage(code: code, fallback: message))
        case "GENERATION_START_FAILED":
            return .generationStartFailed(message: message)
        default:
            return .server(code: code, message: message, status: status)
        }
    }

    private func friendlySourceMessage(code: String, fallback: String) -> String {
        switch code {
        case "FILE_TOO_LARGE": return "파일이 너무 커요"
        case "UNSUPPORTED_IMAGE": return "JPEG 사진만 사용할 수 있어요"
        case "SOURCE_NOT_FOUND", "SOURCE_NOT_OWNED", "INVALID_SOURCE":
            return fallback.isEmpty ? "사진을 확인하지 못했어요" : fallback
        default:
            return fallback.isEmpty ? "사진이 올바르지 않아요" : fallback
        }
    }

    private struct JobsEnvelope: Decodable {
        var jobs: [MobileGenerationJobDTO]
    }

    private struct JobEnvelope: Decodable {
        var job: MobileGenerationJobDTO
    }
}
