import SwiftUI

/// Profile & settings sheet (profile button). Open for guests too: Language works without an account.
/// Signed in, it keeps the existing account screens reachable: notifications, profile, credits, app settings,
/// privacy, help, sign out and account deletion.
struct WhikAccountView: View {
    let onClose: () -> Void
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var gate: WhikAuthGate
    @ObservedObject private var auth = AuthSessionController.shared
    @State private var confirmSignOut = false
    @State private var showExperiments = false
    /// TestFlight / DEBUG only, after the existing unlock (Help › version, 7 taps). Never on App Store builds.
    @State private var internalTools = GonggiFeatureFlags.isInternalToolsUnlocked

    private var user: AuthUserShell? { auth.currentUser }

    var body: some View {
        NavigationStack {
            List {
                if let user {
                    Section {
                        HStack(spacing: 14) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(WhikColors.mint)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.displayName)
                                    .font(.headline)
                                    .foregroundStyle(WhikColors.textPrimary)
                                if !user.email.isEmpty {
                                    Text(user.email)
                                        .font(.subheadline)
                                        .foregroundStyle(WhikColors.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                        .listRowBackground(WhikColors.surface)
                    }
                } else {
                    Section {
                        Button {
                            // One sheet at a time: close this one, then ask for sign-in.
                            onClose()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { gate.signIn() }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "person.crop.circle")
                                    .font(.system(size: 40))
                                    .foregroundStyle(WhikColors.textSecondary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L("Guest"))
                                        .font(.headline)
                                        .foregroundStyle(WhikColors.textPrimary)
                                    Text(L("Sign in to save your captures"))
                                        .font(.subheadline)
                                        .foregroundStyle(WhikColors.textSecondary)
                                }
                                Spacer(minLength: 8)
                                Text(L("Sign in")).foregroundStyle(WhikColors.mint)
                            }
                            .padding(.vertical, 6)
                        }
                        .listRowBackground(WhikColors.surface)
                    }
                }

                Section(L("Settings")) {
                    link(L("Language"), icon: "globe", trailing: AppLanguage.shared.code.nativeName) {
                        WhikLanguageView()
                    }
                    if user != nil {
                        link(L("App settings"), icon: "gearshape") { ProfileAppSettingsView(userId: user?.userId) }
                    }
                    link(L("Privacy & permissions"), icon: "hand.raised") { ProfilePrivacyPermissionsView() }
                    link(L("Help"), icon: "questionmark.circle") { ProfileHelpView() }
                }

                if user != nil {
                    Section(L("Account")) {
                        link(L("Notifications"), icon: "bell") { NotificationsListView().environmentObject(appState) }
                        link(L("Edit profile"), icon: "person.crop.circle") { ProfileEditNameView() }
                        link(L("Sign-in methods"), icon: "link") { ProfileProvidersView() }
                        link(L("Credits"), icon: "sparkles") { ProfileCreditsView() }
                    }
                }
                if internalTools {
                    Section(L("Internal")) {
                        Button {
                            showExperiments = true
                        } label: {
                            Label(L("Experiments"), systemImage: "flask")
                        }
                        .listRowBackground(WhikColors.surface)
                    }
                }
                if user != nil {
                    Section {
                        Button(role: .destructive) {
                            confirmSignOut = true
                        } label: {
                            Label(L("Sign out"), systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .listRowBackground(WhikColors.surface)
                        link(L("Delete account"), icon: "person.crop.circle.badge.minus", tint: WhikColors.danger) {
                            ProfileDeleteAccountView()
                        }
                    }
                }
                Section {
                    Text(Self.versionLabel)
                        .font(.footnote)
                        .foregroundStyle(WhikColors.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(WhikColors.background.ignoresSafeArea())
            .navigationTitle(L("Profile"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("Done"), action: onClose)
                }
            }
            .task { if user != nil { await auth.refreshProfile() } }
            .onAppear { internalTools = GonggiFeatureFlags.isInternalToolsUnlocked }
            .fullScreenCover(isPresented: $showExperiments) {
                // Preserved 실험 menu (hidden from the public shell; see docs/WHIK_HIDDEN_FEATURES.md).
                ExperimentHomeView(onClose: { showExperiments = false })
            }
            .alert(L("Sign out?"), isPresented: $confirmSignOut) {
                Button(L("Cancel"), role: .cancel) {}
                Button(L("Sign out"), role: .destructive) {
                    GonggiHaptics.light()
                    auth.signOutShell()
                }
            } message: {
                Text(L("Your captures stay in your account."))
            }
        }
        .preferredColorScheme(.dark)
    }

    static var versionLabel: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return "WHIK: 3D Scanner \(v) (\(b))"
    }

    private func link<Destination: View>(
        _ title: String,
        icon: String,
        trailing: String? = nil,
        tint: Color = WhikColors.textPrimary,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                Label(title, systemImage: icon).foregroundStyle(tint)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).foregroundStyle(WhikColors.textSecondary).lineLimit(1)
                }
            }
        }
        .listRowBackground(WhikColors.surface)
    }
}

/// Language picker. Names are shown in their own language; the choice applies at once (no restart) and is
/// kept for the next launch. Capture, generation and viewers keep running.
struct WhikLanguageView: View {
    var body: some View {
        List {
            Section {
                ForEach(AppLanguage.Code.allCases) { code in
                    Button {
                        GonggiHaptics.selection()
                        AppLanguage.shared.set(code)
                    } label: {
                        HStack {
                            Text(code.nativeName)
                                .foregroundStyle(WhikColors.textPrimary)
                                .environment(\.locale, Locale(identifier: code.rawValue))
                            Spacer()
                            if AppLanguage.shared.code == code {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(WhikColors.mint)
                                    .fontWeight(.semibold)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(AppLanguage.shared.code == code ? [.isButton, .isSelected] : .isButton)
                    .listRowBackground(WhikColors.surface)
                }
            } footer: {
                Text(L("System screens such as permission prompts and the keyboard follow your iPhone's language."))
                    .foregroundStyle(WhikColors.textTertiary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(WhikColors.background.ignoresSafeArea())
        .navigationTitle(L("Language"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
