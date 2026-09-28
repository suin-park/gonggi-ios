import Foundation
import UIKit
import UserNotifications

/// Device installation identity (no account yet) + APNs token registration.
enum GonggiInstallation {
    private static let key = "gonggi.installationId.v1"

    static var id: String {
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}

@MainActor
final class GonggiPushRegistrar: NSObject, UNUserNotificationCenterDelegate {
    static let shared = GonggiPushRegistrar()

    private static let promptedKey = "gonggi.push.permissionPrompted.v1"
    private var pendingTokenData: Data?
    /// Last APNs token, so a sign-in / sign-out can re-link it to the current account.
    private var lastTokenData: Data?

    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Call around first space-generation start — not cold launch.
    func requestPermissionIfAppropriate() {
        let prompted = UserDefaults.standard.bool(forKey: Self.promptedKey)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .notDetermined:
                    guard !prompted else { return }
                    UserDefaults.standard.set(true, forKey: Self.promptedKey)
                    let granted = try? await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound, .badge])
                    if granted == true {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                case .authorized, .provisional, .ephemeral:
                    UIApplication.shared.registerForRemoteNotifications()
                default:
                    break
                }
            }
        }
    }

    /// Launch / sign-in: refresh the token without prompting (only when already allowed).
    func registerIfAuthorized() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    UIApplication.shared.registerForRemoteNotifications()
                default:
                    break
                }
            }
        }
    }

    /// Account changed: re-send the last token so the server links it to the signed-in owner
    /// (or unlinks it after sign-out — the request then has no bearer).
    func refreshRegistration() {
        guard let token = lastTokenData else {
            registerIfAuthorized()
            return
        }
        Task { await uploadToken(token) }
    }

    func didRegister(deviceToken: Data) {
        pendingTokenData = deviceToken
        lastTokenData = deviceToken
        Task { await uploadToken(deviceToken) }
    }

    func didFailToRegister(error: Error) {
        #if DEBUG
        print("[gonggi-push] register failed: \(error.localizedDescription)")
        #endif
    }

    private func uploadToken(_ tokenData: Data) async {
        let hex = tokenData.map { String(format: "%02x", $0) }.joined()
        let truncated = hex.prefix(8) + "…"
        #if DEBUG
        print("[gonggi-push] registering token prefix=\(truncated)")
        #endif

        let config = AppConfiguration.production
        let url = config.apiBaseURL.appendingPathComponent("api/gonggi/push/register")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Links this installation to the signed-in owner (3D space ready pushes go to the owner only).
        if let access = MobileAuthTokenStore.shared.getAccessToken() {
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        }

        let info = Bundle.main.infoDictionary
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "0"
        let buildNumber = info?["CFBundleVersion"] as? String ?? "0"
        let body: [String: Any] = [
            "deviceToken": hex,
            "platform": "ios",
            "installationId": GonggiInstallation.id,
            "appVersion": appVersion,
            "buildNumber": buildNumber,
            "bundleId": Bundle.main.bundleIdentifier ?? "com.whik.gonggi",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                #if DEBUG
                print("[gonggi-push] register HTTP failed")
                #endif
                return
            }
        } catch {
            #if DEBUG
            print("[gonggi-push] register network error")
            #endif
        }
    }

    // Foreground presentation
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        Task { @MainActor in
            Self.handleAdvancedCaptureUserInfo(userInfo)
        }
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let sessionId = (userInfo["sessionId"] as? String)
            ?? (userInfo["session_id"] as? String)
        let type = userInfo["type"] as? String
        let readySpaceId = type == "gaussian_space_ready" ? (userInfo["spaceId"] as? String) : nil
        Task { @MainActor in
            if let readySpaceId, !readySpaceId.isEmpty {
                // Cold launch: kept until the signed-in tab view appears (MainTabView consumes it).
                GonggiPushDeepLink.pendingGaussianSpaceId = readySpaceId
                NotificationCenter.default.post(name: .gonggiOpenGaussianSpace, object: readySpaceId)
                completionHandler()
                return
            }
            Self.handleAdvancedCaptureUserInfo(userInfo)
            if type == "space_generation_completed" || sessionId != nil {
                GonggiPushDeepLink.pendingSessionId = sessionId
                NotificationCenter.default.post(name: .gonggiOpenCompletedSpace, object: sessionId)
            }
            completionHandler()
        }
    }

    @MainActor
    private static func handleAdvancedCaptureUserInfo(_ userInfo: [AnyHashable: Any]) {
        let advancedId = (userInfo["advancedCaptureSessionId"] as? String)
            ?? (userInfo["type"] as? String == "advanced_capture_analysis_complete"
                ? ((userInfo["sessionId"] as? String) ?? (userInfo["session_id"] as? String))
                : nil)
        guard let advancedId, !advancedId.isEmpty else { return }
        AdvancedCaptureAnalysisRuntime.shared.handleExternalCompletionHint(sessionId: advancedId)
    }
}

enum GonggiPushDeepLink {
    static var pendingSessionId: String?
    /// 3D space (GaussianSpace) from a "space ready" push tap, not yet opened.
    @MainActor static var pendingGaussianSpaceId: String?
}

extension Notification.Name {
    static let gonggiOpenCompletedSpace = Notification.Name("gonggiOpenCompletedSpace")
    static let gonggiOpenGaussianSpace = Notification.Name("gonggiOpenGaussianSpace")
}
