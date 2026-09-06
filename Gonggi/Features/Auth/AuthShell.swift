import AuthenticationServices
import CryptoKit
import Foundation
import SwiftUI

struct AuthUserShell: Equatable {
    var displayName: String
    var email: String
    var photoSystemImage: String
    var userId: String?
    var provider: String?
    var creditsLabel: String?

    static let placeholder = AuthUserShell(
        displayName: "공기 사용자",
        email: "계정 연동 전",
        photoSystemImage: "person.fill"
    )
}

enum AuthSessionPhase: Equatable {
    case restoring
    case signedIn(AuthUserShell)
    case signedOut
}

/// Production mobile session: Keychain refresh + memory access + /api/auth/me profile.
@MainActor
final class AuthSessionController: ObservableObject {
    static let shared = AuthSessionController()

    private static let keychainService = "com.whik.gonggi.auth"
    private static let refreshAccount = "mobile.refresh"
    private static let sessionAccount = "mobile.sessionId"

    @Published private(set) var phase: AuthSessionPhase = .restoring
    @Published var lastError: String?
    @Published var emailSheetPresented = false

    private let api = MobileAuthAPIClient()
    private(set) var accessToken: String?
    private(set) var refreshToken: String?
    private(set) var mobileSessionId: String?
    private(set) var profile: MobileAuthUserDTO?

    var isSignedIn: Bool {
        if case .signedIn = phase { return true }
        return false
    }

    var currentUser: AuthUserShell? {
        if case .signedIn(let user) = phase { return user }
        return nil
    }

    func bootstrap() {
        Task { await restoreSession() }
    }

    func restoreSession() async {
        phase = .restoring
        let storedRefresh = try? GonggiKeychain.get(service: Self.keychainService, account: Self.refreshAccount)
        let storedSession = try? GonggiKeychain.get(service: Self.keychainService, account: Self.sessionAccount)
        guard let storedRefresh, !storedRefresh.isEmpty else {
            clearLocalCredentials()
            phase = .signedOut
            return
        }
        do {
            let tokens = try await api.refresh(refreshToken: storedRefresh)
            try await applyTokens(tokens)
            await afterSignedInSideEffects()
        } catch {
            clearLocalCredentials()
            phase = .signedOut
            lastError = nil
        }
        _ = storedSession
    }

    func signInWithEmail(email: String, password: String) async {
        lastError = nil
        do {
            let tokens = try await api.emailLogin(email: email, password: password)
            try await applyTokens(tokens)
            emailSheetPresented = false
            await afterSignedInSideEffects()
        } catch let MobileAuthAPIError.server(_, message, _) {
            lastError = message
        } catch {
            lastError = "로그인에 실패했습니다."
        }
    }

    func signInWithGoogleIDToken(_ idToken: String) async {
        lastError = nil
        do {
            let tokens = try await api.googleLogin(idToken: idToken)
            try await applyTokens(tokens)
            await afterSignedInSideEffects()
        } catch let MobileAuthAPIError.server(_, message, _) {
            lastError = message
        } catch {
            lastError = "Google 로그인에 실패했습니다."
        }
    }

    func signInWithApple(
        identityToken: String,
        nonce: String?,
        fullName: String?,
        email: String?
    ) async {
        lastError = nil
        do {
            let tokens = try await api.appleLogin(
                identityToken: identityToken,
                nonce: nonce,
                fullName: fullName,
                email: email
            )
            try await applyTokens(tokens)
            await afterSignedInSideEffects()
        } catch let MobileAuthAPIError.server(_, message, _) {
            lastError = message
        } catch {
            lastError = "Apple 로그인에 실패했습니다."
        }
    }

    /// Legacy shell API — routes to email sheet (tests / older call sites).
    func signInShell(providerLabel: String) {
        switch providerLabel {
        case "email":
            emailSheetPresented = true
        default:
            emailSheetPresented = true
        }
    }

    func signOutShell() {
        Task { await signOut() }
    }

    func signOut() async {
        let access = accessToken
        let refresh = refreshToken
        let sessionId = mobileSessionId
        await api.logout(accessToken: access, refreshToken: refresh, sessionId: sessionId)
        clearLocalCredentials()
        phase = .signedOut
    }

