import UIKit
import UserNotifications

/// Bridges UIKit APNs callbacks into SwiftUI GonggiApp.
final class GonggiAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Synchronously: a tap that launched the app is delivered right after this returns.
        MainActor.assumeIsolated {
            GonggiPushRegistrar.shared.configure()
            GonggiPushRegistrar.shared.registerIfAuthorized()
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            GonggiPushRegistrar.shared.didRegister(deviceToken: deviceToken)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            GonggiPushRegistrar.shared.didFailToRegister(error: error)
        }
    }
}
