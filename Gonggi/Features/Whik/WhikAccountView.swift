import SwiftUI

/// Account sheet (profile button, signed in). Keeps the existing account screens reachable:
/// notifications, profile, credits, app settings, privacy, help, sign out and account deletion.
struct WhikAccountView: View {
    let onClose: () -> Void
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var auth = AuthSessionController.shared
    @State private var confirmSignOut = false
    @State private var showExperiments = false
    /// TestFlight / DEBUG only, after the existing unlock (Help › version, 7 taps). Never on App Store builds.
    @State private var internalTools = GonggiFeatureFlags.isInternalToolsUnlocked

    private var user: AuthUserShell { auth.currentUser ?? .placeholder }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(WhikColors.mint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.displayName)
                                .font(.headline)
                                .foregroundStyle(WhikColors.textPrimary)
                            Text(user.email)
                                .font(.subheadline)
                                .foregroundStyle(WhikColors.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section("Account") {
                    link("Notifications", icon: "bell") { NotificationsListView().environmentObject(appState) }
                    link("Edit profile", icon: "person.crop.circle") { ProfileEditNameView() }
                    link("Sign-in methods", icon: "link") { ProfileProvidersView() }
                    link("Credits", icon: "sparkles") { ProfileCreditsView() }
                }
                Section("Settings") {
                    link("App settings", icon: "gearshape") { ProfileAppSettingsView(userId: user.userId) }
                    link("Privacy & permissions", icon: "hand.raised") { ProfilePrivacyPermissionsView() }
                    link("Help", icon: "questionmark.circle") { ProfileHelpView() }
                }
                if internalTools {
                    Section("Internal") {
                        Button {
                            showExperiments = true
                        } label: {
                            Label("Experiments", systemImage: "flask")
                        }
                        .listRowBackground(WhikColors.surface)
                    }
                }
                Section {
                    Button(role: .destructive) {
                        confirmSignOut = true
                    } label: {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    link("Delete account", icon: "person.crop.circle.badge.minus", tint: WhikColors.danger) {
                        ProfileDeleteAccountView()
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
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onClose)
                }
            }
            .task { await auth.refreshProfile() }
            .onAppear { internalTools = GonggiFeatureFlags.isInternalToolsUnlocked }
            .fullScreenCover(isPresented: $showExperiments) {
                // Preserved 실험 menu (hidden from the public shell; see docs/WHIK_HIDDEN_FEATURES.md).
                ExperimentHomeView(onClose: { showExperiments = false })
            }
            .alert("Sign out?", isPresented: $confirmSignOut) {
                Button("Cancel", role: .cancel) {}
                Button("Sign out", role: .destructive) {
                    GonggiHaptics.light()
                    onClose()
                    auth.signOutShell()
                }
            } message: {
                Text("Your captures stay in your account.")
            }
            .onChange(of: auth.phase) { _, phase in
                // Account deleted or signed out elsewhere.
                if case .signedOut = phase { onClose() }
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
        tint: Color = WhikColors.textPrimary,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            Label(title, systemImage: icon).foregroundStyle(tint)
        }
        .listRowBackground(WhikColors.surface)
    }
}
