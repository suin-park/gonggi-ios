import Foundation

enum StoreShelfAPIError: Error, Equatable {
    case notSignedIn
    case forbidden
    case notFound
    case server(status: Int, code: String?)
    case invalidResponse
    case transport

    /// The deployed server has no 매장 routes yet (older server): the feature is simply not available there.
    var isServerWithoutFeature: Bool {
        if case .notFound = self { return true }
        return false
    }

    var userMessage: String {
        switch self {
        case .notSignedIn: return "로그인이 필요해요"
        case .forbidden: return "이 작업을 할 권한이 없어요"
        case .notFound: return "서버에서 해당 정보를 찾지 못했어요"
        case .server(_, let code):
            switch code {
            case "UPLOAD_INCOMPLETE", "UPLOAD_SIZE_MISMATCH": return "업로드가 완료되지 않았어요. 다시 시도해 주세요"
            case "NOT_STORE_MANAGER": return "이 매장의 담당자가 아니에요"
            case "ANALYSIS_DISABLED": return "사진 분석을 지금은 사용할 수 없어요"
            case "ANALYSIS_LIMIT_REACHED": return "이 촬영의 분석 횟수 한도에 도달했어요. 새로 촬영해 주세요"
            case "TOO_MANY_PHOTOS", "TOO_MANY_PHOTOS_FOR_ANALYSIS": return "한 번에 보낼 수 있는 사진 수를 넘었어요"
            case "PHOTO_TOO_LARGE", "PHOTOS_TOO_LARGE_FOR_ANALYSIS", "SESSION_TOO_LARGE": return "사진 용량이 서버 한도를 넘었어요"
            case "UPLOAD_INCOMPLETE": return "사진 업로드가 끝나지 않았어요. 다시 시도해 주세요"
            default: return "서버 오류가 발생했어요. 잠시 후 다시 시도해 주세요"
            }
        case .invalidResponse: return "서버 응답을 읽지 못했어요"
        case .transport: return "네트워크에 연결하지 못했어요"
        }
    }
}

/// Talks to the 매장 routes (`/api/gonggi/stores…`). Reads are public; everything that writes needs the signed-in
/// token and is authorised again on the server (the app only hides buttons).
final class StoreShelfAPIClient: @unchecked Sendable {
    private let config: AppConfiguration
    private let session: URLSession

    init(config: AppConfiguration = .production, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    private func url(_ parts: [String], query: [URLQueryItem] = []) -> URL {
        var u = config.storeShelfBaseURL.appendingPathComponent("api/gonggi")
        for p in parts { u.appendPathComponent(p) }
        guard !query.isEmpty, var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return u }
        c.queryItems = query
        return c.url ?? u
    }

