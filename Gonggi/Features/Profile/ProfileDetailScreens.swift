import AVFoundation
import AuthenticationServices
import CoreLocation
import SwiftUI
import UIKit

// MARK: - Profile edit name

struct ProfileEditNameView: View {
    @ObservedObject private var auth = AuthSessionController.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var saving = false
    @State private var errorMessage: String?
    private let maxLength = 80

    var body: some View {
        Form {
            Section {
                TextField(L("Display name"), text: $name)
                    .textInputAutocapitalization(.words)
                    .disabled(saving)
                Text("\(name.trimmingCharacters(in: .whitespacesAndNewlines).count)/\(maxLength)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(GonggiColors.error) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle(L("Edit profile"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L("Save")) { Task { await save() } }
                    .disabled(saving || !canSave)
            }
        }
        .onAppear {
            name = auth.profile?.name ?? auth.currentUser?.displayName ?? ""
        }
    }

    private var canSave: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maxLength && !saving
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }
        do {
            try await auth.updateDisplayName(name)
            dismiss()
        } catch let MobileAuthAPIError.server(_, message, _) {
            errorMessage = message
        } catch {
            errorMessage = L("Couldn't save the name.")
        }
    }
}

// MARK: - Email (read-only)

struct ProfileEmailView: View {
    @ObservedObject private var auth = AuthSessionController.shared

    private var provider: String {
        (auth.profile?.provider ?? auth.currentUser?.provider ?? "").uppercased()
    }

