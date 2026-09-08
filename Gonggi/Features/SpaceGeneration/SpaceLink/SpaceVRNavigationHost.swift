import SwiftUI
import UIKit

/// Multi-space VR cover host — A→B→C via Navigation-style stack (Build 72).
/// Build 80 — owns space-audio fade transitions across stack changes.
/// Build 81 — production rotate + FOV zoom + dual-view crossfade (no camera push).
struct SpaceVRNavigationHost: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotionEnv
    @State private var stack: [SpaceViewerSession]
    /// Legacy black dissolve — fallback only when transition infrastructure is unavailable.
    @State private var fadeOpacity: Double = 0
    @State private var navigateError: String?
    @State private var isTransitioning = false
    /// While true, render last two stack sessions for source→target opacity crossfade.
    @State private var isCrossfading = false
    @State private var sourceOpacity: Double = 1
    @State private var targetOpacity: Double = 1
    @State private var targetEntryFOV: Double = SpaceLinkTransitionMath.baseFOV
    @State private var suppressStackAudio = false
    @State private var targetReadyWaiter: CheckedContinuation<Void, Never>?
    @State private var targetReadyPending = false

    var onClose: () -> Void

    init(sessions: [SpaceViewerSession], onClose: @escaping () -> Void) {
        _stack = State(initialValue: sessions.isEmpty ? [] : sessions)
        self.onClose = onClose
    }

    init(root: SpaceViewerSession, onClose: @escaping () -> Void) {
        _stack = State(initialValue: [root])
        self.onClose = onClose
    }

    private var renderSessions: [SpaceViewerSession] {
        guard let last = stack.last else { return [] }
        if isCrossfading, stack.count >= 2 {
            return Array(stack.suffix(2))
        }
        return [last]
    }

    var body: some View {
        ZStack {
            ForEach(renderSessions) { session in
                let isTop = session.id == stack.last?.id
                let isSourceDuringCrossfade = isCrossfading && !isTop
                VRSphereSpaceView(
                    imageURL: session.fileURL,
                    sessionId: session.id,
                    preferredAudioURL: session.audioURL,
                    suppressAutoAudio: suppressStackAudio || isCrossfading,
                    initialFieldOfView: isTop ? targetEntryFOV : SpaceLinkTransitionMath.baseFOV,
                    spaceLinkTransitionLocked: isTransitioning,
                    transitionBridgeRole: isSourceDuringCrossfade ? .overlay : .primary,
                    onClose: {
                        guard !isTransitioning else { return }
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
                    },
                    onViewerReady: {
                        if isCrossfading, isTop {
                            signalTargetReady()
                        }
                    }
                )
                .opacity(opacity(for: session, isTop: isTop))
                .allowsHitTesting(isTop && !isTransitioning)
                .zIndex(isTop ? 1 : 0)
            }

            Color.black
                .opacity(fadeOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(isTransitioning && fadeOpacity > 0.01)
        }
        .alert("공간을 불러오지 못했어요", isPresented: Binding(
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
            Task { await SpaceAudioManager.shared.fadeOutAndStop() }
        }
    }

    private func opacity(for session: SpaceViewerSession, isTop: Bool) -> Double {
        guard isCrossfading, stack.count >= 2 else { return 1 }
        return isTop ? targetOpacity : sourceOpacity
    }

    private func signalTargetReady() {
        if let waiter = targetReadyWaiter {
            targetReadyWaiter = nil
            waiter.resume()
        } else {
            targetReadyPending = true
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

        let reduceMotion = reduceMotionEnv || UIAccessibility.isReduceMotionEnabled
        let sourceId = stack.last?.id ?? "?"
        isTransitioning = true
        suppressStackAudio = true

        let sourceHost = SpaceLinkTransitionBridge.shared.activeHost
        guard let sourceHost else {
            #if DEBUG
            print("[spaceLink81] fallback reason=no_active_host source=\(sourceId) target=\(targetKey)")
            #endif
            await navigateWithBlackFallback(targetKey: targetKey)
            return
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        let startPose = sourceHost.currentEquirectCenterDegrees()
        let yawDelta = SpaceLinkTransitionMath.cappedShortestYawDelta(
            from: startPose.yawDeg,
            to: link.yawDeg
        )
        let pitchDelta = link.pitchDeg - startPose.pitchDeg

        sourceHost.setSpaceLinkTransitionLocked(true)
        sourceHost.pulseHotspotExit(id: link.id)

        #if DEBUG
        print(
            "[spaceLink81] begin source=\(sourceId) target=\(targetKey) sourceYaw=\(startPose.yawDeg) sourcePitch=\(startPose.pitchDeg) hotspotYaw=\(link.yawDeg) hotspotPitch=\(link.pitchDeg) yawDelta=\(yawDelta) pitchDelta=\(pitchDelta) reduceMotion=\(reduceMotion)"
        )
        #endif

        async let audioFade: Void = SpaceAudioManager.shared.fadeOutAndStop(
            duration: SpaceAudioPolicy.fadeOutSeconds
        )

        let alignStart = CFAbsoluteTimeGetCurrent()
        async let alignZoom: Void = sourceHost.runAlignAndZoom(
            targetYawDeg: link.yawDeg,
            targetPitchDeg: link.pitchDeg,
            targetFOV: SpaceLinkTransitionMath.zoomFOV,
            reduceMotion: reduceMotion
        )

        let preloadStart = CFAbsoluteTimeGetCurrent()
        let result = await appState.prepareSpaceViewer(jobId: targetKey)
        let preloadMs = Int((CFAbsoluteTimeGetCurrent() - preloadStart) * 1000)
        await alignZoom
        let alignMs = Int((CFAbsoluteTimeGetCurrent() - alignStart) * 1000)
        _ = await audioFade

        switch result {
        case .success(let url):
            let audioURL = await SpaceAudioManager.shared.resolveAudioURL(spaceId: targetKey)
            let session = SpaceViewerSession(id: targetKey, fileURL: url, audioURL: audioURL)

            targetEntryFOV = reduceMotion
                ? SpaceLinkTransitionMath.baseFOV
                : SpaceLinkTransitionMath.zoomFOV
            sourceOpacity = 1
            targetOpacity = 0
            targetReadyPending = false
            isCrossfading = true
            stack.append(session)

            // Wait until target SCNHost has configured texture (or timeout).
            let waitStart = CFAbsoluteTimeGetCurrent()
            await waitForTargetViewerReady(timeoutMs: 2_500)
            let waitMs = Int((CFAbsoluteTimeGetCurrent() - waitStart) * 1000)

            let crossDur = reduceMotion
                ? SpaceLinkTransitionMath.reduceMotionCrossfadeDuration
                : SpaceLinkTransitionMath.crossfadeDuration
            let crossStart = CFAbsoluteTimeGetCurrent()
            withAnimation(.easeInOut(duration: crossDur)) {
                sourceOpacity = 0
                targetOpacity = 1
            }
            try? await Task.sleep(nanoseconds: UInt64(crossDur * 1_000_000_000))
            let crossMs = Int((CFAbsoluteTimeGetCurrent() - crossStart) * 1000)

            isCrossfading = false
            sourceOpacity = 1
            targetOpacity = 1

            let settleStart = CFAbsoluteTimeGetCurrent()
            if let targetHost = SpaceLinkTransitionBridge.shared.activeHost,
               !reduceMotion {
                targetHost.setSpaceLinkTransitionLocked(true)
                targetHost.setFieldOfViewDegrees(SpaceLinkTransitionMath.zoomFOV)
                await targetHost.animateFieldOfView(
                    to: SpaceLinkTransitionMath.baseFOV,
                    duration: SpaceLinkTransitionMath.settleDuration,
                    easeOut: true
                )
                targetHost.setSpaceLinkTransitionLocked(false)
            } else {
                SpaceLinkTransitionBridge.shared.activeHost?.setFieldOfViewDegrees(
                    SpaceLinkTransitionMath.baseFOV
                )
                SpaceLinkTransitionBridge.shared.activeHost?.setSpaceLinkTransitionLocked(false)
            }
            let settleMs = Int((CFAbsoluteTimeGetCurrent() - settleStart) * 1000)

            targetEntryFOV = SpaceLinkTransitionMath.baseFOV
            suppressStackAudio = false
            await SpaceAudioManager.shared.playForSpace(spaceId: targetKey, preferredURL: audioURL)

            let totalMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            #if DEBUG
            print(
                "[spaceLink81] done source=\(sourceId) target=\(targetKey) preloadMs=\(preloadMs) alignMs=\(alignMs) waitReadyMs=\(waitMs) crossfadeMs=\(crossMs) settleMs=\(settleMs) totalMs=\(totalMs)"
            )
            #endif
            isTransitioning = false

        case .failure:
            #if DEBUG
            print("[spaceLink81] target load failure source=\(sourceId) target=\(targetKey) preloadMs=\(preloadMs)")
            #endif
            await sourceHost.restoreAfterFailedSpaceLinkTransition()
            isCrossfading = false
            targetEntryFOV = SpaceLinkTransitionMath.baseFOV
            suppressStackAudio = false
            isTransitioning = false
            navigateError = "공간을 불러오지 못했어요"
            await playAudioForTopOfStack()
        }
    }

    @MainActor
    private func waitForTargetViewerReady(timeoutMs: Int) async {
        if targetReadyPending {
            targetReadyPending = false
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            targetReadyWaiter = cont
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                if let waiter = targetReadyWaiter {
                    targetReadyWaiter = nil
                    waiter.resume()
                }
            }
        }
    }

    /// Animation infrastructure missing — keep prior short black dissolve, still navigate.
    @MainActor
    private func navigateWithBlackFallback(targetKey: String) async {
        withAnimation(.easeInOut(duration: 0.25)) {
            fadeOpacity = 1
        }
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
            suppressStackAudio = false
            await SpaceAudioManager.shared.playForSpace(spaceId: targetKey, preferredURL: audioURL)
            try? await Task.sleep(nanoseconds: 280_000_000)
            isTransitioning = false
        case .failure:
            withAnimation(.easeInOut(duration: 0.2)) {
                fadeOpacity = 0
            }
            suppressStackAudio = false
            isTransitioning = false
            navigateError = "공간을 불러오지 못했어요"
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
