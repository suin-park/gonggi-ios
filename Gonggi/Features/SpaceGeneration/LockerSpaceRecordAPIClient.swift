import Foundation

/// Production client → 3D Locker `/api/gonggi/space-record/*`
actor LockerSpaceRecordAPIClient: SpaceRecordAPIClienting {
    private let config: AppConfiguration
    private let session: URLSession

    init(config: AppConfiguration = .production, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func create(
        sessionId: String,
        imageFiles: [(direction: String, fileURL: URL)]
    ) async throws -> SpaceRecordCreateResponse {
        try await postMultipart(
            path: "/api/gonggi/space-record/create",
            sessionId: sessionId,
            imageFiles: imageFiles
        )
    }

    func regenerate(
        sessionId: String,
        imageFiles: [(direction: String, fileURL: URL)]
    ) async throws -> SpaceRecordCreateResponse {
        try await postMultipart(
            path: "/api/gonggi/space-record/regenerate",
            sessionId: sessionId,
            imageFiles: imageFiles
        )
    }

    func fetchStatus(jobId: String) async throws -> SpaceRecordStatusResponse {
        var components = URLComponents(
            url: config.apiBaseURL.appendingPathComponent("api/gonggi/space-record/status"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "id", value: jobId)]
        guard let url = components.url else { throw SpaceRecordClientError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SpaceRecordClientError.network }
        guard http.statusCode == 200 else { throw SpaceRecordClientError.server("status \(http.statusCode)") }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = json["ok"] as? Bool, ok,
              let status = json["status"] as? String
        else {
            throw SpaceRecordClientError.invalidResponse
        }

        var imageUrl: String?
        var width: Int?
        var height: Int?
        if let result = json["result"] as? [String: Any] {
            imageUrl = result["imageUrl"] as? String
            width = result["width"] as? Int
            height = result["height"] as? Int
        }
        return SpaceRecordStatusResponse(
            status: status,
            imageUrl: imageUrl,
            width: width,
            height: height,
            errorCode: json["errorCode"] as? String
        )
    }

    func downloadImage(from url: URL, to destination: URL) async throws {
        let (tempURL, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SpaceRecordClientError.network
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    private func postMultipart(
        path: String,
        sessionId: String,
        imageFiles: [(direction: String, fileURL: URL)]
    ) async throws -> SpaceRecordCreateResponse {
        let endpoint = config.apiBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + path
        guard let requestURL = URL(string: endpoint) else { throw SpaceRecordClientError.invalidResponse }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120

        var body = Data()
        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField(name: "sessionId", value: sessionId)

        for item in imageFiles {
            let data = try Data(contentsOf: item.fileURL)
            guard !data.isEmpty else { throw SpaceRecordClientError.captureIncomplete }
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append(
                "Content-Disposition: form-data; name=\"\(item.direction)\"; filename=\"\(item.direction).jpg\"\r\n"
                    .data(using: .utf8)!
            )
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SpaceRecordClientError.network }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpaceRecordClientError.invalidResponse
        }
        if http.statusCode >= 400 || (json["ok"] as? Bool) == false {
            let code = json["errorCode"] as? String ?? "server"
            if code == "capture_incomplete" { throw SpaceRecordClientError.captureIncomplete }
            throw SpaceRecordClientError.server(code)
        }
        guard let jobId = json["jobId"] as? String,
              let sid = json["sessionId"] as? String,
              let status = json["status"] as? String
        else {
            throw SpaceRecordClientError.invalidResponse
        }
        return SpaceRecordCreateResponse(sessionId: sid, jobId: jobId, status: status)
    }
}
