import Foundation
import UIKit

/// Client for `/api/gonggi/space-record/import` (still + equirect video).
actor SpaceImportAPIClient {
    private let config: AppConfiguration
    private let session: URLSession

    init(config: AppConfiguration = .production, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    struct StillImportResult: Equatable {
        let sessionId: String
        let jobId: String
        let imageUrl: String
        let width: Int
        let height: Int
        let latestRevisionId: String?
    }

    struct VideoPresignResult: Equatable {
        let sessionId: String
        let videoKey: String
        let uploadUrl: URL
        let contentType: String
    }

    struct VideoImportResult: Equatable {
        let sessionId: String
        let jobId: String
        let imageUrl: String
        let videoUrl: String
        let width: Int
        let height: Int
        let latestRevisionId: String?
    }

    enum ImportError: Error {
        case notAuthenticated
        case invalidResponse
        case server(code: String, message: String?)
        case network
    }

    func importStill(
        jpegData: Data,
        title: String?,
        sessionId: String? = nil
    ) async throws -> StillImportResult {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        func appendFile(_ name: String, filename: String, mime: String, data: Data) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append(
                "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
                    .data(using: .utf8)!
            )
            body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }

        if let sessionId, !sessionId.isEmpty {
            appendField("sessionId", sessionId)
        }
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendField("title", title.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        appendField("installationId", GonggiInstallation.id)
        appendFile("latlong", filename: "latlong.jpg", mime: "image/jpeg", data: jpegData)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let url = config.apiBaseURL.appendingPathComponent("api/gonggi/space-record/import")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120
        if let token = MobileAuthTokenStore.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImportError.network }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.invalidResponse
        }
        if http.statusCode == 401 {
            throw ImportError.notAuthenticated
        }
        guard (200..<300).contains(http.statusCode), json["ok"] as? Bool == true else {
            throw ImportError.server(
                code: (json["errorCode"] as? String) ?? "import_failed",
                message: json["message"] as? String
            )
        }
        guard
            let sid = json["sessionId"] as? String,
            let jid = json["jobId"] as? String,
            let result = json["result"] as? [String: Any],
            let imageUrl = result["imageUrl"] as? String
        else {
            throw ImportError.invalidResponse
        }
        return StillImportResult(
            sessionId: sid,
            jobId: jid,
            imageUrl: imageUrl,
            width: result["width"] as? Int ?? 0,
            height: result["height"] as? Int ?? 0,
            latestRevisionId: json["latestRevisionId"] as? String
        )
    }

    func presignVideo(
        contentType: String,
        byteSize: Int,
        sessionId: String? = nil
    ) async throws -> VideoPresignResult {
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            throw ImportError.notAuthenticated
        }
        let url = config.apiBaseURL.appendingPathComponent("api/gonggi/space-record/import/video/presign")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [
            "contentType": contentType,
            "byteSize": byteSize,
        ]
        if let sessionId, !sessionId.isEmpty {
            body["sessionId"] = sessionId
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImportError.network }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode), json["ok"] as? Bool == true else {
            throw ImportError.server(
                code: (json["errorCode"] as? String) ?? "presign_failed",
                message: json["message"] as? String
            )
        }
        guard
            let sid = json["sessionId"] as? String,
            let key = json["videoKey"] as? String,
            let upload = json["uploadUrl"] as? String,
            let uploadURL = URL(string: upload),
            let ct = json["contentType"] as? String
        else {
            throw ImportError.invalidResponse
        }
        return VideoPresignResult(
            sessionId: sid,
            videoKey: key,
            uploadUrl: uploadURL,
            contentType: ct
        )
    }

    func uploadVideo(to uploadUrl: URL, fileURL: URL, contentType: String) async throws {
        var request = URLRequest(url: uploadUrl)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        _ = data
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ImportError.network
        }
    }

    func completeVideoImport(
        sessionId: String,
        videoKey: String,
        contentType: String,
        posterJPEG: Data,
        title: String?
    ) async throws -> VideoImportResult {
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            throw ImportError.notAuthenticated
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField("sessionId", sessionId)
        appendField("videoKey", videoKey)
        appendField("contentType", contentType)
        appendField("installationId", GonggiInstallation.id)
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendField("title", title.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"poster\"; filename=\"poster.jpg\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(posterJPEG)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let url = config.apiBaseURL.appendingPathComponent(
            "api/gonggi/space-record/import/video/complete"
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImportError.network }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode), json["ok"] as? Bool == true else {
            throw ImportError.server(
                code: (json["errorCode"] as? String) ?? "import_failed",
                message: json["message"] as? String
            )
        }
        guard
            let sid = json["sessionId"] as? String,
            let jid = json["jobId"] as? String,
            let result = json["result"] as? [String: Any],
            let imageUrl = result["imageUrl"] as? String,
            let videoUrl = result["videoUrl"] as? String
        else {
            throw ImportError.invalidResponse
        }
        return VideoImportResult(
            sessionId: sid,
            jobId: jid,
            imageUrl: imageUrl,
            videoUrl: videoUrl,
            width: result["width"] as? Int ?? 0,
            height: result["height"] as? Int ?? 0,
            latestRevisionId: json["latestRevisionId"] as? String
        )
    }
}

enum SpaceImportMediaValidator {
    static func validateStillImage(_ image: UIImage) -> (jpeg: Data, width: Int, height: Int)? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width
        let h = cg.height
        guard SpaceGenerationCoordinator.isValidLatLongSize(width: w, height: h)
            || (w > 0 && h > 0 && w == h * 2 && w >= 1024 && w <= 8192)
        else { return nil }
        guard let data = image.jpegData(compressionQuality: 0.92) else { return nil }
        return (data, w, h)
    }

    static func userMessage(for error: SpaceImportAPIClient.ImportError) -> String {
        switch error {
        case .notAuthenticated:
            return "로그인 후 가져올 수 있어요"
        case .invalidResponse, .network:
            return "가져오기에 실패했어요. 잠시 후 다시 시도해 주세요"
        case .server(_, let message):
            if let message, !message.isEmpty { return message }
            return "가져오기에 실패했어요"
        }
    }
}
