import SwiftUI

/// Auth / account shell models — provider wiring is Phase D.
struct AuthUserShell: Equatable {
    var displayName: String
    var email: String
    var photoSystemImage: String

    static let placeholder = AuthUserShell(
        displayName: "Whik 사용자",
        email: "계정 연동 전",
        photoSystemImage: "person.fill"
    )
}

enum AuthSessionPhase: Equatable {
    case signedIn(AuthUserShell)
    case signedOut
}

/// Local session shell. Default signed-in so existing device flows keep working
/// until real 3D Locker / Gonggi unified auth is connected.
@MainActor
final class AuthSessionController: ObservableObject {
    static let shared = AuthSessionController()

    private static let signedOutKey = "gonggi.auth.shellSignedOut.v1"

    @Published private(set) var phase: AuthSessionPhase

    init() {
        if UserDefaults.standard.bool(forKey: Self.signedOutKey) {
            phase = .signedOut
        } else {
            phase = .signedIn(.placeholder)
        }
    }

    var isSignedIn: Bool {
        if case .signedIn = phase { return true }
        return false
    }

    var currentUser: AuthUserShell? {
        if case .signedIn(let user) = phase { return user }
        return nil
    }

    func signInShell(providerLabel: String) {
        // Phase D: Google / Apple / email → unified Gonggi + 3D Locker account.
        _ = providerLabel
        UserDefaults.standard.set(false, forKey: Self.signedOutKey)
        phase = .signedIn(.placeholder)
    }

    func signOutShell() {
        UserDefaults.standard.set(true, forKey: Self.signedOutKey)
        phase = .signedOut
    }
}

/// Unified signup/login shell — one account for 공기 + 3D Locker.
struct AuthShellView: View {
    @ObservedObject var session: AuthSessionController

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
                        session.signInShell(providerLabel: "google")
                    }
                    authButton(title: "Apple로 계속하기", icon: "apple.logo") {
                        session.signInShell(providerLabel: "apple")
                    }
                    authButton(title: "이메일로 계속하기", icon: "envelope") {
                        session.signInShell(providerLabel: "email")
                    }
                }
                .padding(.horizontal, GonggiSpacing.lg)

                Text("하나의 계정으로 공기와 3D Locker를 함께 이용할 수 있어요.")
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, GonggiSpacing.xl)

                Spacer()
            }
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
