import SwiftUI

/// Multi-space VR cover host — A→B→C via Navigation-style stack (Build 72).
/// Build 80 — owns space-audio fade transitions across stack changes.
struct SpaceVRNavigationHost: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var stack: [SpaceViewerSession]
    @State private var fadeOpacity: Double = 0
    @State private var navigateError: String?
    @State private var isTransitioning = false

    var onClose: () -> Void

    init(sessions: [SpaceViewerSession], onClose: @escaping () -> Void) {
        _stack = State(initialValue: sessions.isEmpty ? [] : sessions)
        self.onClose = onClose
    }

    init(root: SpaceViewerSession, onClose: @escaping () -> Void) {
        _stack = State(initialValue: [root])
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            if let current = stack.last {
                VRSphereSpaceView(
                    imageURL: current.fileURL,
                    sessionId: current.id,
                    preferredAudioURL: current.audioURL,
                    onClose: {
                        if stack.count > 1 {
                            stack.removeLast()
                            Task { await playAudioForTopOfStack() }
                        } else {
                            Task {
                                await SpaceAudioManager.shared.fadeOutAndStop()
                                onClose()
                            }
                        }
                    },
                    onNavigateToLinkedSpace: { link in
                        Task { await navigate(to: link) }
                    }
                )
                .id(current.id)
            }

            Color.black
                .opacity(fadeOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(isTransitioning)
        }
        .alert("공간을 불러올 수 없어요", isPresented: Binding(
            get: { navigateError != nil },
            set: { if !$0 { navigateError = nil } }
        )) {
            Button("확인", role: .cancel) { navigateError = nil }
        } message: {
            Text(navigateError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .gonggiSpaceDidDelete)) { note in
            let sessionId = note.userInfo?["sessionId"] as? String
            let jobId = note.userInfo?["jobId"] as? String
            stack.removeAll { $0.id == sessionId || $0.id == jobId }
            if stack.isEmpty {
                Task {
                    await SpaceAudioManager.shared.fadeOutAndStop()
                    onClose()
                }
            } else {
                Task { await playAudioForTopOfStack() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                SpaceAudioManager.shared.pauseForBackground()
            case .active:
                SpaceAudioManager.shared.resumeFromBackground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onDisappear {
            // Cover dismissed without explicit close — stop with fade.
            Task { await SpaceAudioManager.shared.fadeOutAndStop() }
        }
    }

    @MainActor
    private func navigate(to link: SpaceLink) async {
        guard !isTransitioning else { return }
        let targetKey = link.targetSessionId ?? link.targetSpaceId
        guard let targetKey, !targetKey.isEmpty else {
            navigateError = "연결할 공간을 찾을 수 없어요"
            return
        }

        isTransitioning = true
        withAnimation(.easeInOut(duration: 0.25)) {
            fadeOpacity = 1
        }
        // Fade out A audio while visual fade runs.
        async let audioFade: Void = SpaceAudioManager.shared.fadeOutAndStop()
        try? await Task.sleep(nanoseconds: 250_000_000)
        _ = await audioFade

        let result = await appState.prepareSpaceViewer(jobId: targetKey)
        switch result {
        case .success(let url):
            let audioURL = await SpaceAudioManager.shared.resolveAudioURL(spaceId: targetKey)
            let session = SpaceViewerSession(id: targetKey, fileURL: url, audioURL: audioURL)
            stack.append(session)
            withAnimation(.easeInOut(duration: 0.28)) {
                fadeOpacity = 0
            }
            await SpaceAudioManager.shared.playForSpace(spaceId: targetKey, preferredURL: audioURL)
            try? await Task.sleep(nanoseconds: 280_000_000)
            isTransitioning = false
        case .failure:
            withAnimation(.easeInOut(duration: 0.2)) {
                fadeOpacity = 0
            }
            isTransitioning = false
            navigateError = "공간을 불러올 수 없어요"
            // Restore previous space audio if still on stack.
            await playAudioForTopOfStack()
        }
    }

    @MainActor
    private func playAudioForTopOfStack() async {
        guard let current = stack.last else {
            await SpaceAudioManager.shared.fadeOutAndStop()
            return
        }
        await SpaceAudioManager.shared.playForSpace(
            spaceId: current.id,
            preferredURL: current.audioURL
        )
    }
}

/// fullScreenCover payload that can open a multi-space stack (source → target).
struct SpaceViewerLaunch: Identifiable, Equatable {
    let id: String
    let sessions: [SpaceViewerSession]

    init(sessions: [SpaceViewerSession]) {
        self.sessions = sessions
        self.id = sessions.map(\.id).joined(separator: ">")
    }

    init(single: SpaceViewerSession) {
        self.init(sessions: [single])
    }
}