    var body: some View {
        List {
            Section(L("Account info")) {
                LabeledContent(L("Email"), value: auth.profile?.email ?? auth.currentUser?.email ?? "—")
                LabeledContent(
                    L("Verification"),
                    value: (auth.profile?.emailVerified == true) ? L("Verified") : L("Not verified")
                )
                LabeledContent(L("Sign-up / main sign-in"), value: Self.label(provider))
            }
            if provider == "GOOGLE" {
                Section {
                    Text(L("This email is managed by your Google account."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if provider == "APPLE" {
                Section {
                    Text(L("This email is managed by your Apple account."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle(L("Email"))
    }

    private static func label(_ p: String) -> String {
        switch p {
        case "GOOGLE": return "Google"
        case "APPLE": return "Apple"
        case "LOCAL": return L("Email")
        default: return p.isEmpty ? "—" : p
        }
    }
}

// MARK: - Providers (status only)

struct ProfileProvidersView: View {
    @ObservedObject private var auth = AuthSessionController.shared

    private var rows: [String] {
        if let ids = auth.profile?.providers, !ids.isEmpty { return ids }
        if let p = auth.profile?.provider, !p.isEmpty { return [p] }
        return []
    }

    var body: some View {
        List {
            Section {
                if rows.isEmpty {
                    Text(L("Can't check sign-in methods."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows, id: \.self) { id in
                        Text(L("%@ connected", "\(Self.label(id))"))
                    }
                }
            } footer: {
                Text(L("Adding or removing connections isn't supported yet."))
            }
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle(L("Sign-in methods"))
        .task { await auth.refreshProfile() }
    }

    private static func label(_ p: String) -> String {
        switch p.uppercased() {
        case "GOOGLE": return "Google"
        case "APPLE": return "Apple"
        case "LOCAL": return L("Email")
        default: return p
        }
    }
}

// MARK: - Password

struct ProfilePasswordView: View {
    enum Mode { case change, set }

    let mode: Mode
    @State private var current = ""
    @State private var newPassword = ""
    @State private var confirm = ""
    @State private var saving = false
    @State private var message: String?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if mode == .change {
                Section(L("Current password")) {
                    SecureField(L("Current password"), text: $current)
                        .textContentType(.password)
                }
            }
            Section(L("New password")) {
                SecureField(L("New password (8+ characters)"), text: $newPassword)
                    .textContentType(.newPassword)
                SecureField(L("Confirm new password"), text: $confirm)
                    .textContentType(.newPassword)
            }
            if let message {
                Section { Text(message).foregroundStyle(GonggiColors.accentTeal) }
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(GonggiColors.error) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle(mode == .change ? L("Change password") : L("Set password"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L("Save")) { Task { await save() } }
                    .disabled(saving || !canSave)
            }
        }
    }

    private var canSave: Bool {
        guard newPassword.count >= 8, newPassword == confirm, !saving else { return false }
        if mode == .change { return !current.isEmpty }
        return true
    }

    private func save() async {
        guard canSave, let token = AuthSessionController.shared.accessToken else { return }
        saving = true
        errorMessage = nil
        message = nil
        defer { saving = false }
        do {
            let api = MobileAccountAPIClient()
            try await api.changePassword(
                accessToken: token,
                currentPassword: mode == .change ? current : nil,
                newPassword: newPassword
            )
            message = L("Your password was changed.")
            current = ""
            newPassword = ""
            confirm = ""
            try? await Task.sleep(nanoseconds: 600_000_000)
            dismiss()
        } catch let MobileAuthAPIError.server(_, msg, _) {
            errorMessage = msg
        } catch {
            errorMessage = L("Couldn't change the password.")
        }
    }
}

// MARK: - Plan

struct ProfilePlanView: View {
    @ObservedObject private var auth = AuthSessionController.shared

    var body: some View {
        List {
            Section {
                LabeledContent(L("Current plan"), value: auth.profile?.planLabel ?? "—")
                if let end = auth.profile?.planPeriodEnd, let formatted = Self.formatISO(end) {
                    LabeledContent(L("Renews / expires"), value: formatted)
                }
            }
            Section(L("Main limits")) {
                Text(Self.limitsCopy(for: auth.profile?.planCode))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle(L("Current plan"))
        .task { await auth.refreshProfile() }
    }

    private static func limitsCopy(for code: String?) -> String {
        switch (code ?? "").uppercased() {
        case "STANDARD":
            return L("Up to 8 3D creations a month, 120 credits included")
        case "PRO":
            return L("Up to 23 3D creations a month, 300 credits included")
        case "FREE":
            return L("Credit-based use (no monthly creation limit)")
        default:
            return L("The plan limits on the server apply.")
        }
    }

    private static func formatISO(_ iso: String) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return nil }
        let out = DateFormatter()
        out.locale = AppLanguage.shared.locale
        out.dateStyle = .medium
        return out.string(from: date)
    }
}

// MARK: - Credits

struct ProfileCreditsView: View {
    @State private var credits: MobileAccountCreditsDTO?
    @State private var errorMessage: String?
    @State private var loading = true

    var body: some View {
        List {
            Section(L("Balance")) {
                if loading {
                    ProgressView()
                } else if let credits {
                    Text("\(credits.balance)")
                        .font(.title2.weight(.semibold))
                } else {
                    Text(errorMessage ?? L("Couldn't load the balance."))
                        .foregroundStyle(.secondary)
                }
            }
            if let entries = credits?.entries, !entries.isEmpty {
                Section(L("Recent activity")) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.kind)
                                Spacer()
                                Text(entry.delta >= 0 ? "+\(entry.delta)" : "\(entry.delta)")
                                    .foregroundStyle(entry.delta >= 0 ? GonggiColors.accentTeal : GonggiColors.error)
                            }
                            Text(Self.formatISO(entry.createdAt) ?? entry.createdAt)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle(L("Credits"))
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard let token = AuthSessionController.shared.accessToken else {
            errorMessage = L("Please sign in.")
            return
        }
        do {
            credits = try await MobileAccountAPIClient().fetchCredits(accessToken: token)
            errorMessage = nil
        } catch let MobileAuthAPIError.server(_, message, _) {
            errorMessage = message
            credits = nil
        } catch {
            errorMessage = L("Couldn't load credits.")
            credits = nil
        }
    }

    private static func formatISO(_ iso: String) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return nil }
        let out = DateFormatter()
        out.locale = AppLanguage.shared.locale
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: date)
    }
}

// MARK: - Usage

struct ProfileUsageView: View {
    @State private var usage: MobileAccountUsageDTO?
    @State private var errorMessage: String?
    @State private var loading = true

    var body: some View {
        List {
            if loading {
                ProgressView()
            } else if let usage {
                Section {
                    LabeledContent(L("Space"), value: "\(usage.spaces)")
                    LabeledContent(L("Creating"), value: "\(usage.generatingSpaces)")
                    LabeledContent(L("Sharing"), value: "\(usage.sharedSpaces)")
                    LabeledContent(L("3D Objects"), value: "\(usage.assets3d)")
                    if let bytes = usage.storageBytes {
                        LabeledContent(L("Storage"), value: Self.formatBytes(bytes))
                    }
                }
            } else {
                Text(errorMessage ?? L("Couldn't load usage."))
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle(L("Content usage"))
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard let token = AuthSessionController.shared.accessToken else {
            errorMessage = L("Please sign in.")
            return
        }
        do {
            usage = try await MobileAccountAPIClient().fetchUsage(accessToken: token)
        } catch let MobileAuthAPIError.server(_, message, _) {
            errorMessage = message
        } catch {
            errorMessage = L("Couldn't load usage.")
        }
    }

    private static func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Shared spaces

struct ProfileSharedSpacesView: View {
    @State private var spaces: [MobileSharedSpaceDTO] = []
    @State private var errorMessage: String?
    @State private var loading = true
    @State private var shareItem: SharePayload?
    @State private var revokingId: String?

    var body: some View {
        List {
            if loading {
                ProgressView()
            } else if spaces.isEmpty {
                Text(errorMessage ?? L("No spaces are shared."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(spaces) { space in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(space.title).font(.headline)
                        if let date = Self.formatISO(space.sharedAt) {
                            Text(L("Shared since %@", "\(date)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button(L("Copy link")) {
                                UIPasteboard.general.string = space.shareUrl
                                GonggiHaptics.light()
                            }
                            Button(L("Share")) {
                                shareItem = SharePayload(url: space.shareUrl)
                            }
                            Spacer()
                            Button(L("Stop sharing"), role: .destructive) {
                                Task { await revoke(space) }
                            }
                            .disabled(revokingId == space.spaceId)
                        }
                        .font(.subheadline)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle(L("Manage sharing"))
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $shareItem) { item in
            ActivityView(activityItems: [item.url])
        }
        .onReceive(NotificationCenter.default.publisher(for: .gonggiAccountPresentationDidReset)) { _ in
            spaces = []
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard let token = AuthSessionController.shared.accessToken else {
            spaces = []
            errorMessage = L("Please sign in.")
            return
        }
        do {
            spaces = try await MobileAccountAPIClient().fetchSharedSpaces(accessToken: token)
            errorMessage = nil
        } catch let MobileAuthAPIError.server(_, message, _) {
            errorMessage = message
            spaces = []
        } catch {
            errorMessage = L("Couldn't load the shared list.")
            spaces = []
        }
    }

    private func revoke(_ space: MobileSharedSpaceDTO) async {
        guard let token = AuthSessionController.shared.accessToken else { return }
        revokingId = space.spaceId
        defer { revokingId = nil }
        do {
            _ = try await MobileAuthAPIClient().setSpaceShare(
                accessToken: token,
                spaceId: space.spaceId,
                enabled: false
            )
            spaces.removeAll { $0.spaceId == space.spaceId }
        } catch {
            errorMessage = L("Couldn't stop sharing.")
        }
    }

    private static func formatISO(_ iso: String) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return nil }
        let out = DateFormatter()
        out.locale = AppLanguage.shared.locale
        out.dateStyle = .medium
        return out.string(from: date)
    }
}

private struct SharePayload: Identifiable {
    let id = UUID()
    let url: String
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - App settings

struct ProfileAppSettingsView: View {
    let userId: String?
    @State private var captureLocationEnabled: Bool
    @State private var allowCellular: Bool = GonggiAppSettings.allowCellularUpload
    @State private var hapticsEnabled: Bool = GonggiAppSettings.hapticsEnabled

    init(userId: String?) {
        self.userId = userId
        _captureLocationEnabled = State(
            initialValue: SpaceCaptureLocationPreferences.isEnabled(userId: userId)
        )
    }

    var body: some View {
        List {
            Toggle(L("Allow uploads over cellular"), isOn: $allowCellular)
                .onChange(of: allowCellular) { _, value in
                    GonggiAppSettings.allowCellularUpload = value
                }
            Toggle(L("Save capture location"), isOn: $captureLocationEnabled)
                .onChange(of: captureLocationEnabled) { _, enabled in
                    SpaceCaptureLocationPreferences.setEnabled(enabled, userId: userId)
                    if enabled {
                        Task { _ = try? await SpaceOneShotLocation().request() }
                    }
                }
                .disabled(userId == nil)
            Toggle(L("Haptic feedback"), isOn: $hapticsEnabled)
                .onChange(of: hapticsEnabled) { _, value in
                    GonggiAppSettings.hapticsEnabled = value
                }
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle(L("App settings"))
    }
}

// MARK: - Privacy / permissions

struct ProfilePrivacyPermissionsView: View {
    @ObservedObject private var auth = AuthSessionController.shared
    @State private var camera = L("Checking")
    @State private var location = L("Checking")
    @State private var mic = L("Checking")
    @State private var safariURL: SpaceLinkIdentifiedURL?

    var body: some View {
        List {
            Section(L("Permissions")) {
                permissionRow(L("Camera"), status: camera)
                permissionRow(L("Location"), status: location)
                permissionRow(L("Microphone"), status: mic)
                Button(L("Open iOS Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            Section(L("Terms")) {
                Button(L("Privacy Policy")) {
                    safariURL = SpaceLinkIdentifiedURL(url: GonggiProductURLs.privacyPolicy)
                }
                Button(L("Terms of Use")) {
                    safariURL = SpaceLinkIdentifiedURL(url: GonggiProductURLs.termsOfService)
                }
            }
            Section {
                NavigationLink(L("Manage shared spaces")) {
                    ProfileSharedSpacesView()
                }
                NavigationLink(L("Blocked users")) {
                    BlockedPublishersView(
                        userId: auth.profile?.id ?? auth.currentUser?.userId
                    )
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle(L("Privacy & permissions"))
        .task { refreshStatuses() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshStatuses()
        }
        .sheet(item: $safariURL) { item in
            SpaceLinkSafariView(url: item.url) { safariURL = nil }
        }
    }

    private func permissionRow(_ title: String, status: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(status).foregroundStyle(.secondary)
        }
    }

    private func refreshStatuses() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: camera = L("Allowed")
        case .denied: camera = L("Not allowed")
        case .restricted: camera = L("Restricted")
        case .notDetermined: camera = L("Not requested yet")
        @unknown default: camera = "—"
        }

        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: location = L("Allowed")
        case .denied: location = L("Not allowed")
        case .restricted: location = L("Restricted")
        case .notDetermined: location = L("Not requested yet")
        @unknown default: location = "—"
        }

        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: mic = L("Allowed")
        case .denied: mic = L("Not allowed")
        case .undetermined: mic = L("Not requested yet")
        @unknown default: mic = "—"
        }
    }
}

// MARK: - Help

struct ProfileHelpView: View {
    @State private var safariURL: SpaceLinkIdentifiedURL?
    @State private var versionTapCount = 0
    @State private var showInternalTools = GonggiFeatureFlags.isInternalToolsUnlocked
    @State private var unlockHint: String?

    private var versionLine: String {
        GonggiBuildInfo.versionLine
    }

    var body: some View {
        List {
            Section(L("Guides")) {
                helpLink(L("How to capture a space"))
                helpLink(L("Creation status explained"))
                helpLink(L("How to share"))
                helpLink(L("How to link spaces with hotspots"))
                helpLink(L("How to use 3D Objects and AR"))
            }
            Section(L("Contact")) {
                Button(L("Contact us")) {
                    safariURL = SpaceLinkIdentifiedURL(url: GonggiProductURLs.support)
                }
            }
            Section(L("About")) {
                Button {
                    handleVersionTap()
                } label: {
                    HStack {
                        Text(L("Version"))
                            .foregroundStyle(GonggiColors.textPrimary)
                        Spacer()
                        Text(versionLine)
                            .foregroundStyle(GonggiColors.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Version %@", "\(versionLine)"))
                .accessibilityHint(GonggiFeatureFlags.canUnlockInternalTools
                    ? L("Tap several times to unlock internal tools")
                    : "")
                if let unlockHint {
                    Text(unlockHint)
                        .font(.caption)
                        .foregroundStyle(GonggiColors.textSecondary)
                }
            }

            if showInternalTools {
                Section {
                    Text(L("Test A–E output: Captures/*/capture/debug/ (telemetry, sensor_space, camera_path_xz, decisions)"))
                        .font(.caption2)
                        .foregroundStyle(GonggiColors.textSecondary)
                } header: {
                    Text(L("Internal test"))
                } footer: {
                    Text(L("TestFlight/DEBUG only. Not shown in App Store builds."))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle(L("Help"))
        .onAppear {
            showInternalTools = GonggiFeatureFlags.isInternalToolsUnlocked
        }
        .sheet(item: $safariURL) { item in
            SpaceLinkSafariView(url: item.url) { safariURL = nil }
        }
    }

    private func handleVersionTap() {
        guard GonggiFeatureFlags.canUnlockInternalTools else { return }
        versionTapCount += 1
        if versionTapCount >= 7 {
            versionTapCount = 0
            GonggiFeatureFlags.setInternalToolsUnlocked(true)
            showInternalTools = true
            unlockHint = L("Internal test menu unlocked")
            GonggiHaptics.medium()
        } else if versionTapCount >= 4 {
            unlockHint = L("%@ more taps to internal tools", "\(7 - versionTapCount)")
        }
    }

    private func helpLink(_ title: String) -> some View {
        Button(title) {
            safariURL = SpaceLinkIdentifiedURL(url: GonggiProductURLs.helpCapture)
        }
    }
}

// MARK: - Delete account

struct ProfileDeleteAccountView: View {
    @ObservedObject private var auth = AuthSessionController.shared
    @State private var confirmed = false
    @State private var password = ""
    @State private var busy = false
    @State private var errorMessage: String?
    private let appleCoordinator = DeleteAppleReauthCoordinator()

    private var provider: String {
        (auth.profile?.provider ?? "").uppercased()
    }

    var body: some View {
        List {
            Section {
                Text(L("Your WHIK and 3D Locker account will be deleted. Saved spaces, 3D Objects, share links and remaining credits will no longer be available."))
                    .font(.footnote)
            }
            Section(L("What gets deleted")) {
                Text(L("Unified user account, WHIK spaces, original captures, panoramas, audio, hotspot links, share links, 3D Locker assets, sessions and tokens"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section(L("Retained")) {
                Text(L("Payment and accounting records that must be kept by law are stored apart from account data under the retention policy."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if provider == "LOCAL" || auth.profile?.hasPassword == true {
                Section(L("Confirm password")) {
                    SecureField(L("Current password"), text: $password)
                }
            }
            Section {
                Toggle(L("I've read the above and want to delete my account."), isOn: $confirmed)
                Button(L("Delete account"), role: .destructive) {
                    Task { await delete() }
                }
                .disabled(!confirmed || busy)
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(GonggiColors.error) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GonggiAmbientBackground(showGlow: false))
        .navigationTitle(L("Delete account"))
        .disabled(busy)
    }

    private func delete() async {
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            switch provider {
            case "APPLE":
                let tokens = try await appleCoordinator.reauthenticate()
                try await auth.deleteAccount(
                    appleIdentityToken: tokens.identityToken,
                    appleAuthorizationCode: tokens.authorizationCode
                )
            case "GOOGLE":
                let idToken = try await GoogleSignInCoordinator.shared.signIn()
                try await auth.deleteAccount(googleIdToken: idToken)
            default:
                try await auth.deleteAccount(currentPassword: password)
            }
        } catch let MobileAuthAPIError.server(_, message, _) {
            errorMessage = message
        } catch {
            errorMessage = error.localizedDescription.isEmpty
                ? L("Couldn't finish deleting the account.")
                : error.localizedDescription
        }
    }
}

@MainActor
final class DeleteAppleReauthCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<(identityToken: String, authorizationCode: String?), Error>?

    func reauthenticate() async throws -> (identityToken: String, authorizationCode: String?) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.email]
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8)
        else {
            continuation?.resume(throwing: MobileAuthAPIError.server(
                code: "REAUTH_FAILED",
                message: L("Apple account check failed."),
                status: 401
            ))
            continuation = nil
            return
        }
        let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        continuation?.resume(returning: (token, code))
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
