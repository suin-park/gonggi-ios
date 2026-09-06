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

    func didRegister(deviceToken: Data) {
        pendingTokenData = deviceToken
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
        Task { @MainActor in
            if type == "space_generation_completed" || sessionId != nil {
                GonggiPushDeepLink.pendingSessionId = sessionId
                NotificationCenter.default.post(name: .gonggiOpenCompletedSpace, object: sessionId)
            }
            completionHandler()
        }
    }
}

enum GonggiPushDeepLink {
    static var pendingSessionId: String?
}

extension Notification.Name {
    static let gonggiOpenCompletedSpace = Notification.Name("gonggiOpenCompletedSpace")
}
