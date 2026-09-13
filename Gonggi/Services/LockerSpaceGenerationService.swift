import Foundation

/// Shared app config for 3D Locker / Gonggi HTTP + OAuth.
/// Google client id comes from Info.plist (`GoogleClientID` ← Config/Auth.xcconfig). Do not hardcode.
struct AppConfiguration: Sendable {
    var apiBaseURL: URL
    var sessionCookieName: String
    /// iOS OAuth client id (`….apps.googleusercontent.com`).
    var googleClientID: String
    /// Reverse-DNS URL scheme for ASWebAuthenticationSession / Google redirect.
    var googleReversedClientID: String

    static func reversedGoogleClientID(from clientID: String) -> String {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.split(separator: ".").reversed().joined(separator: ".")
    }

    static func loadProduction() -> AppConfiguration {
        let clientID = (Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reversedFromPlist = (Bundle.main.object(forInfoDictionaryKey: "GoogleReversedClientID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reversed = reversedFromPlist.isEmpty ? reversedGoogleClientID(from: clientID) : reversedFromPlist
        return AppConfiguration(
            apiBaseURL: URL(string: "https://www.3d-locker.com")!,
            sessionCookieName: "whik_session",
            googleClientID: clientID,
            googleReversedClientID: reversed
        )
    }

    static let production = AppConfiguration.loadProduction()

    var isGoogleSignInConfigured: Bool {
        !googleClientID.isEmpty && googleClientID.contains("apps.googleusercontent.com")
    }
}

/// Real 3D Locker video → Gaussian pipeline client.
/// Flow: create draft + signed PUT → upload mov → start → poll status.
final class LockerSpaceGenerationService: SpaceGenerationService, @unchecked Sendable {
    private let config: AppConfiguration
    private let session: URLSession
    /// jobId → (spaceId, uploadURL, qualityProfile, local mapping)
    private var jobContext: [String: JobContext] = [:]
    private let lock = NSLock()

    private struct JobContext {
        var spaceId: String
        var uploadURL: URL?
        var qualityProfile: String
        var videoByteSize: Int?
        var serverStatus: String
        var overallProgress: Double
        var idempotencyKey: String?
    }

    init(config: AppConfiguration = .production, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    private static func apiURL(base: URL, path: String) throws -> URL {
        let root = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: root + normalized) else {
            throw SpaceGenerationError.networkUnavailable
        }
        return url
    }

    func createSpace(_ request: CreateSpaceRequest) async throws -> CreateSpaceResponse {
        let url = try Self.apiURL(base: config.apiBaseURL, path: "/api/gaussian-spaces/video")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        try attachAuth(&req)

        // Placeholder size — uploadCapture updates with real byte size before PUT.
        let byteSize = request.videoByteSize ?? 1_048_576
        let profile = ServerGenerationProfileMapper.resolveServerProfile(
            guideQualityProfile: request.qualityProfile
        )
        let idempotencyKey = request.idempotencyKey ?? "gonggi-\(UUID().uuidString)"
        let body: [String: Any] = [
            "name": request.name,
            "visibility": request.visibility,
            "filename": request.videoFilename,
            "contentType": request.videoContentType,
            "byteSize": byteSize,
            "qualityProfile": profile,
            "idempotencyKey": idempotencyKey,
        ]
        if let duration = request.durationSec {
            var withDuration = body
            withDuration["durationSec"] = duration
            req.httpBody = try JSONSerialization.data(withJSONObject: withDuration)
        } else {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw SpaceGenerationError.networkUnavailable
        }
        if http.statusCode == 401 {
            throw SpaceGenerationError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let code = (json["error"] as? String)
                ?? (json["errorCode"] as? String)
                ?? "create_failed_\(http.statusCode)"
            #if DEBUG
            print("[video-gaussian] create failed status=\(http.statusCode) code=\(code) profile=\(profile) idem=\(idempotencyKey)")
            #endif
            throw SpaceGenerationError.server(code: code, httpStatus: http.statusCode)
        }

        let decoded = try JSONDecoder().decode(CreateDTO.self, from: data)
        let spaceId = decoded.space.id
        let jobId = decoded.job.id
        let uploadURL = decoded.uploadUrl.flatMap(URL.init(string:))
        lock.lock()
        jobContext[jobId] = JobContext(
            spaceId: spaceId,
            uploadURL: uploadURL,
            qualityProfile: decoded.job.qualityProfile ?? profile,
            videoByteSize: nil,
            serverStatus: decoded.job.status ?? "uploading",
            overallProgress: 0.05,
            idempotencyKey: idempotencyKey
        )
        lock.unlock()

        return CreateSpaceResponse(spaceId: spaceId, jobId: jobId, uploadURL: uploadURL, idempotencyKey: idempotencyKey)
    }

    func uploadCapture(_ request: UploadCaptureRequest) async throws {
        lock.lock()
        var ctx = jobContext[request.jobId]
        lock.unlock()
        guard var context = ctx else { throw SpaceGenerationError.jobNotFound }
        guard let uploadURL = context.uploadURL else {
            throw SpaceGenerationError.uploadFailed
        }

        let fileURL = request.localCaptureURL
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let byteSize = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard byteSize > 0 else { throw SpaceGenerationError.uploadFailed }

        var put = URLRequest(url: uploadURL)
        put.httpMethod = "PUT"
        put.setValue("video/quicktime", forHTTPHeaderField: "Content-Type")
        put.httpBody = try Data(contentsOf: fileURL)

        let (_, putResponse) = try await session.data(for: put)
        guard let http = putResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SpaceGenerationError.uploadFailed
        }

        context.videoByteSize = byteSize
        context.serverStatus = "uploaded"
        context.overallProgress = 0.2
        lock.lock()
        jobContext[request.jobId] = context
        lock.unlock()
    }

    func startGeneration(jobId: String) async throws {
        lock.lock()
        let ctx = jobContext[jobId]
        lock.unlock()
        guard let context = ctx else { throw SpaceGenerationError.jobNotFound }

        let path = "/api/gaussian-spaces/\(context.spaceId)/video-conversion/\(jobId)/start"
        let url = try Self.apiURL(base: config.apiBaseURL, path: path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try attachAuth(&req)
        var body: [String: Any] = [
            "qualityProfile": ServerGenerationProfileMapper.sanitize(context.qualityProfile)
        ]
        if let size = context.videoByteSize {
            body["videoByteSize"] = size
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw SpaceGenerationError.networkUnavailable
        }
        if http.statusCode == 401 { throw SpaceGenerationError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let code = (json["error"] as? String)
                ?? (json["errorCode"] as? String)
                ?? "start_failed_\(http.statusCode)"
            throw SpaceGenerationError.server(code: code, httpStatus: http.statusCode)
        }
        _ = data
        lock.lock()
        jobContext[jobId]?.serverStatus = "processing"
        jobContext[jobId]?.overallProgress = 0.35
        lock.unlock()
    }

    func fetchStatus(jobId: String) async throws -> GenerationJobStatus {
        lock.lock()
        let ctx = jobContext[jobId]
        lock.unlock()
        guard let context = ctx else { throw SpaceGenerationError.jobNotFound }

        let path = "/api/gaussian-spaces/\(context.spaceId)/video-conversion/\(jobId)"
        let url = try Self.apiURL(base: config.apiBaseURL, path: path)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        try attachAuth(&req)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw SpaceGenerationError.networkUnavailable
        }
        if http.statusCode == 401 { throw SpaceGenerationError.unauthorized }
        if http.statusCode == 404 { throw SpaceGenerationError.jobNotFound }
        guard (200..<300).contains(http.statusCode) else {
            throw SpaceGenerationError.unknown("status failed (\(http.statusCode))")
        }

        let decoded = try JSONDecoder().decode(StatusDTO.self, from: data)
        let status = decoded.job.status ?? context.serverStatus
        let progress = Self.mapProgress(status: status, serverProgress: decoded.job.progress)
        lock.lock()
        jobContext[jobId]?.serverStatus = status
        jobContext[jobId]?.overallProgress = progress
        lock.unlock()

        return GenerationJobStatus(
            jobId: jobId,
            spaceId: context.spaceId,
            steps: Self.steps(for: status, progress: progress),
            estimatedMinutesRemaining: status == "completed" ? 0 : (Self.isFailed(status) ? 0 : 8),
            overallProgress: Self.isFailed(status) ? 0 : progress
        )
    }

    func cancel(jobId: String) async {
        lock.lock()
        let ctx = jobContext[jobId]
        lock.unlock()
        guard let context = ctx else { return }
        let path = "/api/gaussian-spaces/\(context.spaceId)/video-conversion/\(jobId)"
        guard let url = try? Self.apiURL(base: config.apiBaseURL, path: path) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        try? attachAuth(&req)
        _ = try? await session.data(for: req)
        lock.lock()
        jobContext.removeValue(forKey: jobId)
        lock.unlock()
    }

    private func attachAuth(_ request: inout URLRequest) throws {
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            throw SpaceGenerationError.unauthorized
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private static func isFailed(_ status: String) -> Bool {
        status == "failed" || status == "cancelled" || status == "expired"
    }

    private static func mapProgress(status: String, serverProgress: Double?) -> Double {
        if isFailed(status) { return 0 }
        if let serverProgress { return min(max(serverProgress, 0), 1) }
        switch status {
        case "uploading": return 0.1
        case "uploaded", "queued": return 0.25
        case "processing": return 0.55
        case "completed": return 1.0
        default: return 0.4
        }
    }

    private static func steps(for status: String, progress: Double) -> [ProcessingStepState] {
        if isFailed(status) {
            return ProcessingStepKind.allCases.map {
                ProcessingStepState(kind: $0, status: .failed(status))
            }
        }
        let kinds = ProcessingStepKind.allCases
        return kinds.map { kind in
            switch (kind, status) {
            case (.upload, "uploading"):
                return ProcessingStepState(kind: kind, status: .active(progress: progress))
            case (.upload, _):
                return ProcessingStepState(kind: kind, status: .completed)
            case (.frameAnalysis, "queued"), (.frameAnalysis, "uploaded"):
                return ProcessingStepState(kind: kind, status: .active(progress: progress))
            case (.frameAnalysis, "processing"), (.frameAnalysis, "completed"):
                return ProcessingStepState(kind: kind, status: .completed)
            case (.spaceGeneration, "processing"):
                return ProcessingStepState(kind: kind, status: .active(progress: progress))
            case (.spaceGeneration, "completed"):
                return ProcessingStepState(kind: kind, status: .completed)
            case (.optimization, "completed"):
                return ProcessingStepState(kind: kind, status: .completed)
            default:
                return ProcessingStepState(kind: kind, status: .waiting)
            }
        }
    }

    private struct CreateDTO: Decodable {
        var space: IdDTO
        var job: JobDTO
        var uploadUrl: String?
    }

    private struct StatusDTO: Decodable {
        var job: JobDTO
    }

    private struct IdDTO: Decodable {
        var id: String
    }

    private struct JobDTO: Decodable {
        var id: String
        var status: String?
        var qualityProfile: String?
        /// Server may send object progressJson — ignore non-numeric.
        var progress: Double?

        enum CodingKeys: String, CodingKey {
            case id, status, qualityProfile, progress
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            status = try c.decodeIfPresent(String.self, forKey: .status)
            qualityProfile = try c.decodeIfPresent(String.self, forKey: .qualityProfile)
            if let value = try? c.decode(Double.self, forKey: .progress) {
                progress = value
            } else if let obj = try? c.decode([String: Double].self, forKey: .progress),
                      let overall = obj["overall"] ?? obj["progress"] {
                progress = overall
            } else {
                progress = nil
            }
        }
    }
}
