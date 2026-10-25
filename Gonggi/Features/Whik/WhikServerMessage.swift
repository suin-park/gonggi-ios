import Foundation
import os

/// Short, localized messages for server errors. The raw server message (often in one fixed language) is logged,
/// never shown: users see copy in the selected app language.
enum WhikServerMessage {
    private static let log = Logger(subsystem: "com.whik.gonggi", category: "ServerError")

    enum Action {
        case signIn, signUp, verifyEmail, resendCode, resetRequest, resetComplete, google, apple

        var fallback: String {
            switch self {
            case .signIn: return L("Sign-in failed.")
            case .signUp: return L("Sign-up failed.")
            case .verifyEmail: return L("Email verification failed.")
            case .resendCode: return L("Couldn't resend the code.")
            case .resetRequest: return L("Couldn't send the reset email.")
            case .resetComplete: return L("Password reset failed.")
            case .google: return L("Google sign-in failed.")
            case .apple: return L("Apple sign-in failed.")
            }
        }
    }

    /// Auth endpoints (`api/auth/mobile/*`): known codes get a specific line, everything else the action's
    /// generic message.
    static func auth(_ action: Action, code: String?, status: Int?, raw: String?) -> String {
        log.error("auth \(String(describing: action), privacy: .public) code=\(code ?? "-", privacy: .public) status=\(status ?? 0) message=\(raw ?? "", privacy: .private)")
        switch code {
        case "INVALID_CREDENTIALS", "INVALID_PASSWORD": return L("The email or password is incorrect.")
        case "EMAIL_EXISTS": return L("This email is already registered. Sign in instead.")
        case "EMAIL_NOT_VERIFIED": return L("Verify your email first. Check your inbox for the code.")
        case "INVALID_CODE": return L("The code is incorrect or has expired.")
        case "RATE_LIMITED": return L("Too many attempts. Please try again later.")
        case "OAUTH_ONLY", "PASSWORD_NOT_SET": return L("This account uses Apple or Google sign-in.")
        case "INVALID_INPUT": return L("Check the information you entered.")
        case "AUTH_REQUIRED", "AUTH_EXPIRED": return L("Please sign in again.")
        default: break
        }
        if let status, status >= 500 { return L("Something went wrong. Please try again.") }
        return action.fallback
    }

    /// Any other server call: status-based, raw message logged only.
    static func generic(code: String?, status: Int?, raw: String?, context: String) -> String {
        log.error("\(context, privacy: .public) code=\(code ?? "-", privacy: .public) status=\(status ?? 0) message=\(raw ?? "", privacy: .private)")
        switch status {
        case 401, 403: return L("Please sign in again.")
        case .some(let s) where s >= 500: return L("Something went wrong. Please try again.")
        default: return L("Something went wrong. Please try again.")
        }
    }
}
