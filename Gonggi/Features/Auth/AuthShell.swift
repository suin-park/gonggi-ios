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
        // Never show device-global space catalog while auth is unresolved.
        SpaceJobStore.shared.bind(.none)
        let storedRefresh = try? GonggiKeychain.get(service: Self.keychainService, account: Self.refreshAccount)
        let storedSession = try? GonggiKeychain.get(service: Self.keychainService, account: Self.sessionAccount)
        guard let storedRefresh, !storedRefresh.isEmpty else {
            clearLocalCredentials()
            AccountPresentationReset.resetForSignOut()
            phase = .signedOut
            return
        }
        do {
            let tokens = try await api.refresh(refreshToken: storedRefresh)
            try await applyTokens(tokens)
            await afterSignedInSideEffects()
        } catch {
            clearLocalCredentials()
            AccountPresentationReset.resetForSignOut()
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
        // Clear presentation immediately (before network logout completes).
        clearLocalCredentials()
        AccountPresentationReset.resetForSignOut()
        phase = .signedOut
        await api.logout(accessToken: access, refreshToken: refresh, sessionId: sessionId)
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
        // Bind empty/user partition before UI shows signed-in content from a prior account.
        if let userId = user?.id, !userId.isEmpty {
            AccountPresentationReset.prepareForSignedIn(userId: userId)
        } else {
            AccountPresentationReset.resetForSignOut()
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
        let generation = AuthSessionGeneration.current
        let userId = profile?.id
        // Only anonymous / unknown-owner sessionIds — never re-claim other accounts' jobs.
        let sessionIds = SpaceJobStore.shared.claimEligibleSessionIds()
        if let claim = try? await api.claimInstallation(accessToken: access, sessionIds: sessionIds),
           AuthSessionGeneration.isCurrent(generation),
           let userId {
            let claimed = Set(claim.sessionIds)
            if !claimed.isEmpty {
                SpaceJobStore.shared.absorbClaimedSessions(claimed, intoUserId: userId)
            }
        }
        guard AuthSessionGeneration.isCurrent(generation) else { return }
        await SpaceLibraryReconciler.shared.reconcile(accessToken: access, generation: generation)
        guard AuthSessionGeneration.isCurrent(generation) else { return }
        AssetLibraryStore.shared.refresh(force: true)
    }
}

// MARK: - Auth shell UI

/// Welcome decoration mode. Production default is street panorama sample.
enum AuthWelcomeDecoration: Equatable {
    case wireframeSphere
    case spaceLight
    case panoramaSample
}

