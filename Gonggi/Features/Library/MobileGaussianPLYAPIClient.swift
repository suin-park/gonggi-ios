import Foundation

/// Client for external Gaussian PLY upload: create session → R2 PUT → complete.
actor MobileGaussianPLYAPIClient {
    private let config: AppConfiguration
    private let session: URLSession

    /// Soft warning threshold aligned with cloud `GAUSSIAN_SPACE_MOBILE_WARN_BYTES` (80MB).
    static let mobileWarnBytes = 80 * 1024 * 1024
    /// Hard limit aligned with cloud default `GAUSSIAN_SPACE_MAX_FILE_BYTES` (500MB).
    static let maxFileBytes = 500 * 1024 * 1024

    init(config: AppConfiguration = .production, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    struct UploadResult: Equatable, Sendable {
        let spaceId: String
        let name: String
        let status: String
    }

    enum PLYImportError: Error {
        case notAuthenticated
        case invalidFile
        case tooLarge
        case orgRequired
        case invalidResponse
        case server(code: String)
        case network
        case uploadFailed

        var userMessage: String {
            switch self {
            case .notAuthenticated: return "로그인이 필요해요"
            case .invalidFile: return "PLY 파일만 가져올 수 있어요"
            case .tooLarge: return "파일이 너무 커요 (최대 500MB)"
            case .orgRequired: return "계정 조직 정보가 없어요. 다시 로그인해 주세요"
            case .invalidResponse: return "서버 응답을 읽지 못했어요"
            case .server(let code): return "가져오기에 실패했어요 (\(code))"
            case .network: return "네트워크 연결을 확인해 주세요"
            case .uploadFailed: return "파일 업로드에 실패했어요"
            }
        }
    }

    func importPLY(fileURL: URL, name: String, visibility: String = "private") async throws -> UploadResult {
        let access = fileURL.startAccessingSecurityScopedResource()
        defer { if access { fileURL.stopAccessingSecurityScopedResource() } }

        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .nameKey])
        let size = values.fileSize ?? 0
        guard size > 0 else { throw PLYImportError.invalidFile }
        guard size <= Self.maxFileBytes else { throw PLYImportError.tooLarge }

        let fileName = values.name ?? fileURL.lastPathComponent
        guard fileName.lowercased().hasSuffix(".ply") else { throw PLYImportError.invalidFile }

        let sessionRes = try await createSession(
            name: name,
            visibility: visibility,
            fileName: fileName,
            fileSize: size
        )
        try await putFile(to: sessionRes.uploadURL, fileURL: fileURL)
        let space = try await complete(spaceId: sessionRes.spaceId)
        return space
    }

    private struct CreateSessionResult {
        let spaceId: String
        let uploadURL: URL
    }

    private func createSession(
        name: String,
        visibility: String,
        fileName: String,
        fileSize: Int
    ) async throws -> CreateSessionResult {
        let url = try apiURL("/api/gaussian-spaces")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        try attachAuth(&req)
        let body: [String: Any] = [
            "name": name,
            "visibility": visibility,
            "fileName": fileName,
            "fileSize": fileSize,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw PLYImportError.network }
        if http.statusCode == 401 { throw PLYImportError.notAuthenticated }
        if http.statusCode == 400 {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            if code == "ORG_REQUIRED" { throw PLYImportError.orgRequired }
            throw PLYImportError.server(code: code ?? "bad_request")
        }
        guard (200...299).contains(http.statusCode) else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw PLYImportError.server(code: code ?? "http_\(http.statusCode)")
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let space = json["space"] as? [String: Any],
            let spaceId = space["id"] as? String,
            let uploadUrlStr = json["uploadUrl"] as? String,
            let uploadURL = URL(string: uploadUrlStr)
        else {
            throw PLYImportError.invalidResponse
        }
        return CreateSessionResult(spaceId: spaceId, uploadURL: uploadURL)
    }

    private func putFile(to uploadURL: URL, fileURL: URL) async throws {
        var req = URLRequest(url: uploadURL)
        req.httpMethod = "PUT"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: req, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PLYImportError.uploadFailed
        }
    }

    private func complete(spaceId: String) async throws -> UploadResult {
        let url = try apiURL("/api/gaussian-spaces/\(spaceId)/complete")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        try attachAuth(&req)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw PLYImportError.network }
        if http.statusCode == 401 { throw PLYImportError.notAuthenticated }
        guard (200...299).contains(http.statusCode) else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw PLYImportError.server(code: code ?? "http_\(http.statusCode)")
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let space = json["space"] as? [String: Any],
            let id = space["id"] as? String
        else {
            throw PLYImportError.invalidResponse
        }
        return UploadResult(
            spaceId: id,
            name: (space["name"] as? String) ?? "",
            status: (space["status"] as? String) ?? "ready"
        )
    }

    private func attachAuth(_ request: inout URLRequest) throws {
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            throw PLYImportError.notAuthenticated
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func apiURL(_ path: String) throws -> URL {
        let root = config.apiBaseURL.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: root + normalized) else {
            throw PLYImportError.network
        }
        return url
    }
}
