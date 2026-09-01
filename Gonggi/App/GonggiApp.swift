import SwiftUI

@main
struct GonggiApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            rootContent
                .environmentObject(appState)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        CaptureSessionStore.pruneStaleSessions()
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
            MainTabView()
        }
        #else
        MainTabView()
        #endif
    }
}