struct AuthShellView: View {
    @ObservedObject var session: AuthSessionController
    /// Production Welcome uses official 360° street sample; legacy decorations remain for DEBUG fixtures.
    var decoration: AuthWelcomeDecoration = .panoramaSample
    @StateObject private var appleCoordinator = AppleSignInCoordinator()
    @State private var googleBusy = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Keep logo compact so sample card + three auth actions stay visible on compact height.
    private var welcomeLogoWidth: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 120 }
        if sizeCategory >= .extraExtraLarge { return 132 }
        return 148
    }

    private var decorationHeight: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 132 }
        if sizeCategory >= .extraExtraLarge { return 156 }
        return 180
    }

    private var sphereDiameter: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 100 }
        if sizeCategory >= .extraExtraLarge { return 120 }
        return 140
    }

    /// Top flexible inset scales with usable height (~50–80pt on tall phones; compresses first on short).
    private func welcomeTopMin(for usableHeight: CGFloat) -> CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return GonggiSpacing.sm }
        let proposed = usableHeight * 0.078
        return min(80, max(GonggiSpacing.md, proposed))
    }

    private var welcomeBottomMin: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? GonggiSpacing.md : GonggiSpacing.lg
    }

    var body: some View {
        ZStack {
            GonggiAmbientBackground()
            GeometryReader { geo in
                let usableHeight = geo.size.height
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        Spacer(minLength: welcomeTopMin(for: usableHeight))

                        // Independent centered logo header (does not force form centering).
                        GonggiLogoView(variant: .white, width: welcomeLogoWidth)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, GonggiSpacing.xs)

                        welcomeDecoration
                            .frame(height: decorationHeight)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            .padding(.vertical, GonggiSpacing.xs)

                        VStack(spacing: GonggiSpacing.sm) {
                            Text(WelcomePanoramaSampleAsset.headline)
                                .font(GonggiTypography.title(22))
                                .foregroundStyle(GonggiColors.textPrimary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(WelcomePanoramaSampleAsset.subtitle)
                                .font(GonggiTypography.body(15))
                                .foregroundStyle(GonggiColors.textSecondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.9)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, GonggiSpacing.lg)
                        .padding(.top, GonggiSpacing.sm)
                        .padding(.bottom, GonggiSpacing.md)

                        VStack(spacing: GonggiSpacing.sm) {
                            authButton(title: "Google로 계속하기", icon: "g.circle") {
                                Task { await startGoogle() }
                            }
                            .disabled(googleBusy)

                            authButton(title: "Apple로 계속하기", icon: "apple.logo") {
                                appleCoordinator.beginSignIn { result in
                                    Task { @MainActor in
                                        switch result {
                                        case .success(let payload):
                                            await session.signInWithApple(
                                                identityToken: payload.identityToken,
                                                nonce: payload.nonce,
                                                fullName: payload.fullName,
                                                email: payload.email
                                            )
                                        case .failure(let err):
                                            session.lastError = err.errorDescription ?? "Apple 로그인에 실패했습니다."
                                        }
                                    }
                                }
                            }

                            authButton(title: "이메일로 계속하기", icon: "envelope") {
                                session.emailSheetPresented = true
                            }
                        }
                        .padding(.horizontal, GonggiSpacing.lg)

                        Text(WelcomePanoramaSampleAsset.accountFootnote)
                            .font(GonggiTypography.caption(13))
                            .foregroundStyle(GonggiColors.textTertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, GonggiSpacing.xl)
                            .padding(.top, GonggiSpacing.sm)
                            .padding(.bottom, GonggiSpacing.sm)

                        if let err = session.lastError {
                            Text(err)
                                .font(GonggiTypography.caption(12))
                                .foregroundStyle(GonggiColors.error)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, GonggiSpacing.lg)
                                .padding(.bottom, GonggiSpacing.sm)
                        }

                        Spacer(minLength: welcomeBottomMin)
                    }
                    .frame(maxWidth: .infinity, minHeight: usableHeight, alignment: .top)
                }
            }
        }
        .sheet(isPresented: $session.emailSheetPresented) {
            EmailContinueView(session: session)
        }
        .onAppear {
            appleCoordinator.prepare()
        }
    }

    @ViewBuilder
    private var welcomeDecoration: some View {
        GeometryReader { geo in
            let w = max(200, geo.size.width)
            switch decoration {
            case .wireframeSphere:
                GonggiWireframeSphereView(
                    diameter: min(sphereDiameter, w * 0.55),
                    isAnimating: scenePhase == .active
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            case .spaceLight:
                GonggiSpaceLightStoryView(
                    size: CGSize(width: min(300, w), height: decorationHeight),
                    isAnimating: scenePhase == .active
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            case .panoramaSample:
                WelcomePanoramaSampleView(isActive: scenePhase == .active)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
                // Cap SF Symbol growth under accessibility Dynamic Type.
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 22, height: 22)
                Text(title)
                    .font(GonggiTypography.body(16))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(GonggiColors.textPrimary)
            .frame(maxWidth: .infinity, minHeight: GonggiSpacing.touchTarget + 8)
            .padding(.horizontal, GonggiSpacing.md)
            .padding(.vertical, 12)
            .background(GonggiColors.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                    .stroke(GonggiColors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
        }
        .buttonStyle(GonggiPressableStyle())
        .accessibilityLabel(title)
    }
}

struct EmailContinueView: View {
    @ObservedObject var session: AuthSessionController
    var autofocusEmail: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var mode: Mode = .login
    @FocusState private var focusedField: Field?

    enum Field { case email, password }

    enum Mode: String, CaseIterable {
        case login = "로그인"
        case registerHint = "회원가입"
        case resetHint = "비밀번호 재설정"
    }

    /// Prior square canvas 140pt ≈94pt ink; +25% visual ≈118pt on cropped asset.
    private let emailLogoWidth: CGFloat = 120

    var body: some View {
        NavigationStack {
            ZStack {
                GonggiAmbientBackground(showGlow: false)
                ScrollView {
                    VStack(alignment: .leading, spacing: GonggiSpacing.md) {
                        GonggiLogoView(variant: .white, width: emailLogoWidth)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, GonggiSpacing.xs)
                            .padding(.bottom, GonggiSpacing.xs)

                        Text("이메일로 계속하기")
                            .font(GonggiTypography.title(22))
                            .foregroundStyle(GonggiColors.textPrimary)

                        VStack(spacing: GonggiSpacing.sm) {
                            TextField("이메일", text: $email)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.emailAddress)
                                .textContentType(.emailAddress)
                                .focused($focusedField, equals: .email)
                                .padding(GonggiSpacing.md)
                                .background(GonggiColors.surfaceElevated)
                                .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous))
                            SecureField("비밀번호", text: $password)
                                .textContentType(.password)
                                .focused($focusedField, equals: .password)
                                .padding(GonggiSpacing.md)
                                .background(GonggiColors.surfaceElevated)
                                .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous))
                        }
                        .foregroundStyle(GonggiColors.textPrimary)

                        Picker("방식", selection: $mode) {
                            ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)

                        switch mode {
                        case .login:
                            PrimaryButton(title: busy ? "로그인 중…" : "계속하기") {
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
                                .font(GonggiTypography.body(14))
                                .foregroundStyle(GonggiColors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let url = URL(string: "https://www.3d-locker.com") {
                                Link("3D Locker에서 가입하기", destination: url)
                                    .foregroundStyle(GonggiColors.brandCyan)
                            }
                        case .resetHint:
                            Text("비밀번호 재설정도 3D Locker 웹에서 진행합니다.")
                                .font(GonggiTypography.body(14))
                                .foregroundStyle(GonggiColors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let url = URL(string: "https://www.3d-locker.com") {
                                Link("비밀번호 재설정 열기", destination: url)
                                    .foregroundStyle(GonggiColors.brandCyan)
                            }
                        }

                        if let err = session.lastError {
                            Text(err)
                                .font(GonggiTypography.caption(13))
                                .foregroundStyle(GonggiColors.error)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(GonggiSpacing.lg)
                    .padding(.bottom, GonggiSpacing.xxl)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                        .foregroundStyle(GonggiColors.textSecondary)
                }
            }
            .onAppear {
                if autofocusEmail {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        focusedField = .email
                    }
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

enum AppleSignInFlowError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

@MainActor
final class AppleSignInCoordinator: NSObject, ObservableObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: ((Result<AppleSignInPayload, AppleSignInFlowError>) -> Void)?
    private(set) var rawNonce: String?

    func prepare() {
        rawNonce = Self.randomNonce()
    }

    func beginSignIn(completion: @escaping (Result<AppleSignInPayload, AppleSignInFlowError>) -> Void) {
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
            continuation?(.failure(.message("Apple 토큰을 읽지 못했습니다.")))
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
        continuation?(.failure(.message(error.localizedDescription)))
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

// Google OAuth (authorization code + PKCE): see GoogleSignInBridge.swift