    private func applyTokens(_ tokens: MobileAuthTokens) async throws {
        accessToken = tokens.accessToken
        refreshToken = tokens.refreshToken
        mobileSessionId = tokens.sessionId
        MobileAuthTokenStore.shared.setAccessToken(tokens.accessToken)
        try GonggiKeychain.set(tokens.refreshToken, service: Self.keychainService, account: Self.refreshAccount)
        if let sessionId = tokens.sessionId {
            try GonggiKeychain.set(sessionId, service: Self.keychainService, account: Self.sessionAccount)
        }

        var user = tokens.user
        if user == nil {
            user = try await api.fetchMe(accessToken: tokens.accessToken)
        }
        profile = user
        let shell = user?.shell ?? .placeholder
        var enriched = shell
        enriched.userId = user?.id
        enriched.provider = user?.provider
        if let credits = user?.creditsTotal {
            enriched.creditsLabel = "\(credits)"
        }
        phase = .signedIn(enriched)
    }

    private func clearLocalCredentials() {
        accessToken = nil
        refreshToken = nil
        mobileSessionId = nil
        profile = nil
        MobileAuthTokenStore.shared.setAccessToken(nil)
        GonggiKeychain.delete(service: Self.keychainService, account: Self.refreshAccount)
        GonggiKeychain.delete(service: Self.keychainService, account: Self.sessionAccount)
    }

    private func afterSignedInSideEffects() async {
        guard let access = accessToken else { return }
        let sessionIds = SpaceJobStore.shared.jobs.map(\.sessionId)
        try? await api.claimInstallation(accessToken: access, sessionIds: sessionIds)
        await SpaceLibraryReconciler.shared.reconcile(accessToken: access)
    }
}

// MARK: - Auth shell UI

struct AuthShellView: View {
    @ObservedObject var session: AuthSessionController
    @StateObject private var appleCoordinator = AppleSignInCoordinator()
    @State private var googleBusy = false

    var body: some View {
        ZStack {
            GonggiAmbientBackground()
            VStack(spacing: GonggiSpacing.xl) {
                Spacer()
                VStack(spacing: GonggiSpacing.sm) {
                    Text("공기")
                        .font(GonggiTypography.title(36))
                        .foregroundStyle(GonggiColors.textPrimary)
                    Text("공간을 기록하고 기억하다")
                        .font(GonggiTypography.body(16))
                        .foregroundStyle(GonggiColors.textSecondary)
                }

                VStack(spacing: GonggiSpacing.sm) {
                    authButton(title: "Google로 계속하기", icon: "g.circle") {
                        Task { await startGoogle() }
                    }
                    .disabled(googleBusy)

                    authButton(title: "Apple로 계속하기", icon: "apple.logo") {
                        appleCoordinator.start { result in
                            Task {
                                switch result {
                                case .success(let payload):
                                    await session.signInWithApple(
                                        identityToken: payload.identityToken,
                                        nonce: payload.nonce,
                                        fullName: payload.fullName,
                                        email: payload.email
                                    )
                                case .failure(let message):
                                    session.lastError = message
                                }
                            }
                        }
                    }

                    authButton(title: "이메일로 계속하기", icon: "envelope") {
                        session.emailSheetPresented = true
                    }
                }
                .padding(.horizontal, GonggiSpacing.lg)

                Text("하나의 계정으로 공기와 3D Locker를 함께 이용할 수 있어요.")
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, GonggiSpacing.xl)

                if let err = session.lastError {
                    Text(err)
                        .font(GonggiTypography.caption(12))
                        .foregroundStyle(GonggiColors.error)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, GonggiSpacing.lg)
                }

                Spacer()
            }
        }
        .sheet(isPresented: $session.emailSheetPresented) {
            EmailContinueView(session: session)
        }
        .onAppear {
            appleCoordinator.prepare()
        }
    }

    private func startGoogle() async {
        googleBusy = true
        defer { googleBusy = false }
        do {
            let idToken = try await GoogleSignInCoordinator.shared.signIn()
            await session.signInWithGoogleIDToken(idToken)
        } catch {
            session.lastError = (error as? LocalizedError)?.errorDescription
                ?? "Google 로그인을 시작하지 못했습니다. Client ID 설정을 확인하세요."
        }
    }

    private func authButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            GonggiHaptics.medium()
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                Text(title)
                    .font(GonggiTypography.body(16))
            }
            .foregroundStyle(GonggiColors.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(GonggiColors.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                    .stroke(GonggiColors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
        }
        .buttonStyle(GonggiPressableStyle())
    }
}

struct EmailContinueView: View {
    @ObservedObject var session: AuthSessionController
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var mode: Mode = .login

