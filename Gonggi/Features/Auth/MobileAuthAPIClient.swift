import Foundation
import UIKit

struct MobileAuthUserDTO: Equatable, Sendable {
    var id: String
    var email: String
    var name: String
    var avatar: String?
    var provider: String
    var orgId: String?
    var creditsTotal: Int?

    var shell: AuthUserShell {
        AuthUserShell(
            displayName: name.isEmpty ? "공기 사용자" : name,
            email: email.isEmpty ? "—" : email,
            photoSystemImage: "person.fill"
        )
    }
}

struct MobileAuthTokens: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var accessExpiresAt: String?
    var sessionId: String?
    var user: MobileAuthUserDTO?
}

enum MobileAuthAPIError: Error, Equatable {
    case invalidResponse
    case network
    case server(code: String, message: String, status: Int)
}

actor MobileAuthAPIClient {
    private let config: AppConfiguration
    private let session: URLSession

    init(config: AppConfiguration = .production, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func emailLogin(email: String, password: String) async throws -> MobileAuthTokens {
        try await postJSON(
            path: "api/auth/mobile/email/login",
            body: [
                "email": email,
                "password": password,
                "deviceId": GonggiInstallation.id,
                "deviceName": "iOS",
            ]
        )
    }

    func googleLogin(idToken: String) async throws -> MobileAuthTokens {
        try await postJSON(
            path: "api/auth/mobile/google",
            body: [
                "idToken": idToken,
                "deviceId": GonggiInstallation.id,
                "deviceName": "iOS",
            ]
        )
    }

    func appleLogin(
        identityToken: String,
        nonce: String?,
        fullName: String?,
        email: String?
    ) async throws -> MobileAuthTokens {
        var body: [String: Any] = [
            "identityToken": identityToken,
            "deviceId": GonggiInstallation.id,
            "deviceName": "iOS",
        ]
        if let nonce { body["nonce"] = nonce }
        if let fullName, !fullName.isEmpty { body["fullName"] = fullName }
        if let email, !email.isEmpty { body["email"] = email }
        return try await postJSON(path: "api/auth/mobile/apple", body: body)
    }

    func refresh(refreshToken: String) async throws -> MobileAuthTokens {
        try await postJSON(path: "api/auth/mobile/refresh", body: ["refreshToken": refreshToken])
    }

    func logout(accessToken: String?, refreshToken: String?, sessionId: String?) async {
        var request = URLRequest(url: config.apiBaseURL.appendingPathComponent("api/auth/mobile/logout"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: String] = [:]
        if let refreshToken { body["refreshToken"] = refreshToken }
        if let sessionId { body["sessionId"] = sessionId }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15
        _ = try? await session.data(for: request)
    }

    func fetchMe(accessToken: String) async throws -> MobileAuthUserDTO {
        var request = URLRequest(url: config.apiBaseURL.appendingPathComponent("api/auth/me"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MobileAuthAPIError.network }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = json["ok"] as? Bool, ok,
              let user = json["user"] as? [String: Any]
        else {
            throw MobileAuthAPIError.server(
                code: "AUTH_EXPIRED",
                message: "세션이 만료되었습니다.",
                status: http.statusCode
            )
        }
        return parseUser(user)
    }

    struct ClaimInstallationResult: Sendable {
        var claimed: Int
        var alreadyOwned: Int
        var conflicts: Int
        var sessionIds: [String]
    }

    @discardableResult
    func claimInstallation(accessToken: String, sessionIds: [String]) async throws -> ClaimInstallationResult {
        var request = URLRequest(
            url: config.apiBaseURL.appendingPathComponent("api/gonggi/migrate/claim-installation")
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "installationId": GonggiInstallation.id,
            "sessionIds": sessionIds,
        ])
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw MobileAuthAPIError.network
        }
        let ids = (json["sessionIds"] as? [String]) ?? []
        return ClaimInstallationResult(
            claimed: json["claimed"] as? Int ?? 0,
            alreadyOwned: json["alreadyOwned"] as? Int ?? 0,
            conflicts: json["conflicts"] as? Int ?? 0,
            sessionIds: ids
        )
    }

    func listSpaces(accessToken: String) async throws -> [[String: Any]] {
        var request = URLRequest(url: config.apiBaseURL.appendingPathComponent("api/gonggi/spaces"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spaces = json["spaces"] as? [[String: Any]]
        else {
            throw MobileAuthAPIError.invalidResponse
        }
        return spaces
    }

    func patchSpace(
        accessToken: String,
        spaceId: String,
        body: [String: Any]
    ) async throws -> [String: Any] {
        var request = URLRequest(
            url: config.apiBaseURL
                .appendingPathComponent("api/gonggi/spaces")
                .appendingPathComponent(spaceId)
        )
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MobileAuthAPIError.network
        }
        guard let http = response as? HTTPURLResponse else {
            throw MobileAuthAPIError.network
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            let fallback: String
            switch http.statusCode {
            case 400: fallback = "입력한 공간 정보를 확인해주세요."
            case 404: fallback = "공간을 찾을 수 없어요."
            default: fallback = "공간 정보를 저장하지 못했어요."
            }
            throw MobileAuthAPIError.server(
                code: (json?["error"] as? String) ?? "ERROR",
                message: (json?["message"] as? String) ?? fallback,
                status: http.statusCode
            )
        }
        guard let json else { throw MobileAuthAPIError.invalidResponse }
        if let space = json["space"] as? [String: Any] {
            return space
        }
        return json
    }

    struct SpaceShareState: Equatable, Sendable {
        var shareEnabled: Bool
        var shareToken: String?
        var shareUrl: String?
    }

    /// GET /api/gonggi/spaces/:id/share — owner link-share state.
    func getSpaceShare(accessToken: String, spaceId: String) async throws -> SpaceShareState {
        var request = URLRequest(
            url: config.apiBaseURL
                .appendingPathComponent("api/gonggi/spaces")
                .appendingPathComponent(spaceId)
                .appendingPathComponent("share")
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MobileAuthAPIError.network }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode),
              let share = json?["share"] as? [String: Any]
        else {
            throw MobileAuthAPIError.server(
                code: (json?["error"] as? String) ?? "ERROR",
                message: (json?["message"] as? String) ?? "공유 설정을 불러오지 못했어요.",
                status: http.statusCode
            )
        }
        return SpaceShareState(
            shareEnabled: share["shareEnabled"] as? Bool ?? false,
            shareToken: share["shareToken"] as? String,
            shareUrl: share["shareUrl"] as? String
        )
    }

    /// PATCH /api/gonggi/spaces/:id/share — owner enable/disable link share.
    func setSpaceShare(accessToken: String, spaceId: String, enabled: Bool) async throws -> SpaceShareState {
        var request = URLRequest(
            url: config.apiBaseURL
                .appendingPathComponent("api/gonggi/spaces")
                .appendingPathComponent(spaceId)
                .appendingPathComponent("share")
        )
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["enabled": enabled])
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MobileAuthAPIError.network }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode),
              let share = json?["share"] as? [String: Any]
        else {
            throw MobileAuthAPIError.server(
                code: (json?["error"] as? String) ?? "ERROR",
                message: (json?["message"] as? String) ?? "공유 설정을 저장하지 못했어요.",
                status: http.statusCode
            )
        }
        return SpaceShareState(
            shareEnabled: share["shareEnabled"] as? Bool ?? false,
            shareToken: share["shareToken"] as? String,
            shareUrl: share["shareUrl"] as? String
        )
    }

    /// Build 78 — soft-delete owned GonggiSpace (links cleaned server-side). Does not delete R2.
    func deleteSpace(accessToken: String, spaceId: String) async throws {
        var request = URLRequest(
            url: config.apiBaseURL
                .appendingPathComponent("api/gonggi/spaces")
                .appendingPathComponent(spaceId)
        )
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MobileAuthAPIError.network
        }
        if (200..<300).contains(http.statusCode) { return }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        throw MobileAuthAPIError.server(
            code: (json?["error"] as? String) ?? "ERROR",
            message: (json?["message"] as? String) ?? "공간을 삭제하지 못했어요",
            status: http.statusCode
        )
    }

    private func postJSON(path: String, body: [String: Any]) async throws -> MobileAuthTokens {
        var request = URLRequest(url: config.apiBaseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MobileAuthAPIError.network }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MobileAuthAPIError.invalidResponse
        }
        if http.statusCode >= 400 || (json["ok"] as? Bool) == false {
            throw MobileAuthAPIError.server(
                code: (json["error"] as? String) ?? "ERROR",
                message: (json["message"] as? String) ?? "로그인에 실패했습니다.",
                status: http.statusCode
            )
        }
        guard let access = json["accessToken"] as? String,
              let refresh = json["refreshToken"] as? String
        else {
            throw MobileAuthAPIError.invalidResponse
        }
        let userDTO: MobileAuthUserDTO? = (json["user"] as? [String: Any]).map(parseUser)
        return MobileAuthTokens(
            accessToken: access,
            refreshToken: refresh,
            accessExpiresAt: json["accessExpiresAt"] as? String,
            sessionId: json["sessionId"] as? String,
            user: userDTO
        )
    }

    private func parseUser(_ user: [String: Any]) -> MobileAuthUserDTO {
        let credits = user["credits"] as? [String: Any]
        return MobileAuthUserDTO(
            id: user["id"] as? String ?? "",
            email: user["email"] as? String ?? "",
            name: user["name"] as? String ?? "",
            avatar: user["avatar"] as? String ?? user["avatarUrl"] as? String,
            provider: user["provider"] as? String ?? "",
            orgId: user["orgId"] as? String,
            creditsTotal: credits?["total"] as? Int ?? user["credits"] as? Int
        )
    }
}