    private func request(_ method: String, _ url: URL, body: Data? = nil, auth: Bool) throws -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 30
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if auth {
            guard let token = MobileAuthTokenStore.shared.getAccessToken() else { throw StoreShelfAPIError.notSignedIn }
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if let token = MobileAuthTokenStore.shared.getAccessToken() {
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return r
    }

    private func send<T: Decodable>(_ r: URLRequest, as type: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: r)
        } catch {
            throw StoreShelfAPIError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw StoreShelfAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            switch http.statusCode {
            case 401: throw StoreShelfAPIError.notSignedIn
            case 403: throw StoreShelfAPIError.forbidden
            case 404: throw StoreShelfAPIError.notFound
            default: throw StoreShelfAPIError.server(status: http.statusCode, code: code)
            }
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw StoreShelfAPIError.invalidResponse
        }
    }

    private struct ErrorBody: Decodable { var error: String? }
    private struct ListBody<T: Decodable>: Decodable { var items: [T] }
    private struct ReleaseBody: Decodable { var release: RemoteReleaseView }
    private struct Empty: Decodable {}

    // MARK: Customer reads

    func listStores(latitude: Double?, longitude: Double?, query: String?) async throws -> [RemoteStoreItem] {
        var q: [URLQueryItem] = []
        if let latitude, let longitude {
            q.append(URLQueryItem(name: "lat", value: String(latitude)))
            q.append(URLQueryItem(name: "lng", value: String(longitude)))
        }
        if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty { q.append(URLQueryItem(name: "q", value: query)) }
        let body = try await send(try request("GET", url(["stores"], query: q), auth: false), as: ListBody<RemoteStoreItem>.self)
        return body.items
    }

    func publishedRelease(storeId: String) async throws -> RemoteReleaseView {
        try await send(try request("GET", url(["stores", storeId, "release"]), auth: false), as: ReleaseBody.self).release
    }

    // MARK: Manager

    func myStores() async throws -> [RemoteManagedStore] {
        try await send(try request("GET", url(["stores", "mine"]), auth: true), as: ListBody<RemoteManagedStore>.self).items
    }

    func createDraft(storeId: String, declaration: ReleaseDeclarationBody) async throws -> RemoteDraftRelease {
        let body = try JSONEncoder().encode(declaration)
        return try await send(try request("POST", url(["stores", storeId, "releases"]), body: body, auth: true), as: RemoteDraftRelease.self)
    }

    func publish(storeId: String, releaseId: String) async throws {
        _ = try await send(try request("POST", url(["stores", storeId, "releases", releaseId, "publish"]), body: Data("{}".utf8), auth: true),
                           as: Empty.self)
    }

    func linkProduct(storeId: String, storeProductId: String, catalogProductId: String) async throws {
        let body = try JSONEncoder().encode(["catalogProductId": catalogProductId])
        _ = try await send(try request("PUT", url(["stores", storeId, "product-links", storeProductId]), body: body, auth: true), as: Empty.self)
    }

    func unlinkProduct(storeId: String, storeProductId: String) async throws {
        _ = try await send(try request("DELETE", url(["stores", storeId, "product-links", storeProductId]), auth: true), as: Empty.self)
    }

    // MARK: Automatic capture and analysis (store manager only; the server decides, the app only asks)

    func startCapture(storeId: String, body: StartCaptureBody) async throws -> RemoteStartedCapture {
        let data = try JSONEncoder().encode(body)
        return try await send(try request("POST", url(["stores", storeId, "captures"]), body: data, auth: true), as: RemoteStartedCapture.self)
    }

    func registerPhotos(storeId: String, sessionId: String, body: RegisterPhotosBody) async throws -> RemoteRegisteredPhotos {
        let data = try JSONEncoder().encode(body)
        return try await send(try request("POST", url(["stores", storeId, "captures", sessionId, "photos"]), body: data, auth: true),
                              as: RemoteRegisteredPhotos.self)
    }

    func confirmUploads(storeId: String, sessionId: String) async throws -> RemoteConfirmedUploads {
        try await send(try request("POST", url(["stores", storeId, "captures", sessionId, "uploaded"]), body: Data("{}".utf8), auth: true),
                       as: RemoteConfirmedUploads.self)
    }

    func startAnalysis(storeId: String, sessionId: String, force: Bool = false) async throws -> RemoteStartedAnalysis {
        // reanalyze: "새 설정으로 재분석" (a separate run, its own cache); false: continue / return the same run.
        let body = try JSONEncoder().encode(["reanalyze": force])
        return try await send(try request("POST", url(["stores", storeId, "captures", sessionId, "analyze"]), body: body, auth: true),
                              as: RemoteStartedAnalysis.self)
    }

    func capture(storeId: String, sessionId: String) async throws -> RemoteCaptureView {
        try await send(try request("GET", url(["stores", storeId, "captures", sessionId]), auth: true), as: RemoteCaptureView.self)
    }

    /// One photo to its signed URL (the same bounded PUT as release files).
    func uploadPhoto(_ data: Data, to target: RemotePhotoUploadTarget) async throws {
        try await upload(data, to: RemoteUploadTarget(path: target.photoId, url: target.url, contentType: "image/jpeg", expiresInSec: 1800))
    }

    // MARK: Object storage (signed URLs; no app credentials)

    func upload(_ data: Data, to target: RemoteUploadTarget) async throws {
        guard let u = URL(string: target.url), u.scheme == "https" else { throw StoreShelfAPIError.invalidResponse }
        var r = URLRequest(url: u)
        r.httpMethod = "PUT"
        r.timeoutInterval = 120
        r.setValue(target.contentType, forHTTPHeaderField: "Content-Type")
        do {
            let (_, response) = try await session.upload(for: r, from: data)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw StoreShelfAPIError.server(status: (response as? HTTPURLResponse)?.statusCode ?? -1, code: "UPLOAD_FAILED")
            }
        } catch let e as StoreShelfAPIError {
            throw e
        } catch {
            throw StoreShelfAPIError.transport
        }
    }

    func download(_ file: RemoteReleaseFile) async throws -> Data {
        guard let u = URL(string: file.url), u.scheme == "https" else { throw StoreShelfAPIError.invalidResponse }
        do {
            let (data, response) = try await session.data(from: u)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw StoreShelfAPIError.server(status: (response as? HTTPURLResponse)?.statusCode ?? -1, code: "DOWNLOAD_FAILED")
            }
            return data
        } catch let e as StoreShelfAPIError {
            throw e
        } catch {
            throw StoreShelfAPIError.transport
        }
    }
}
