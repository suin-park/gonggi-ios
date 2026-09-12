import Foundation

struct GonggiNotificationItem: Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var type: String
    var title: String
    var message: String?
    var link: String?
    var read: Bool
    var createdAt: String

    var typeLabelKo: String {
        switch type {
        case "GONGGI_SPACE_LIKE": return "좋아요"
        case "GONGGI_SPACE_COMMENT": return "댓글"
        case "GONGGI_ADMIN_ANNOUNCEMENT": return "공지"
        default: return "알림"
        }
    }

    var systemImage: String {
        switch type {
        case "GONGGI_SPACE_LIKE": return "heart.fill"
        case "GONGGI_SPACE_COMMENT": return "bubble.left.fill"
        case "GONGGI_ADMIN_ANNOUNCEMENT": return "megaphone.fill"
        default: return "bell.fill"
        }
    }
}

actor MobileNotificationsAPIClient {
    private let config: AppConfiguration
    private let session: URLSession

    init(config: AppConfiguration = .production, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func fetchList(
        accessToken: String,
        limit: Int = 30,
        cursor: String? = nil,
        unreadOnly: Bool = false
    ) async throws -> (items: [GonggiNotificationItem], unreadCount: Int, nextCursor: String?) {
        var components = URLComponents(
            url: config.apiBaseURL
                .appendingPathComponent("api")
                .appendingPathComponent("gonggi")
                .appendingPathComponent("notifications"),
            resolvingAgainstBaseURL: false
        )!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if unreadOnly { items.append(URLQueryItem(name: "unreadOnly", value: "1")) }
        if let cursor, !cursor.isEmpty {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = items
        guard let url = components.url else { throw MobileAuthAPIError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MobileAuthAPIError.network }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode), (json?["ok"] as? Bool) == true else {
            throw MobileAuthAPIError.server(
                code: (json?["errorCode"] as? String) ?? "ERROR",
                message: "알림을 불러오지 못했어요.",
                status: http.statusCode
            )
        }
        let rows = json?["notifications"] as? [[String: Any]] ?? []
        let parsed = rows.compactMap(Self.parseItem)
        let unread = json?["unreadCount"] as? Int ?? 0
        let next = json?["nextCursor"] as? String
        return (parsed, unread, next)
    }

    func fetchDetail(accessToken: String, id: String) async throws -> GonggiNotificationItem {
        let url = ["api", "gonggi", "notifications", id].reduce(config.apiBaseURL) {
            $0.appendingPathComponent($1)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MobileAuthAPIError.network }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode),
              (json?["ok"] as? Bool) == true,
              let row = json?["notification"] as? [String: Any],
              let item = Self.parseItem(row)
        else {
            throw MobileAuthAPIError.server(
                code: (json?["errorCode"] as? String) ?? "ERROR",
                message: "알림을 열 수 없어요.",
                status: http.statusCode
            )
        }
        return item
    }

    func markAllRead(accessToken: String) async throws {
        let url = ["api", "gonggi", "notifications", "read-all"].reduce(config.apiBaseURL) {
            $0.appendingPathComponent($1)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MobileAuthAPIError.network }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode), (json?["ok"] as? Bool) == true else {
            throw MobileAuthAPIError.server(
                code: (json?["errorCode"] as? String) ?? "ERROR",
                message: "읽음 처리에 실패했어요.",
                status: http.statusCode
            )
        }
    }

    func fetchUnreadCount(accessToken: String) async throws -> Int {
        let result = try await fetchList(accessToken: accessToken, limit: 1, unreadOnly: false)
        return result.unreadCount
    }

    nonisolated private static func parseItem(_ row: [String: Any]) -> GonggiNotificationItem? {
        guard let id = row["id"] as? String, !id.isEmpty,
              let type = row["type"] as? String,
              let title = row["title"] as? String
        else { return nil }
        return GonggiNotificationItem(
            id: id,
            type: type,
            title: title,
            message: row["message"] as? String,
            link: row["link"] as? String,
            read: (row["read"] as? Bool) ?? false,
            createdAt: row["createdAt"] as? String ?? ""
        )
    }
}
