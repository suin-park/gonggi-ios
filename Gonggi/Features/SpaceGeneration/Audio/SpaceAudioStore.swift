import Foundation

/// Thin actor for Build 80 space audio HTTP + R2 PUT.
actor SpaceAudioStore {
    static let shared = SpaceAudioStore()

    private let config: AppConfiguration
    private let session: URLSession

    init(config: AppConfiguration = .production, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func fetchAudio(spaceId: String) async throws -> SpaceAudioMetadata {
        let data = try await authorizedJSON(
            method: "GET",
            pathComponents: ["api", "gonggi", "spaces", spaceId, "audio"]
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpaceAudioAPIError.invalidResponse
        }
        if let audio = json["audio"] as? [String: Any] {
            return SpaceAudioMetadata.fromAudioObject(audio)
        }
        // Some backends return fields at top level.
        if json["audioURL"] != nil || json["ok"] as? Bool == true {
            return SpaceAudioMetadata.fromCatalogRow(json)
        }
        throw SpaceAudioAPIError.invalidResponse
    }

    func fetchAudioURL(spaceId: String) async throws -> URL? {
        let meta = try await fetchAudio(spaceId: spaceId)
        guard let raw = meta.audioURL, let url = URL(string: raw) else { return nil }
        return url
    }

    func presign(
        spaceId: String,
        contentType: String,
        fileName: String,
        byteSize: Int,
        durationSec: Double?,
        source: SpaceAudioSource
    ) async throws -> SpaceAudioPresignResponse {
        var body: [String: Any] = [
            "action": "presign",
            "contentType": contentType,
            "fileName": fileName,
            "byteSize": byteSize,
            "source": source.rawValue,
        ]
        if let durationSec { body["durationSec"] = durationSec }
        let data = try await authorizedJSON(
            method: "POST",
            pathComponents: ["api", "gonggi", "spaces", spaceId, "audio"],
            body: body
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uploadUrl = json["uploadUrl"] as? String,
              let key = json["key"] as? String
        else {
            throw SpaceAudioAPIError.invalidResponse
        }
        let ct = (json["contentType"] as? String) ?? contentType
        return SpaceAudioPresignResponse(uploadUrl: uploadUrl, key: key, contentType: ct)
    }

    func putBinary(uploadUrl: String, data: Data, contentType: String) async throws {
        guard let url = URL(string: uploadUrl) else { throw SpaceAudioAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = 120
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SpaceAudioAPIError.network }
        guard (200..<300).contains(http.statusCode) else {
            throw SpaceAudioAPIError.generic
        }
    }

    func complete(
        spaceId: String,
        key: String,
        contentType: String,
        fileName: String,
        byteSize: Int,
        durationSec: Double?,
        source: SpaceAudioSource
    ) async throws -> SpaceAudioMetadata {
        var body: [String: Any] = [
            "action": "complete",
            "key": key,
            "contentType": contentType,
            "fileName": fileName,
            "byteSize": byteSize,
            "source": source.rawValue,
        ]
        if let durationSec { body["durationSec"] = durationSec }
        let data = try await authorizedJSON(
            method: "POST",
            pathComponents: ["api", "gonggi", "spaces", spaceId, "audio"],
            body: body
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpaceAudioAPIError.invalidResponse
        }
        if let audio = json["audio"] as? [String: Any] {
            return SpaceAudioMetadata.fromAudioObject(audio)
        }
        return SpaceAudioMetadata.fromCatalogRow(json)
    }

    func deleteAudio(spaceId: String) async throws {
        _ = try await authorizedJSON(
            method: "DELETE",
            pathComponents: ["api", "gonggi", "spaces", spaceId, "audio"]
        )
    }

    /// Presign → PUT → complete. Validates size/type first.
    func uploadFile(
        spaceId: String,
        fileURL: URL,
        source: SpaceAudioSource,
        durationSec: Double? = nil
    ) async throws -> SpaceAudioMetadata {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        let byteSize = values.fileSize ?? 0
        let fileName = fileURL.lastPathComponent
        let contentType = SpaceAudioPolicy.contentType(forFileName: fileName)
        guard SpaceAudioPolicy.isAllowed(fileName: fileName, byteSize: byteSize, contentType: contentType) else {
            if byteSize > SpaceAudioPolicy.maxByteSize {
                throw SpaceAudioAPIError.fileTooLarge
            }
            throw SpaceAudioAPIError.unsupportedType
        }
        let data = try Data(contentsOf: fileURL)
        let presign = try await self.presign(
            spaceId: spaceId,
            contentType: contentType,
            fileName: fileName,
            byteSize: byteSize,
            durationSec: durationSec,
            source: source
        )
        try await putBinary(uploadUrl: presign.uploadUrl, data: data, contentType: presign.contentType)
        return try await complete(
            spaceId: spaceId,
            key: presign.key,
            contentType: presign.contentType,
            fileName: fileName,
            byteSize: byteSize,
            durationSec: durationSec,
            source: source
        )
    }

    private func authorizedJSON(
        method: String,
        pathComponents: [String],
        body: [String: Any]? = nil
    ) async throws -> Data {
        guard let token = MobileAuthTokenStore.shared.getAccessToken(), !token.isEmpty else {
            throw SpaceAudioAPIError.missingToken
        }
        let url = pathComponents.reduce(config.apiBaseURL) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 45
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SpaceAudioAPIError.network
        }
        guard let http = response as? HTTPURLResponse else { throw SpaceAudioAPIError.network }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw SpaceAudioAPIError.unauthorized
        }
        if method == "DELETE", (200..<300).contains(http.statusCode) {
            return data
        }
        guard (200..<300).contains(http.statusCode) else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = json["error"] as? String {
                if code.lowercased().contains("large") || code == "payload_too_large" {
                    throw SpaceAudioAPIError.fileTooLarge
                }
                if code.lowercased().contains("type") || code == "unsupported_type" {
                    throw SpaceAudioAPIError.unsupportedType
                }
            }
            throw SpaceAudioAPIError.generic
        }
        return data
    }
}
