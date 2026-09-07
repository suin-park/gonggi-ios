import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Google iOS OAuth via ASWebAuthenticationSession: authorization code + PKCE (S256).
/// No client_secret. Returns Google `id_token` for `POST /api/auth/mobile/google`.
enum GoogleSignInCoordinator {
    static let shared = GoogleSignInBridge()
}

enum GoogleOAuthPKCE {
    /// RFC 7636 code_verifier: 43–128 unreserved characters (base64url of random bytes).
    static func makeCodeVerifier(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    static func makeState() -> String {
        makeCodeVerifier(byteCount: 16)
    }

    static func codeChallengeS256(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

final class GoogleSignInBridge: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum GoogleError: LocalizedError {
        case missingClientID
        case cancelled
        case stateMismatch
        case missingAuthCode
        case tokenExchangeFailed
        case noIdToken

        var errorDescription: String? {
            switch self {
            case .missingClientID:
                return "Info.plist에 GoogleClientID(iOS OAuth client)를 설정하세요."
            case .cancelled:
                return "Google 로그인이 취소되었습니다."
            case .stateMismatch:
                return "Google 로그인 보안 검증에 실패했습니다. 다시 시도해 주세요."
            case .missingAuthCode:
                return "Google 인증 코드를 받지 못했습니다."
            case .tokenExchangeFailed:
                return "Google 토큰 교환에 실패했습니다."
            case .noIdToken:
                return "Google ID 토큰을 받지 못했습니다."
            }
        }
    }

    /// Retained for the duration of ASWebAuthenticationSession (local var would deallocate).
    private var activeSession: ASWebAuthenticationSession?

    func signIn() async throws -> String {
        let config = AppConfiguration.production
        guard config.isGoogleSignInConfigured else { throw GoogleError.missingClientID }
        let clientID = config.googleClientID
        let reversed = config.googleReversedClientID
        guard !reversed.isEmpty else { throw GoogleError.missingClientID }

        let redirectURI = "\(reversed):/oauth2redirect/google"
        let state = GoogleOAuthPKCE.makeState()
        let codeVerifier = GoogleOAuthPKCE.makeCodeVerifier()
        let codeChallenge = GoogleOAuthPKCE.codeChallengeS256(for: codeVerifier)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authURL = components.url else { throw GoogleError.missingAuthCode }

        let callbackURL = try await presentAuthSession(authURL: authURL, callbackScheme: reversed)
        let params = Self.queryParams(from: callbackURL)
        guard let returnedState = params["state"], returnedState == state else {
            throw GoogleError.stateMismatch
        }
        guard let code = params["code"], !code.isEmpty else {
            throw GoogleError.missingAuthCode
        }

        return try await exchangeCodeForIDToken(
            code: code,
            codeVerifier: codeVerifier,
            clientID: clientID,
            redirectURI: redirectURI
        )
    }

    private func presentAuthSession(authURL: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, error in
                self?.activeSession = nil
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                guard let callbackURL else {
                    cont.resume(throwing: GoogleError.cancelled)
                    return
                }
                cont.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            activeSession = session
            if !session.start() {
                activeSession = nil
                cont.resume(throwing: GoogleError.cancelled)
            }
        }
    }

    private func exchangeCodeForIDToken(
        code: String,
        codeVerifier: String,
        clientID: String,
        redirectURI: String
    ) async throws -> String {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Installed iOS clients: PKCE only — never send client_secret.
        let body = [
            "client_id": clientID,
            "code": code,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]
        request.httpBody = Data(Self.formURLEncoded(body).utf8)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            // Do not log response body (may contain tokens).
            throw GoogleError.tokenExchangeFailed
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let idToken = json["id_token"] as? String,
            !idToken.isEmpty
        else {
            throw GoogleError.noIdToken
        }
        return idToken
    }

    private static func queryParams(from url: URL) -> [String: String] {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var out: [String: String] = [:]
        for item in comps?.queryItems ?? [] {
            if let value = item.value {
                out[item.name] = value
            }
        }
        if let fragment = comps?.fragment, !fragment.isEmpty {
            for pair in fragment.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    out[parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
                }
            }
        }
        return out
    }

    private static func formURLEncoded(_ fields: [String: String]) -> String {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery ?? ""
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
