import SwiftUI

@main
struct GonggiApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        CaptureSessionStore.pruneStaleSessions()
                    }
                }
        }
    }
}
