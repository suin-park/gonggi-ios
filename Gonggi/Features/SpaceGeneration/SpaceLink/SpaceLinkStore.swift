import Foundation

enum SpaceLinkStoreError: Error, Equatable {
    case invalidResponse
    case server(status: Int, code: String?, message: String?)
    case tooManyLinks
    case targetNotReady
    case network
}

/// Remote SpaceLink API + Application Support cache (online authoritative).
actor SpaceLinkStore {
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

    func loadCached(spaceId: String) throws -> [SpaceLink] {
        let url = try cacheURL(spaceId: spaceId, createDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([SpaceLink].self, from: data)
            .filter(\.isNavigable)
            .prefix(SpaceLink.maxLinksPerSource)
            .map { $0 }
    }

    func saveCache(_ links: [SpaceLink], spaceId: String) throws {
        let url = try cacheURL(spaceId: spaceId, createDirectory: true)
        let navigable = Array(links.filter(\.isNavigable).prefix(SpaceLink.maxLinksPerSource))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(navigable).write(to: url, options: .atomic)
    }

    /// Online: fetch + cache. Offline: return cache.
    func loadLinks(spaceId: String) async -> [SpaceLink] {
        do {
            let remote = try await fetchRemote(spaceId: spaceId)
            try? saveCache(remote, spaceId: spaceId)
            return remote
        } catch {
            return (try? loadCached(spaceId: spaceId)) ?? []
        }
    }

    func fetchRemote(spaceId: String) async throws -> [SpaceLink] {
        var request = URLRequest(url: linksEndpoint(spaceId: spaceId))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        applyBearer(to: &request)

        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        let decoded = try JSONDecoder().decode(SpaceLinkListResponse.self, from: data)
        return decoded.links.map { $0.toModel() }.filter(\.isNavigable)
    }

    func createLinked(
        sourceSpaceId: String,
        targetSpaceId: String,
        yawDeg: Float,
        pitchDeg: Float,
        radius: Float,
        label: String?
    ) async throws -> SpaceLink {
        struct CreateBody: Encodable {
            var targetSpaceId: String
            var yawDeg: Float
            var pitchDeg: Float
            var radius: Float
            var label: String?
        }
        let body = CreateBody(
            targetSpaceId: targetSpaceId,
            yawDeg: yawDeg,
            pitchDeg: pitchDeg,
            radius: SpaceLink.clampRadius(radius),
            label: label.flatMap { t in
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : String(trimmed.prefix(64))
            }
        )
        var request = URLRequest(url: linksEndpoint(spaceId: sourceSpaceId))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(body)
        applyBearer(to: &request)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SpaceLinkStoreError.network
        }
        try validate(response, data: data)
        let decoded = try JSONDecoder().decode(SpaceLinkMutationResponse.self, from: data)
        guard let link = decoded.link?.toModel() else {
            throw SpaceLinkStoreError.invalidResponse
        }
        var cached = (try? loadCached(spaceId: sourceSpaceId)) ?? []
        cached.removeAll { $0.id == link.id }
        cached.append(link)
        try? saveCache(cached, spaceId: sourceSpaceId)
        return link
    }

    func patchLink(
        sourceSpaceId: String,
        linkId: String,
        yawDeg: Float?,
        pitchDeg: Float?,
        radius: Float?,
        label: String??
    ) async throws -> SpaceLink {
        struct PatchBody: Encodable {
            var yawDeg: Float?
            var pitchDeg: Float?
            var radius: Float?
            var label: String?
            var encodeLabelNull: Bool = false

            enum CodingKeys: String, CodingKey {
                case yawDeg, pitchDeg, radius, label
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encodeIfPresent(yawDeg, forKey: .yawDeg)
                try c.encodeIfPresent(pitchDeg, forKey: .pitchDeg)
                try c.encodeIfPresent(radius, forKey: .radius)
                if encodeLabelNull {
                    try c.encodeNil(forKey: .label)
                } else if let label {
                    try c.encode(label, forKey: .label)
                }
            }
        }

        var body = PatchBody(
            yawDeg: yawDeg,
            pitchDeg: pitchDeg,
            radius: radius.map { SpaceLink.clampRadius($0) },
            label: nil,
            encodeLabelNull: false
        )
        if let labelOpt = label {
            if let labelOpt {
                body.label = String(labelOpt.prefix(64))
            } else {
                body.encodeLabelNull = true
            }
        }

        var request = URLRequest(url: linkEndpoint(spaceId: sourceSpaceId, linkId: linkId))
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(body)
        applyBearer(to: &request)

        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        let decoded = try JSONDecoder().decode(SpaceLinkMutationResponse.self, from: data)
        guard let link = decoded.link?.toModel() else {
            throw SpaceLinkStoreError.invalidResponse
        }
        var cached = (try? loadCached(spaceId: sourceSpaceId)) ?? []
        if let idx = cached.firstIndex(where: { $0.id == link.id }) {
            cached[idx] = link
        } else {
            cached.append(link)
        }
        try? saveCache(cached, spaceId: sourceSpaceId)
        return link
    }

    func deleteLink(sourceSpaceId: String, linkId: String) async throws {
        var request = URLRequest(url: linkEndpoint(spaceId: sourceSpaceId, linkId: linkId))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        applyBearer(to: &request)

        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        var cached = (try? loadCached(spaceId: sourceSpaceId)) ?? []
        cached.removeAll { $0.id == linkId }
        try? saveCache(cached, spaceId: sourceSpaceId)
    }

    /// Build 78 — drop local link caches that reference a soft-deleted space (source or target).
    func purgeCachesInvolving(spaceId: String) {
        try? fileManager.removeItem(at: cacheURL(spaceId: spaceId, createDirectory: false))
        guard let dir = try? cacheURL(spaceId: "_", createDirectory: true).deletingLastPathComponent(),
              let files = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
              )
        else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  var links = try? decoder.decode([SpaceLink].self, from: data)
            else { continue }
            let before = links.count
            links.removeAll {
                $0.sourceSpaceId == spaceId
                    || $0.targetSpaceId == spaceId
                    || $0.targetSessionId == spaceId
            }
            guard links.count != before else { continue }
            if links.isEmpty {
                try? fileManager.removeItem(at: file)
            } else if let out = try? encoder.encode(links) {
                try? out.write(to: file, options: .atomic)
            }
        }
    }

    // MARK: - Private

    private func linksEndpoint(spaceId: String) -> URL {
        config.apiBaseURL
            .appendingPathComponent("api/gonggi/spaces")
            .appendingPathComponent(spaceId)
            .appendingPathComponent("links")
    }

    private func linkEndpoint(spaceId: String, linkId: String) -> URL {
        linksEndpoint(spaceId: spaceId).appendingPathComponent(linkId)
    }

    private func applyBearer(to request: inout URLRequest) {
        if let token = MobileAuthTokenStore.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SpaceLinkStoreError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            struct ErrBody: Decodable {
                var error: String?
                var message: String?
            }
            let body = try? JSONDecoder().decode(ErrBody.self, from: data)
            let code = body?.error
            let msg = body?.message
            if http.statusCode == 400, code == "TOO_MANY_LINKS" || msg?.contains("최대") == true {
                throw SpaceLinkStoreError.tooManyLinks
            }
            if http.statusCode == 400, code == "TARGET_NOT_READY" {
                throw SpaceLinkStoreError.targetNotReady
            }
            throw SpaceLinkStoreError.server(status: http.statusCode, code: code, message: msg)
        }
    }

    private func cacheURL(spaceId: String, createDirectory: Bool) throws -> URL {
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
        let directory = support.appendingPathComponent("gonggi-space-links", isDirectory: true)
        if createDirectory {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let safe = spaceId.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]"#,
            with: "_",
            options: .regularExpression
        )
        return directory.appendingPathComponent("\(safe).json")
    }
}
