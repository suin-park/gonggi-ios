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

    func claimInstallation(accessToken: String, sessionIds: [String]) async throws {
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
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MobileAuthAPIError.network
        }
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
