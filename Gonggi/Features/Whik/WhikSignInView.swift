import SwiftUI

/// Sign-in sheet shown on demand (see `WhikAuthGate`). Reuses the existing Apple / Google / email sign-in.
struct WhikSignInView: View {
    let reason: String
    let onCancel: () -> Void
    @ObservedObject private var session = AuthSessionController.shared
    @StateObject private var appleCoordinator = AppleSignInCoordinator()
    @State private var googleBusy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    WhikLogo(width: 170)
                        .padding(.top, 28)
                    Text(reason)
                        .font(.system(.body))
                        .foregroundStyle(WhikColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                    VStack(spacing: 12) {
                        button("Continue with Apple", icon: "apple.logo") {
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
                                        session.lastError = err.errorDescription ?? "Apple sign-in failed."
                                    }
                                }
                            }
                        }
                        button("Continue with Google", icon: "g.circle") {
                            Task { await startGoogle() }
                        }
                        .disabled(googleBusy)
                        button("Continue with Email", icon: "envelope") {
                            session.emailSheetPresented = true
                        }
                    }
                    if let err = session.lastError {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(WhikColors.danger)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .background(WhikColors.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Not now", action: onCancel)
                        .foregroundStyle(WhikColors.textPrimary)
                }
            }
            .sheet(isPresented: $session.emailSheetPresented) {
                EmailContinueView(session: session)
            }
            .onAppear {
                session.lastError = nil
                appleCoordinator.prepare()
            }
        }
        .preferredColorScheme(.dark)
    }

    private func startGoogle() async {
        googleBusy = true
        defer { googleBusy = false }
        do {
            let idToken = try await GoogleSignInCoordinator.shared.signIn()
            await session.signInWithGoogleIDToken(idToken)
        } catch {
            session.lastError = (error as? LocalizedError)?.errorDescription ?? "Google sign-in couldn't start."
        }
    }

    private func button(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            GonggiHaptics.medium()
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 22, height: 22)
                Text(title)
                    .font(.system(.body).weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(WhikColors.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(WhikColors.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(WhikColors.border, lineWidth: 1))
        }
        .buttonStyle(GonggiPressableStyle())
        .accessibilityLabel(title)
    }
}
