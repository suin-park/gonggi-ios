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
        imageFiles: [(direction: String, fileURL: URL)],
        captureMetadataJSON: String?
    ) async throws -> SpaceRecordCreateResponse {
        let mode = GonggiSpaceRecordAIMode.createRequestMode
        let appBuild = GonggiSpaceRecordAIMode.currentAppBuildNumber
        let prepared = try SpaceRecordUploadPreparer.prepareUploadFiles(
            imageFiles,
            sessionId: sessionId,
            captureMetadataJSON: captureMetadataJSON,
            mode: mode,
            clientAppBuild: appBuild.isEmpty ? nil : appBuild
        )
        return try await postMultipart(
            path: "/api/gonggi/space-record/create",
            sessionId: sessionId,
            imageFiles: prepared.files,
            captureMetadataJSON: captureMetadataJSON
        )
    }

    func regenerate(
        sessionId: String,
        imageFiles: [(direction: String, fileURL: URL)],
        captureMetadataJSON: String?
    ) async throws -> SpaceRecordCreateResponse {
        let mode = GonggiSpaceRecordAIMode.createRequestMode
        let appBuild = GonggiSpaceRecordAIMode.currentAppBuildNumber
        let prepared = try SpaceRecordUploadPreparer.prepareUploadFiles(
            imageFiles,
            sessionId: sessionId,
            captureMetadataJSON: captureMetadataJSON,
            mode: mode,
            clientAppBuild: appBuild.isEmpty ? nil : appBuild
        )
        return try await postMultipart(
            path: "/api/gonggi/space-record/regenerate",
            sessionId: sessionId,
            imageFiles: prepared.files,
            captureMetadataJSON: captureMetadataJSON
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
        if let token = MobileAuthTokenStore.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SpaceRecordClientError.network }
        guard (200..<300).contains(http.statusCode) else {
            throw SpaceRecordClientError.server("status \(http.statusCode)")
        }

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
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SpaceRecordClientError.network
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    // MARK: - Selective repair

    func createRepair(
        sessionId: String,
        baseRevisionId: String,
        targetYawDeg: Double,
        targetPitchDeg: Double,
        radiusYawDeg: Double,
        radiusPitchDeg: Double,
        repairMode: String,
        repairImageURL: URL,
        captureMetadataJSON: String,
        capturedYawDeg: Double,
        capturedElevationDeg: Double
    ) async throws -> SpaceRepairCreateResponse {
        let endpoint = config.apiBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/api/gonggi/space/repair"
        guard let requestURL = URL(string: endpoint) else { throw SpaceRecordClientError.invalidResponse }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120
        if let token = MobileAuthTokenStore.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField(name: "sessionId", value: sessionId)
        appendField(name: "baseRevisionId", value: baseRevisionId)
        appendField(name: "targetYawDeg", value: String(targetYawDeg))
        appendField(name: "targetPitchDeg", value: String(targetPitchDeg))
        appendField(name: "radiusYawDeg", value: String(radiusYawDeg))
        appendField(name: "radiusPitchDeg", value: String(radiusPitchDeg))
        appendField(name: "repairMode", value: repairMode)
        appendField(name: "compareModes", value: "0")
        appendField(name: "capturedYawDeg", value: String(capturedYawDeg))
        appendField(name: "capturedElevationDeg", value: String(capturedElevationDeg))
        appendField(name: "captureMetadata", value: captureMetadataJSON)

        let data = try Data(contentsOf: repairImageURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"repairImage\"; filename=\"repair.jpg\"\r\n".data(using: .utf8)!
        )
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (respData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SpaceRecordClientError.network }
        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
            throw SpaceRecordClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode), (json["ok"] as? Bool) == true,
              let repairJobId = json["repairJobId"] as? String,
              let revisionId = json["revisionId"] as? String,
              let status = json["status"] as? String
        else {
            let code = json["errorCode"] as? String ?? "server_\(http.statusCode)"
            throw SpaceRecordClientError.server(code)
        }
        return SpaceRepairCreateResponse(repairJobId: repairJobId, revisionId: revisionId, status: status)
    }

    func fetchRepairStatus(sessionId: String, repairJobId: String) async throws -> SpaceRepairStatusResponse {
        var components = URLComponents(
            url: config.apiBaseURL.appendingPathComponent("api/gonggi/space/repair/status"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "sessionId", value: sessionId),
            URLQueryItem(name: "repairJobId", value: repairJobId),
        ]
        guard let url = components.url else { throw SpaceRecordClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = MobileAuthTokenStore.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
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
        return SpaceRepairStatusResponse(
            status: status,
            revisionId: json["revisionId"] as? String,
            imageUrl: imageUrl,
            width: width,
            height: height,
            errorCode: json["errorCode"] as? String
        )
    }

    private func postMultipart(
        path: String,
        sessionId: String,
        imageFiles: [(direction: String, fileURL: URL)],
        captureMetadataJSON: String?
    ) async throws -> SpaceRecordCreateResponse {
        let endpoint = config.apiBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + path
        guard let requestURL = URL(string: endpoint) else { throw SpaceRecordClientError.invalidResponse }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 180
        if let token = MobileAuthTokenStore.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField(name: "sessionId", value: sessionId)
        appendField(name: "installationId", value: GonggiInstallation.id)
        // Build 61 TestFlight only: explicit H12 scaffold opt-in. Omitted → backend default `direct`.
        if let mode = GonggiSpaceRecordAIMode.createRequestMode {
            appendField(name: "mode", value: mode)
        }
        let appBuild = GonggiSpaceRecordAIMode.currentAppBuildNumber
        if !appBuild.isEmpty {
            appendField(name: "clientAppBuild", value: appBuild)
        }
        if let captureMetadataJSON, !captureMetadataJSON.isEmpty {
            appendField(name: "captureMetadata", value: captureMetadataJSON)
        }

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
        SpaceRecordUploadLog.multipartBodyBytes(body.count, sessionId: sessionId)
        // Final hard-cap: never send oversize body to Vercel edge.
        if body.count > SpaceRecordUploadPreparer.hardCeilingMultipartBytes {
            throw SpaceRecordClientError.payloadTooLargeLocal
        }
        request.httpBody = body
        request.httpMethod = "POST"

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SpaceRecordClientError.network }

        if http.statusCode == 413 {
            throw SpaceRecordClientError.server("payload_too_large")
        }

        let httpOK = (200..<300).contains(http.statusCode)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpaceRecordClientError.invalidResponse
        }
        if !httpOK || (json["ok"] as? Bool) == false {
            let code = json["errorCode"] as? String ?? "server_\(http.statusCode)"
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
