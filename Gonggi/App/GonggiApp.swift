import SwiftUI

@main
struct GonggiApp: App {
    @UIApplicationDelegateAdaptor(GonggiAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appState = AppState()
    @ObservedObject private var authSession = AuthSessionController.shared

    var body: some Scene {
        WindowGroup {
            rootContent
                .environmentObject(appState)
                .environmentObject(authSession)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    appState.handleScenePhase(phase)
                    if phase == .background {
                        CaptureSessionStore.pruneStaleSessions()
                    }
                }
                .onAppear {
                    appState.handleScenePhase(.active)
                }
                .onReceive(NotificationCenter.default.publisher(for: .gonggiOpenCompletedSpace)) { note in
                    let sid = (note.object as? String) ?? GonggiPushDeepLink.pendingSessionId
                    if let sid {
                        Task { await appState.openSpaceFromPush(sessionId: sid) }
                    }
                }
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        #if DEBUG
        if let screen = ScreenshotLaunchConfig.screen {
            ScreenshotRootView(screen: screen)
        } else {
            authenticatedRoot
        }
        #else
        authenticatedRoot
        #endif
    }

    @ViewBuilder
    private var authenticatedRoot: some View {
        switch authSession.phase {
        case .signedIn:
            MainTabView()
        case .signedOut:
            AuthShellView(session: authSession)
        }
    }
}
