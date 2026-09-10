import Foundation

/// Public discovery, owner visibility, reports, blocks, likes, comments, and audio against the Gonggi API host.
actor MobilePublicSpacesAPIClient {
    private let config: AppConfiguration
    private let session: URLSession

    init(config: AppConfiguration = .production, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    var apiBaseURL: URL { config.apiBaseURL }

    // MARK: - Owner visibility

    func getVisibility(accessToken: String, spaceId: String) async throws -> GonggiOwnerVisibilityState {
        let json = try await requestJSON(
            pathComponents: ["api", "gonggi", "spaces", spaceId, "visibility"],
            method: "GET",
            accessToken: accessToken,
            body: nil,
            fallbackError: "공개 설정을 불러오지 못했어요. 잠시 후 다시 시도해주세요."
        )
        guard let visibility = json["visibility"] as? [String: Any],
              let state = Self.parseVisibility(visibility)
        else {
            throw MobileAuthAPIError.invalidResponse
        }
        return state
    }

    func setVisibility(
        accessToken: String,
        spaceId: String,
        visibility: GonggiSpaceVisibility,
        commentsAllowed: Bool? = nil
    ) async throws -> GonggiOwnerVisibilityState {
        var body: [String: Any] = ["visibility": visibility.rawValue]
        if let commentsAllowed {
            body["commentsAllowed"] = commentsAllowed
        }
        let json = try await requestJSON(
            pathComponents: ["api", "gonggi", "spaces", spaceId, "visibility"],
            method: "PATCH",
            accessToken: accessToken,
            body: body,
            fallbackError: PublicSpacesPolicy.visibilitySaveFailedMessage
        )
        guard let row = json["visibility"] as? [String: Any],
              let state = Self.parseVisibility(row)
        else {
            throw MobileAuthAPIError.invalidResponse
        }
        return state
    }

    // MARK: - Public list / detail

    func listPublicSpaces(
        accessToken: String?,
        limit: Int = 20,
        cursor: String? = nil
    ) async throws -> PublicSpaceListPage {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 50)))),
        ]
        if let cursor, !cursor.isEmpty {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        let json = try await requestJSON(
            pathComponents: ["api", "gonggi", "public", "spaces"],
            method: "GET",
            accessToken: accessToken,
            body: nil,
            queryItems: items,
            fallbackError: "공개 공간을 불러오지 못했어요. 잠시 후 다시 시도해주세요."
        )
        let rows = json["spaces"] as? [[String: Any]] ?? []
        let spaces = rows.compactMap(Self.parseListItem)
        let next = json["nextCursor"] as? String
        return PublicSpaceListPage(spaces: spaces, nextCursor: next)
    }

    func getPublicSpace(accessToken: String?, slug: String) async throws -> PublicSpaceDetail {
        let json = try await requestJSON(
            pathComponents: ["api", "gonggi", "public", "spaces", slug],
            method: "GET",
            accessToken: accessToken,
            body: nil,
            fallbackError: "공개 공간을 불러오지 못했어요."
        )
        let root = (json["space"] as? [String: Any]) ?? json
        guard let detail = Self.parseDetail(root) else {
            throw MobileAuthAPIError.invalidResponse
        }
        return detail
    }

    /// Existing link-share metadata (UNLISTED navigation from public hotspot opt-in).
    func getShareSpace(token: String) async throws -> (panoramaUrl: String, title: String?) {
        let json = try await requestJSON(
            pathComponents: ["api", "gonggi", "share", token],
            method: "GET",
            accessToken: nil,
            body: nil,
            fallbackError: "공유 공간을 불러오지 못했어요."
        )
        let root = (json["space"] as? [String: Any]) ?? json
        guard let panoramaUrl = root["panoramaUrl"] as? String else {
            throw MobileAuthAPIError.invalidResponse
        }
        return (panoramaUrl, root["title"] as? String)
    }

    // MARK: - Likes

    func getLikes(accessToken: String?, slug: String) async throws -> PublicSpaceLikeState {
        let json = try await requestJSON(
            pathComponents: ["api", "gonggi", "public", "spaces", slug, "likes"],
            method: "GET",
            accessToken: accessToken,
            body: nil,
            fallbackError: "좋아요를 불러오지 못했어요."
        )
        return PublicSpaceLikeState(
            likeCount: Self.intValue(json["likeCount"]) ?? 0,
            isLiked: json["isLiked"] as? Bool ?? false
        )
    }

    func likeSpace(accessToken: String, slug: String) async throws -> PublicSpaceLikeState {
        let json = try await requestJSON(
            pathComponents: ["api", "gonggi", "public", "spaces", slug, "likes"],
            method: "POST",
            accessToken: accessToken,
            body: [:],
            fallbackError: "좋아요를 반영하지 못했어요. 잠시 후 다시 시도해주세요."
        )
        return PublicSpaceLikeState(
            likeCount: Self.intValue(json["likeCount"]) ?? 0,
            isLiked: json["isLiked"] as? Bool ?? true
        )
    }

    func unlikeSpace(accessToken: String, slug: String) async throws -> PublicSpaceLikeState {
        let json = try await requestJSON(
            pathComponents: ["api", "gonggi", "public", "spaces", slug, "likes"],
            method: "DELETE",
            accessToken: accessToken,
            body: nil,
            fallbackError: "좋아요를 반영하지 못했어요. 잠시 후 다시 시도해주세요."
        )
        return PublicSpaceLikeState(
            likeCount: Self.intValue(json["likeCount"]) ?? 0,
            isLiked: json["isLiked"] as? Bool ?? false
        )
    }

    // MARK: - Comments

    func listComments(
        accessToken: String?,
        slug: String,
        limit: Int = 30,
        cursor: String? = nil
    ) async throws -> PublicSpaceCommentsPage {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 50)))),
        ]
        if let cursor, !cursor.isEmpty {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        let json = try await requestJSON(
            pathComponents: ["api", "gonggi", "public", "spaces", slug, "comments"],
            method: "GET",
            accessToken: accessToken,
            body: nil,
            queryItems: items,
            fallbackError: "댓글을 불러오지 못했어요."
        )
        let rows = json["comments"] as? [[String: Any]] ?? []
        return PublicSpaceCommentsPage(
            comments: rows.compactMap(Self.parseComment),
            nextCursor: json["nextCursor"] as? String,
            commentsAllowed: json["commentsAllowed"] as? Bool ?? true,
            commentCount: Self.intValue(json["commentCount"]) ?? rows.count
        )
    }

    func createComment(accessToken: String, slug: String, body: String) async throws -> PublicSpaceComment {
        let json = try await requestJSON(
            pathComponents: ["api", "gonggi", "public", "spaces", slug, "comments"],
            method: "POST",
            accessToken: accessToken,
            body: ["body": body],
            fallbackError: "댓글을 등록하지 못했어요. 잠시 후 다시 시도해주세요."
        )
        let root = (json["comment"] as? [String: Any]) ?? json
        guard let comment = Self.parseComment(root) else {
            throw MobileAuthAPIError.invalidResponse
        }
        return comment
    }

    func updateComment(accessToken: String, commentId: String, body: String) async throws -> PublicSpaceComment {
        let json = try await requestJSON(
            pathComponents: ["api", "gonggi", "public", "comments", commentId],
            method: "PATCH",
            accessToken: accessToken,
            body: ["body": body],
            fallbackError: "댓글을 수정하지 못했어요."
        )
        let root = (json["comment"] as? [String: Any]) ?? json
        guard let comment = Self.parseComment(root) else {
            throw MobileAuthAPIError.invalidResponse
        }
        return comment
    }

    func hideComment(accessToken: String, commentId: String) async throws {
        _ = try await requestJSON(
            pathComponents: ["api", "gonggi", "public", "comments", commentId],
            method: "PATCH",
            accessToken: accessToken,
            body: ["action": "hide"],
            fallbackError: "댓글을 숨기지 못했어요."
        )
    }

    func deleteComment(accessToken: String, commentId: String) async throws {
        _ = try await requestJSON(
            pathComponents: ["api", "gonggi", "public", "comments", commentId],
            method: "DELETE",
            accessToken: accessToken,
            body: nil,
            fallbackError: "댓글을 삭제하지 못했어요."
        )
    }

    func reportComment(
        accessToken: String,
        commentId: String,
        reason: PublicCommentReportReason,
        description: String? = nil
    ) async throws -> String {
        var body: [String: Any] = [
            "commentId": commentId,
            "reason": reason.rawValue,
        ]
        if let description, !description.isEmpty {
            body["description"] = description
        }
        let json = try await requestJSON(
            pathComponents: ["api", "gonggi", "public", "comment-reports"],
            method: "POST",
            accessToken: accessToken,
            body: body,
            fallbackError: "신고를 접수하지 못했어요. 잠시 후 다시 시도해주세요."
        )
        return PublicSpacesAPIMessageSanitizer.safeMessage(
            json["message"] as? String,
            fallback: PublicSpacesPolicy.reportAcceptedMessage
        )
    }

    // MARK: - Reports / blocks

    func reportPublicSpace(
        accessToken: String,
        publicSlug: String,
        reason: PublicSpaceReportReason,
        description: String? = nil
    ) async throws -> String {
        var body: [String: Any] = [
            "publicSlug": publicSlug,
            "reason": reason.rawValue,
        ]
        if let description, !description.isEmpty {
            body["description"] = description
        }
        let json = try await requestJSON(
            pathComponents: ["api", "gonggi", "public", "reports"],
            method: "POST",
            accessToken: accessToken,
            body: body,
            fallbackError: "신고를 접수하지 못했어요. 잠시 후 다시 시도해주세요."
        )
        return PublicSpacesAPIMessageSanitizer.safeMessage(
            json["message"] as? String,
            fallback: PublicSpacesPolicy.reportAcceptedMessage
        )
    }

    func listBlocks(accessToken: String) async throws -> [PublicBlockedCreator] {
        let json = try await requestJSON(
            pathComponents: ["api", "gonggi", "public", "blocks"],
            method: "GET",
            accessToken: accessToken,
            body: nil,
            fallbackError: "차단 목록을 불러오지 못했어요."
        )
        let rows = json["blocks"] as? [[String: Any]] ?? []
        return rows.compactMap(Self.parseBlock)
    }

    func createBlock(accessToken: String, publisherBlockToken: String) async throws {
        _ = try await requestJSON(
            pathComponents: ["api", "gonggi", "public", "blocks"],
            method: "POST",
            accessToken: accessToken,
            body: ["publisherBlockToken": publisherBlockToken],
            fallbackError: "차단하지 못했어요. 잠시 후 다시 시도해주세요."
        )
    }

    func deleteBlock(accessToken: String, blockToken: String) async throws {
        _ = try await requestJSON(
            pathComponents: ["api", "gonggi", "public", "blocks"],
            method: "DELETE",
            accessToken: accessToken,
            body: ["blockToken": blockToken],
            fallbackError: "차단을 해제하지 못했어요."
        )
    }

    /// Download panorama bytes for public VR (cached under Application Support).
    func downloadPanorama(accessToken: String?, panoramaUrl: String, cacheKey: String) async throws -> URL {
        try await downloadMediaFile(
            accessToken: accessToken,
            remotePath: panoramaUrl,
            cacheKey: cacheKey,
            fileName: "latlong.jpg",
            validate: { SpaceLatLongStore.isValidLocalFile(at: $0.path) }
        )
    }

    /// Download PUBLIC space audio (proxy or absolute). Failure must not block panorama.
    func downloadPublicAudio(accessToken: String?, audioUrl: String, cacheKey: String) async throws -> URL {
        let ext: String
        let lower = audioUrl.lowercased()
        if lower.contains(".m4a") { ext = "m4a" }
        else if lower.contains(".mp3") { ext = "mp3" }
        else if lower.contains(".wav") { ext = "wav" }
        else if lower.contains(".aac") { ext = "aac" }
        else { ext = "m4a" }
        return try await downloadMediaFile(
            accessToken: accessToken,
            remotePath: audioUrl,
            cacheKey: cacheKey,
            fileName: "public-audio.\(ext)",
            validate: { url in
                (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { $0 > 0 } ?? false
            }
        )
    }

    /// Relative audio proxy path for a public slug.
    nonisolated static func publicAudioProxyPath(slug: String) -> String {
        "/api/gonggi/public/spaces/\(slug)/audio"
    }

    // MARK: - HTTP

    private func downloadMediaFile(
        accessToken: String?,
        remotePath: String,
        cacheKey: String,
        fileName: String,
        validate: (URL) -> Bool
    ) async throws -> URL {
        guard let remote = PublicSpacesPolicy.resolveMediaURL(
            relativeOrAbsolute: remotePath,
            apiBaseURL: config.apiBaseURL
        ) else {
            throw MobileAuthAPIError.invalidResponse
        }
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Gonggi", isDirectory: true)
        .appendingPathComponent("PublicSpaces", isDirectory: true)
        .appendingPathComponent(cacheKey.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(fileName)
        if validate(dest) {
            return dest
        }

        var request = URLRequest(url: remote)
        request.httpMethod = "GET"
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 120
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw MobileAuthAPIError.network
        }
        try data.write(to: dest, options: .atomic)
        guard validate(dest) else {
            try? FileManager.default.removeItem(at: dest)
            throw MobileAuthAPIError.invalidResponse
        }
        return dest
    }

    private func requestJSON(
        pathComponents: [String],
        method: String,
        accessToken: String?,
        body: [String: Any]?,
        queryItems: [URLQueryItem]? = nil,
        fallbackError: String
    ) async throws -> [String: Any] {
        var url = pathComponents.reduce(config.apiBaseURL) { $0.appendingPathComponent($1) }
        if let queryItems, !queryItems.isEmpty,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = queryItems
            if let built = components.url { url = built }
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        request.timeoutInterval = 30

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MobileAuthAPIError.network
        }
        guard let http = response as? HTTPURLResponse else { throw MobileAuthAPIError.network }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode), (json?["ok"] as? Bool) != false else {
            let raw = json?["message"] as? String
            throw MobileAuthAPIError.server(
                code: (json?["error"] as? String) ?? "ERROR",
                message: PublicSpacesAPIMessageSanitizer.safeMessage(raw, fallback: fallbackError),
                status: http.statusCode
            )
        }
        guard let json else { throw MobileAuthAPIError.invalidResponse }
        return json
    }

    // MARK: - Parsers

    nonisolated static func parseVisibility(_ row: [String: Any]) -> GonggiOwnerVisibilityState? {
        guard let raw = row["visibility"] as? String,
              let visibility = GonggiSpaceVisibility(rawValue: raw)
        else { return nil }
        let modRaw = row["moderationStatus"] as? String
        let moderation = modRaw.flatMap(GonggiModerationStatus.init(rawValue:))
        return GonggiOwnerVisibilityState(
            visibility: visibility,
            shareEnabled: row["shareEnabled"] as? Bool ?? false,
            shareToken: row["shareToken"] as? String,
            shareUrl: row["shareUrl"] as? String,
            publicSlug: row["publicSlug"] as? String,
            moderationStatus: moderation,
            moderationReason: row["moderationReason"] as? String,
            publishedAt: row["publishedAt"] as? String,
            publicUpdatedAt: row["publicUpdatedAt"] as? String,
            publicDisplayName: row["publicDisplayName"] as? String,
            ownerStatusMessage: row["ownerStatusMessage"] as? String,
            commentsAllowed: row["commentsAllowed"] as? Bool ?? true
        )
    }

    nonisolated static func parseListItem(_ row: [String: Any]) -> PublicSpaceListItem? {
        guard let publicSlug = row["publicSlug"] as? String,
              let title = row["title"] as? String,
              let publisher = row["publisherDisplayName"] as? String,
              let publishedAt = row["publishedAt"] as? String
        else { return nil }
        return PublicSpaceListItem(
            publicSlug: publicSlug,
            title: title,
            publisherDisplayName: publisher,
            publishedAt: publishedAt,
            thumbnailUrl: row["thumbnailUrl"] as? String,
            likeCount: intValue(row["likeCount"]) ?? 0,
            commentCount: intValue(row["commentCount"]) ?? 0
        )
    }

    nonisolated static func parseDetail(_ row: [String: Any]) -> PublicSpaceDetail? {
        guard let publicSlug = row["publicSlug"] as? String,
              let title = row["title"] as? String,
              let publisher = row["publisherDisplayName"] as? String,
              let panoramaUrl = row["panoramaUrl"] as? String,
              let blockToken = row["publisherBlockToken"] as? String
        else { return nil }
        let hotspots = (row["hotspots"] as? [[String: Any]] ?? []).compactMap(parseHotspot)
        let placement = row["placement"] as? [String: Any]
        let assets = (placement?["assets"] as? [[String: Any]] ?? []).compactMap(parsePlacementAsset)
        return PublicSpaceDetail(
            publicSlug: publicSlug,
            title: title,
            publisherDisplayName: publisher,
            publishedAt: row["publishedAt"] as? String,
            width: row["width"] as? Int,
            height: row["height"] as? Int,
            panoramaUrl: panoramaUrl,
            hotspots: hotspots,
            placementFloorY: placement?["floorY"] as? Double ?? 0,
            placementAssets: assets,
            publisherBlockToken: blockToken,
            supportUrl: (row["supportUrl"] as? String) ?? GonggiProductURLs.support.absoluteString,
            audio: parseAudio(row["audio"]),
            likeCount: intValue(row["likeCount"]) ?? 0,
            commentCount: intValue(row["commentCount"]) ?? 0,
            commentsAllowed: row["commentsAllowed"] as? Bool ?? true,
            isLiked: row["isLiked"] as? Bool ?? false,
            publisherAvatarUrl: row["publisherAvatarUrl"] as? String,
            shareUrl: row["shareUrl"] as? String
        )
    }

    nonisolated static func parseComment(_ row: [String: Any]) -> PublicSpaceComment? {
        guard let id = row["id"] as? String,
              let body = row["body"] as? String,
              let createdAt = row["createdAt"] as? String,
              let authorDisplayName = row["authorDisplayName"] as? String
        else { return nil }
        return PublicSpaceComment(
            id: id,
            body: body,
            createdAt: createdAt,
            editedAt: row["editedAt"] as? String,
            authorDisplayName: authorDisplayName,
            authorAvatarUrl: row["authorAvatarUrl"] as? String,
            authorBlockToken: row["authorBlockToken"] as? String,
            isMine: row["isMine"] as? Bool ?? false,
            canEdit: row["canEdit"] as? Bool ?? false,
            canDelete: row["canDelete"] as? Bool ?? false,
            canHide: row["canHide"] as? Bool ?? false
        )
    }

    nonisolated private static func parseAudio(_ any: Any?) -> PublicSpaceAudio? {
        guard let row = any as? [String: Any],
              let audioUrl = row["audioUrl"] as? String,
              !audioUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return PublicSpaceAudio(
            title: row["title"] as? String,
            durationSec: doubleValue(row["durationSec"]),
            mimeType: row["mimeType"] as? String,
            audioUrl: audioUrl
        )
    }

    nonisolated private static func parseHotspot(_ row: [String: Any]) -> PublicSpaceHotspot? {
        guard let id = row["id"] as? String else { return nil }
        return PublicSpaceHotspot(
            id: id,
            yawDeg: doubleValue(row["yawDeg"]) ?? 0,
            pitchDeg: doubleValue(row["pitchDeg"]) ?? 0,
            radius: doubleValue(row["radius"]) ?? 1,
            displayName: row["displayName"] as? String,
            labelSize: row["labelSize"] as? String,
            externalHostname: row["externalHostname"] as? String,
            externalUrl: row["externalUrl"] as? String,
            externalUrlDisabled: row["externalUrlDisabled"] as? Bool ?? false,
            canNavigate: row["canNavigate"] as? Bool ?? false,
            targetPublicSlug: row["targetPublicSlug"] as? String,
            targetShareToken: row["targetShareToken"] as? String,
            targetTitle: row["targetTitle"] as? String,
            targetThumbnailUrl: row["targetThumbnailUrl"] as? String
        )
    }

    nonisolated private static func parsePlacementAsset(_ row: [String: Any]) -> PublicSpacePlacementAsset? {
        guard let id = row["id"] as? String,
              let assetId = row["assetId"] as? String
        else { return nil }
        let pos = row["position"] as? [String: Any]
        return PublicSpacePlacementAsset(
            id: id,
            assetId: assetId,
            positionX: doubleValue(pos?["x"]) ?? 0,
            positionY: doubleValue(pos?["y"]) ?? 0,
            positionZ: doubleValue(pos?["z"]) ?? 0,
            rotationY: doubleValue(row["rotationY"]) ?? 0,
            uniformScale: doubleValue(row["uniformScale"]) ?? 1,
            modelUrl: row["modelUrl"] as? String,
            sortIndex: row["sortIndex"] as? Int ?? 0
        )
    }

    nonisolated static func parseBlock(_ row: [String: Any]) -> PublicBlockedCreator? {
        guard let id = row["id"] as? String,
              let blockToken = row["blockToken"] as? String,
              let displayName = row["displayName"] as? String,
              let createdAt = row["createdAt"] as? String
        else { return nil }
        return PublicBlockedCreator(
            id: id,
            blockToken: blockToken,
            displayName: displayName,
            createdAt: createdAt
        )
    }

    nonisolated private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        if let i = any as? Int { return Double(i) }
        return nil
    }

    nonisolated private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let d = any as? Double { return Int(d) }
        return nil
    }
}
