import Foundation

enum VRPlacementStoreError: Error, Equatable {
    case invalidResponse
    case server(status: Int)
}

actor VRPlacementLayoutStore {
    private let config: AppConfiguration
    private let session: URLSession
    private let fileManager: FileManager
    private let applicationSupportURL: URL?

    init(
        config: AppConfiguration = .production,
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        applicationSupportURL: URL? = nil
    ) {
        self.config = config
        self.session = session
        self.fileManager = fileManager
        self.applicationSupportURL = applicationSupportURL
    }

    func loadLocal(sessionId: String) throws -> VRPlacementLayout? {
        let url = try localURL(sessionId: sessionId, createDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(VRPlacementLayout.self, from: data)
    }

    func saveLocal(_ draft: VRPlacementLayout, sessionId: String) throws {
        let url = try localURL(sessionId: sessionId, createDirectory: true)
        var normalized = draft
        normalized.enforceLimits()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(normalized).write(to: url, options: .atomic)
    }

    func fetchRemote(sessionId: String) async throws -> VRPlacementLayout {
        var request = URLRequest(url: endpoint(sessionId: sessionId))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        applyBearer(to: &request)

        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try decodeLayout(from: data)
    }

    @discardableResult
    func pushRemote(_ layout: VRPlacementLayout, sessionId: String) async throws -> VRPlacementLayout {
        var normalized = layout
        normalized.enforceLimits()

        var request = URLRequest(url: endpoint(sessionId: sessionId))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(LayoutRequest(layout: normalized))
        applyBearer(to: &request)

        let (data, response) = try await session.data(for: request)
        try validate(response)
        guard !data.isEmpty else { return normalized }
        return try decodeLayout(from: data)
    }

    /// Local draft wins for matching ids; remote-only entries are retained.
    func merge(
        local: VRPlacementLayout?,
        remote: VRPlacementLayout?
    ) -> VRPlacementLayout {
        guard let local else {
            var result = remote ?? VRPlacementLayout()
            result.enforceLimits()
            return result
        }
        guard let remote else {
            var result = local
            result.enforceLimits()
            return result
        }

        var localById: [String: VRPlacedAssetEntry] = [:]
        local.assets.forEach { localById[$0.id] = $0 }
        var merged = remote.assets.map { localById[$0.id] ?? $0 }
        let remoteIds = Set(remote.assets.map(\.id))
        merged.append(contentsOf: local.assets.filter { !remoteIds.contains($0.id) })
        merged.sort {
            if $0.sortIndex == $1.sortIndex { return $0.id < $1.id }
            return $0.sortIndex < $1.sortIndex
        }
        return VRPlacementLayout(
            version: local.version,
            frame: local.frame,
            floorY: local.floorY,
            assets: merged
        )
    }

    private func endpoint(sessionId: String) -> URL {
        config.apiBaseURL
            .appendingPathComponent("api/gonggi/spaces")
            .appendingPathComponent(sessionId)
            .appendingPathComponent("placement-layout")
    }

    private func applyBearer(to request: inout URLRequest) {
        if let token = MobileAuthTokenStore.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw VRPlacementStoreError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw VRPlacementStoreError.server(status: http.statusCode)
        }
    }

    private struct LayoutEnvelope: Decodable {
        var layout: VRPlacementLayout
    }

    private struct LayoutRequest: Encodable {
        var layout: VRPlacementLayout
    }

    private func decodeLayout(from data: Data) throws -> VRPlacementLayout {
        let decoder = JSONDecoder()
        if let layout = try? decoder.decode(VRPlacementLayout.self, from: data) {
            return layout
        }
        if let envelope = try? decoder.decode(LayoutEnvelope.self, from: data) {
            return envelope.layout
        }
        throw VRPlacementStoreError.invalidResponse
    }

    private func localURL(sessionId: String, createDirectory: Bool) throws -> URL {
        let support: URL
        if let applicationSupportURL {
            support = applicationSupportURL
        } else {
            support = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: createDirectory
            )
        }
        let directory = support.appendingPathComponent("gonggi-placements", isDirectory: true)
        if createDirectory {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let safeSessionId = sessionId.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]"#,
            with: "_",
            options: .regularExpression
        )
        return directory.appendingPathComponent("\(safeSessionId).json")
    }
}
