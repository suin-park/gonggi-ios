import Foundation

struct MobileAccountCreditsDTO: Equatable, Sendable {
    var balance: Int
    var entries: [MobileCreditLedgerEntry]
}

struct MobileCreditLedgerEntry: Equatable, Identifiable, Sendable {
    var id: String
    var delta: Int
    var balanceAfter: Int
    var kind: String
    var createdAt: String
}

struct MobileAccountUsageDTO: Equatable, Sendable {
    var spaces: Int
    var generatingSpaces: Int
    var sharedSpaces: Int
    var assets3d: Int
    var storageBytes: Int?
}

struct MobileSharedSpaceDTO: Equatable, Identifiable, Sendable {
    var id: String { spaceId }
    var spaceId: String
    var sessionId: String
    var title: String
    var sharedAt: String
    var shareUrl: String
}

actor MobileAccountAPIClient {
    private let config: AppConfiguration
    private let session: URLSession

    init(config: AppConfiguration = .production, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func updateProfile(accessToken: String, name: String) async throws -> MobileAuthUserDTO {
        let json = try await requestJSON(
            pathComponents: ["api", "mobile", "account", "profile"],
            method: "PATCH",
            accessToken: accessToken,
            body: ["name": name]
        )
        guard let user = json["user"] as? [String: Any] else {
            throw MobileAuthAPIError.invalidResponse
        }
        return MobileAuthAPIClient.parseUserPublic(user)
    }

    func changePassword(
        accessToken: String,
        currentPassword: String?,
        newPassword: String
    ) async throws {
        var body: [String: Any] = ["newPassword": newPassword]
        if let currentPassword { body["currentPassword"] = currentPassword }
        _ = try await requestJSON(
            pathComponents: ["api", "mobile", "account", "change-password"],
            method: "POST",
            accessToken: accessToken,
            body: body
        )
    }

    func fetchCredits(accessToken: String) async throws -> MobileAccountCreditsDTO {
        let json = try await requestJSON(
            pathComponents: ["api", "mobile", "account", "credits"],
            method: "GET",
            accessToken: accessToken,
            body: nil
        )
        guard let credits = json["credits"] as? [String: Any],
              let balance = credits["balance"] as? Int
        else { throw MobileAuthAPIError.invalidResponse }
        let raw = credits["entries"] as? [[String: Any]] ?? []
        let entries = raw.compactMap { row -> MobileCreditLedgerEntry? in
            guard let id = row["id"] as? String,
                  let delta = row["delta"] as? Int,
                  let balanceAfter = row["balanceAfter"] as? Int,
                  let kind = row["kind"] as? String,
                  let createdAt = row["createdAt"] as? String
            else { return nil }
            return MobileCreditLedgerEntry(
                id: id,
                delta: delta,
                balanceAfter: balanceAfter,
                kind: kind,
                createdAt: createdAt
            )
        }
        return MobileAccountCreditsDTO(balance: balance, entries: entries)
    }

    func fetchUsage(accessToken: String) async throws -> MobileAccountUsageDTO {
        let json = try await requestJSON(
            pathComponents: ["api", "mobile", "account", "usage"],
            method: "GET",
            accessToken: accessToken,
            body: nil
        )
        guard let usage = json["usage"] as? [String: Any] else {
            throw MobileAuthAPIError.invalidResponse
        }
        return MobileAccountUsageDTO(
            spaces: usage["spaces"] as? Int ?? 0,
            generatingSpaces: usage["generatingSpaces"] as? Int ?? 0,
            sharedSpaces: usage["sharedSpaces"] as? Int ?? 0,
            assets3d: usage["assets3d"] as? Int ?? 0,
            storageBytes: usage["storageBytes"] as? Int
        )
    }

    func fetchSharedSpaces(accessToken: String) async throws -> [MobileSharedSpaceDTO] {
        let json = try await requestJSON(
            pathComponents: ["api", "mobile", "account", "shared-spaces"],
            method: "GET",
            accessToken: accessToken,
            body: nil
        )
        let rows = json["spaces"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let spaceId = row["spaceId"] as? String,
                  let sessionId = row["sessionId"] as? String,
                  let title = row["title"] as? String,
                  let sharedAt = row["sharedAt"] as? String,
                  let shareUrl = row["shareUrl"] as? String
            else { return nil }
            return MobileSharedSpaceDTO(
                spaceId: spaceId,
                sessionId: sessionId,
                title: title,
                sharedAt: sharedAt,
                shareUrl: shareUrl
            )
        }
    }

    func deleteAccount(
        accessToken: String,
        currentPassword: String? = nil,
        appleIdentityToken: String? = nil,
        appleAuthorizationCode: String? = nil,
        googleIdToken: String? = nil
    ) async throws {
        var body: [String: Any] = [:]
        if let currentPassword { body["currentPassword"] = currentPassword }
        if let appleIdentityToken { body["appleIdentityToken"] = appleIdentityToken }
        if let appleAuthorizationCode { body["appleAuthorizationCode"] = appleAuthorizationCode }
        if let googleIdToken { body["googleIdToken"] = googleIdToken }
        _ = try await requestJSON(
            pathComponents: ["api", "mobile", "account", "delete"],
            method: "POST",
            accessToken: accessToken,
            body: body
        )
    }

    private func requestJSON(
        pathComponents: [String],
        method: String,
        accessToken: String,
        body: [String: Any]?
    ) async throws -> [String: Any] {
        let url = pathComponents.reduce(config.apiBaseURL) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
            throw MobileAuthAPIError.server(
                code: (json?["error"] as? String) ?? "ERROR",
                message: (json?["message"] as? String) ?? "요청에 실패했습니다.",
                status: http.statusCode
            )
        }
        guard let json else { throw MobileAuthAPIError.invalidResponse }
        return json
    }
}

extension MobileAuthAPIClient {
    /// Shared parser for account profile responses.
    nonisolated static func parseUserPublic(_ user: [String: Any]) -> MobileAuthUserDTO {
        let credits = user["credits"] as? [String: Any]
        let plan = user["plan"] as? [String: Any]
        let providerRows = user["providers"] as? [[String: Any]]
        let providerIds = providerRows?.compactMap { $0["id"] as? String }
        return MobileAuthUserDTO(
            id: user["id"] as? String ?? "",
            email: user["email"] as? String ?? "",
            name: user["name"] as? String ?? "",
            avatar: user["avatar"] as? String ?? user["avatarUrl"] as? String,
            provider: user["provider"] as? String ?? "",
            orgId: user["orgId"] as? String,
            creditsTotal: credits?["total"] as? Int ?? user["credits"] as? Int,
            emailVerified: user["emailVerified"] as? Bool,
            hasPassword: user["hasPassword"] as? Bool,
            canSetPassword: user["canSetPassword"] as? Bool,
            canChangePassword: user["canChangePassword"] as? Bool,
            providers: providerIds,
            planCode: plan?["code"] as? String,
            planLabel: plan?["label"] as? String,
            planPeriodEnd: plan?["periodEnd"] as? String
        )
    }
}