    enum Mode: String, CaseIterable {
        case login = "로그인"
        case registerHint = "회원가입"
        case resetHint = "비밀번호 재설정"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("이메일", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                    SecureField("비밀번호", text: $password)
                }
                Section {
                    Picker("방식", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    switch mode {
                    case .login:
                        Button(busy ? "로그인 중…" : "계속하기") {
                            busy = true
                            Task {
                                await session.signInWithEmail(email: email, password: password)
                                busy = false
                                if session.isSignedIn { dismiss() }
                            }
                        }
                        .disabled(busy || email.isEmpty || password.isEmpty)
                    case .registerHint:
                        Text("회원가입·이메일 인증은 3D Locker 웹과 동일합니다. www.3d-locker.com 에서 가입한 뒤 여기서 로그인하세요.")
                            .font(.footnote)
                        if let url = URL(string: "https://www.3d-locker.com") {
                            Link("3D Locker에서 가입하기", destination: url)
                        }
                    case .resetHint:
                        Text("비밀번호 재설정도 3D Locker 웹에서 진행합니다.")
                            .font(.footnote)
                        if let url = URL(string: "https://www.3d-locker.com") {
                            Link("비밀번호 재설정 열기", destination: url)
                        }
                    }
                }
                if let err = session.lastError {
                    Section {
                        Text(err).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("이메일로 계속하기")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Apple

struct AppleSignInPayload {
    var identityToken: String
    var nonce: String?
    var fullName: String?
    var email: String?
}

@MainActor
final class AppleSignInCoordinator: NSObject, ObservableObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: ((Result<AppleSignInPayload, String>) -> Void)?
    private(set) var rawNonce: String?

    func prepare() {
        rawNonce = Self.randomNonce()
    }

    func start(completion: @escaping (Result<AppleSignInPayload, String>) -> Void) {
        continuation = completion
        if rawNonce == nil { prepare() }
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        if let rawNonce {
            request.nonce = Self.sha256(rawNonce)
        }
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8)
        else {
            continuation?(.failure("Apple 토큰을 읽지 못했습니다."))
            continuation = nil
            return
        }
        var fullName: String?
        if let name = credential.fullName {
            let parts = [name.familyName, name.givenName].compactMap { $0 }.filter { !$0.isEmpty }
            if !parts.isEmpty { fullName = parts.joined(separator: " ") }
        }
        continuation?(.success(AppleSignInPayload(
            identityToken: identityToken,
            nonce: rawNonce.map { Self.sha256($0) },
            fullName: fullName,
            email: credential.email
        )))
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?(.failure(error.localizedDescription))
        continuation = nil
    }

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            _ = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            if random < charset.count {
                result.append(charset[Int(random)])
                remaining -= 1
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Google (ASWebAuthenticationSession → id_token)

enum GoogleSignInCoordinator {
    static let shared = GoogleSignInBridge()
}

final class GoogleSignInBridge: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum GoogleError: LocalizedError {
        case missingClientID
        case cancelled
        case noIdToken

        var errorDescription: String? {
            switch self {
            case .missingClientID:
                return "Info.plist에 GoogleClientID(iOS OAuth client)를 설정하세요."
            case .cancelled:
                return "Google 로그인이 취소되었습니다."
            case .noIdToken:
                return "Google ID 토큰을 받지 못했습니다."
            }
        }
    }

    func signIn() async throws -> String {
        let clientID = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String
        guard let clientID, !clientID.isEmpty else { throw GoogleError.missingClientID }

        let reversed = clientID.split(separator: ".").reversed().joined(separator: ".")
        let redirectURI = "\(reversed):/oauth2redirect/google"
        let nonce = UUID().uuidString
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "id_token"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "nonce", value: nonce),
        ]
        guard let authURL = components.url else { throw GoogleError.noIdToken }

        return try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: reversed
            ) { callbackURL, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                guard let callbackURL,
                      let fragment = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.fragment
                else {
                    cont.resume(throwing: GoogleError.noIdToken)
                    return
                }
                let params = fragment.split(separator: "&").reduce(into: [String: String]()) { acc, pair in
                    let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    if parts.count == 2 { acc[parts[0]] = parts[1].removingPercentEncoding }
                }
                guard let idToken = params["id_token"] else {
                    cont.resume(throwing: GoogleError.noIdToken)
                    return
                }
                cont.resume(returning: idToken)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                cont.resume(throwing: GoogleError.cancelled)
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
