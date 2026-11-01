import AuthenticationServices
import Foundation
import UIKit

/// Google account for 글자 스캔, separate from WHIK sign-in: the same iOS OAuth client, asking only for Google
/// Sheets. The refresh token lives in a new Keychain item of its own; the WHIK sign-in items are not touched.
@MainActor
final class TextScanGoogleAuth: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = TextScanGoogleAuth()

    enum AuthError: LocalizedError {
        case notConfigured
        case cancelled
        case failed

        var errorDescription: String? {
            switch self {
            case .notConfigured: return L("Google sign-in isn't set up in this build.")
            case .cancelled: return L("Google connection was cancelled.")
            case .failed: return L("Couldn't connect to Google. Please try again.")
            }
        }
    }

    @Published private(set) var email: String?
    var isConnected: Bool { email != nil }

    private static let keychainService = "com.whik.textscan.google"
    private static let refreshAccount = "refresh_token"
    private static let emailKey = "whik.textScan.googleEmail"
    private static let scope = "openid email https://www.googleapis.com/auth/spreadsheets"

    private var accessToken: String?
    private var accessExpiresAt: Date?
    private var activeSession: ASWebAuthenticationSession?

    override init() {
        super.init()
        let hasRefresh = (try? GonggiKeychain.get(service: Self.keychainService, account: Self.refreshAccount)) != nil
        email = hasRefresh ? (UserDefaults.standard.string(forKey: Self.emailKey) ?? "") : nil
    }

    func connect() async throws {
        let config = AppConfiguration.production
        guard config.isGoogleSignInConfigured, !config.googleReversedClientID.isEmpty else { throw AuthError.notConfigured }
        let redirectURI = "\(config.googleReversedClientID):/oauth2redirect/google"
        let state = GoogleOAuthPKCE.makeState()
        let verifier = GoogleOAuthPKCE.makeCodeVerifier()

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.googleClientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: GoogleOAuthPKCE.codeChallengeS256(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // Always show the account chooser and the Sheets consent, so a refresh token is issued.
            URLQueryItem(name: "prompt", value: "select_account consent"),
        ]
        let callback = try await present(components.url!, scheme: config.googleReversedClientID)
        let params = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard params.first(where: { $0.name == "state" })?.value == state,
              let code = params.first(where: { $0.name == "code" })?.value, !code.isEmpty
        else { throw AuthError.failed }

        let json = try await tokenRequest([
            "client_id": config.googleClientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ])
        guard let refresh = json["refresh_token"] as? String, let access = json["access_token"] as? String else {
            throw AuthError.failed
        }
        try GonggiKeychain.set(refresh, service: Self.keychainService, account: Self.refreshAccount)
        store(access: access, expiresIn: json["expires_in"] as? Double)
        let mail = (json["id_token"] as? String).flatMap(Self.email(fromIDToken:)) ?? ""
        UserDefaults.standard.set(mail, forKey: Self.emailKey)
        email = mail
    }

    func disconnect() {
        if let refresh = try? GonggiKeychain.get(service: Self.keychainService, account: Self.refreshAccount) {
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(Self.formEncoded(["token": refresh]).utf8)
            URLSession.shared.dataTask(with: req).resume()
        }
        GonggiKeychain.delete(service: Self.keychainService, account: Self.refreshAccount)
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
        accessToken = nil
        accessExpiresAt = nil
        email = nil
    }

    /// Access token valid for at least a minute, refreshed with the stored refresh token when needed.
    func accessTokenForSheets(force: Bool = false) async throws -> String {
        if !force, let accessToken, let accessExpiresAt, accessExpiresAt.timeIntervalSinceNow > 60 { return accessToken }
        guard let refresh = try? GonggiKeychain.get(service: Self.keychainService, account: Self.refreshAccount) else {
            email = nil
            throw GoogleSheetsClient.SheetsError.notConnected
        }
        let json: [String: Any]
        do {
            json = try await tokenRequest([
                "client_id": AppConfiguration.production.googleClientID,
                "refresh_token": refresh,
                "grant_type": "refresh_token",
            ])
        } catch {
            throw GoogleSheetsClient.SheetsError.notConnected
        }
        guard let access = json["access_token"] as? String else { throw GoogleSheetsClient.SheetsError.notConnected }
        store(access: access, expiresIn: json["expires_in"] as? Double)
        return access
    }

    private func store(access: String, expiresIn: Double?) {
        accessToken = access
        accessExpiresAt = Date().addingTimeInterval(expiresIn ?? 3000)
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(Self.formEncoded(fields).utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        // Never log the body: it holds tokens.
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AuthError.failed }
        return json
    }

    private func present(_ url: URL, scheme: String) async throws -> URL {
        defer { activeSession = nil }
        return try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    cont.resume(throwing: AuthError.cancelled)
                } else if let callback {
                    cont.resume(returning: callback)
                } else {
                    cont.resume(throwing: AuthError.failed)
                }
            }
            session.presentationContextProvider = self
            activeSession = session
            if !session.start() {
                activeSession = nil
                cont.resume(throwing: AuthError.failed)
            }
        }
    }

    nonisolated static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["email"] as? String
    }

    private static func formEncoded(_ fields: [String: String]) -> String {
        var c = URLComponents()
        c.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.percentEncodedQuery ?? ""
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}

/// Sheets this phone has used for 글자 스캔 (created here or pasted as a link), most recent first.
enum TextScanSheetStore {
    private static let key = "whik.textScan.sheets"

    static func load() -> [TextScanSheet] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([TextScanSheet].self, from: data)) ?? []
    }

    static func remember(_ sheet: TextScanSheet) {
        save([sheet] + load().filter { $0.id != sheet.id })
    }

    static func forget(_ id: String) {
        save(load().filter { $0.id != id })
    }

    private static func save(_ sheets: [TextScanSheet]) {
        if let data = try? JSONEncoder().encode(Array(sheets.prefix(20))) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// `POST /api/mobile/text-scan/extract` on the WHIK server.
struct TextScanAPIClient {
    struct Row: Decodable, Equatable {
        var values: [String]
        var uncertain: [Int]
    }

    enum APIError: LocalizedError {
        case notSignedIn
        case server(String?)
        case network

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return L("Sign in to WHIK again.")
            case .server(let message): return message ?? L("Couldn't read the text. Please try again.")
            case .network: return L("Check your internet connection and try again.")
            }
        }
    }

    var config: AppConfiguration = .production

    func extract(jpegs: [Data], columns: [String], sheetTitle: String) async throws -> [Row] {
        guard let token = await AuthSessionController.shared.freshAccessToken(), !token.isEmpty else { throw APIError.notSignedIn }
        var req = URLRequest(url: config.apiBaseURL.appendingPathComponent("api/mobile/text-scan/extract"))
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "columns": columns,
            "images": jpegs.map { $0.base64EncodedString() },
            "sheetTitle": sheetTitle,
        ] as [String: Any])

        struct Response: Decodable {
            var ok: Bool?
            var rows: [Row]?
            var message: String?
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try? JSONDecoder().decode(Response.self, from: data)
        if status == 401 { throw APIError.notSignedIn }
        guard (200..<300).contains(status), decoded?.ok == true, let rows = decoded?.rows else {
            throw APIError.server(decoded?.message)
        }
        return rows
    }
}
