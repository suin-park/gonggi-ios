import SwiftUI

/// Keeps SpaceCleanupSession polling lifecycle outside VRSphereSpaceView's giant
/// `viewerLifecycleBody` expression (Swift type-checker budget).
struct SpaceCleanupLifecycleModifier: ViewModifier {
    @ObservedObject var session: SpaceCleanupSession
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear {
                if session.isActive {
                    session.onSelectionUIAppear()
                }
            }
            .onDisappear {
                session.onSelectionUIDisappear()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    session.onScenePhaseActive()
                case .background:
                    session.onScenePhaseBackground()
                default:
                    break
                }
            }
            .onChange(of: session.isActive) { _, active in
                if active {
                    session.onSelectionUIAppear()
                } else {
                    session.onSelectionUIDisappear()
                }
            }
    }
}
