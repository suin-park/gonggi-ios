import SwiftUI
import UIKit

/// Multi-space VR cover host — A→B→C via Navigation-style stack (Build 72).
/// Build 80 — owns space-audio fade transitions across stack changes.
/// Build 81 — production rotate + FOV zoom + dual-view crossfade (no camera push).
/// Build 82 — hitch forensic + predecode/prewarm + deferred source teardown (visual lock).
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
    /// Build 82 — keep source SCNView alive (opacity 0) briefly after crossfade to avoid teardown hitch.
    @State private var deferSourceHold = false
    @State private var sourceOpacity: Double = 1
    @State private var targetOpacity: Double = 1
    @State private var targetEntryFOV: Double = SpaceLinkTransitionMath.baseFOV
    @State private var suppressStackAudio = false
    @State private var targetReadyWaiter: CheckedContinuation<Void, Never>?
    @State private var targetReadyPending = false
    @State private var sourceHoldTask: Task<Void, Never>?

    var onClose: () -> Void
    var onStackCountChange: ((Int) -> Void)?

    init(
        sessions: [SpaceViewerSession],
        onClose: @escaping () -> Void,
        onStackCountChange: ((Int) -> Void)? = nil
    ) {
        _stack = State(initialValue: sessions.isEmpty ? [] : sessions)
        self.onClose = onClose
        self.onStackCountChange = onStackCountChange
    }

    init(
        root: SpaceViewerSession,
        onClose: @escaping () -> Void,
        onStackCountChange: ((Int) -> Void)? = nil
    ) {
        _stack = State(initialValue: [root])
        self.onClose = onClose
        self.onStackCountChange = onStackCountChange
    }

    private var renderSessions: [SpaceViewerSession] {
        guard let last = stack.last else { return [] }
        if (isCrossfading || deferSourceHold), stack.count >= 2 {
            return Array(stack.suffix(2))
        }
        return [last]
    }

    var body: some View {
        ZStack {
            ForEach(renderSessions) { session in
                let isTop = session.id == stack.last?.id
                let isSourceDuringCrossfade = (isCrossfading || deferSourceHold) && !isTop
                VRSphereSpaceView(
                    imageURL: session.fileURL,
                    videoURL: session.videoURL,
                    sessionId: session.id,
                    preferredAudioURL: session.allowsOwnerControls ? session.audioURL : nil,
                    suppressAutoAudio: suppressStackAudio || isCrossfading || deferSourceHold || !session.allowsOwnerControls,
                    initialFieldOfView: isTop ? targetEntryFOV : SpaceLinkTransitionMath.baseFOV,
                    spaceLinkTransitionLocked: isTransitioning,
                    transitionBridgeRole: isSourceDuringCrossfade ? .overlay : .primary,
                    deferSecondaryLoads: isTop && (isCrossfading || isTransitioning),
                    startInEditMode: session.allowsOwnerControls && session.startInEditMode && isTop && !isCrossfading,
                    allowsOwnerControls: session.allowsOwnerControls,
                    publicOverlay: session.publicOverlay,
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
                            SpaceLink82Timing.log("targetFirstFrameReady")
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
            sourceHoldTask?.cancel()
            Task { await SpaceAudioManager.shared.fadeOutAndStop() }
        }
        .onChange(of: appState.forceDismissViewerEpoch) { _, _ in
            // Root exit / account reset — drop hotspot stack without stepwise pop animation.
            sourceHoldTask?.cancel()
            sourceHoldTask = nil
            isTransitioning = false
            isCrossfading = false
            deferSourceHold = false
            stack.removeAll()
            Task { await SpaceAudioManager.shared.fadeOutAndStop() }
        }
        .onChange(of: stack.count) { _, count in
            onStackCountChange?(count)
        }
        .onAppear {
            onStackCountChange?(stack.count)
        }
    }

    private func opacity(for session: SpaceViewerSession, isTop: Bool) -> Double {
        if deferSourceHold, !isTop { return 0 }
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

        if targetKey.hasPrefix("public:") || targetKey.hasPrefix("share:") {
            await navigatePublicOrShare(targetKey: targetKey, link: link)
            return
        }

        let reduceMotion = reduceMotionEnv || UIAccessibility.isReduceMotionEnabled
        let sourceId = stack.last?.id ?? "?"
        isTransitioning = true
        suppressStackAudio = true
        sourceHoldTask?.cancel()
        deferSourceHold = false

        let sourceHost = SpaceLinkTransitionBridge.shared.activeHost
        guard let sourceHost else {
            SpaceLink82Timing.log("fallback", ["reason": "no_active_host"])
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

        SpaceLink82Timing.log("begin", [
            "source": sourceId,
            "target": targetKey,
            "yawDelta": String(format: "%.1f", yawDelta),
            "pitchDelta": String(format: "%.1f", pitchDelta),
            "reduceMotion": reduceMotion
        ])

        async let audioFade: Void = SpaceAudioManager.shared.fadeOutAndStop(
            duration: SpaceAudioPolicy.fadeOutSeconds
        )

        let alignStart = CFAbsoluteTimeGetCurrent()
        let presentationFOV = sourceHost.currentFieldOfViewDegrees()
        let zoomTarget = reduceMotion
            ? presentationFOV
            : VRViewingFOVMath.transitionZoomTarget(fromCurrent: presentationFOV)
        SpaceLink82Timing.log("transitionFOV", [
            "presentation": String(format: "%.1f", presentationFOV),
            "zoomTarget": String(format: "%.1f", zoomTarget)
        ])
        async let alignZoom: Void = sourceHost.runAlignAndZoom(
            targetYawDeg: link.yawDeg,
            targetPitchDeg: link.pitchDeg,
            targetFOV: zoomTarget,
            reduceMotion: reduceMotion
        )

        let resolveStart = CFAbsoluteTimeGetCurrent()
        SpaceLink82Timing.log("urlResolve start")
        let result = await appState.prepareSpaceViewer(jobId: targetKey)
        let resolveMs = SpaceLink82Timing.ms(since: resolveStart)
        SpaceLink82Timing.log("urlResolve end", ["ms": resolveMs])

        await alignZoom
        let alignMs = SpaceLink82Timing.ms(since: alignStart)
        _ = await audioFade

        switch result {
        case .success(let url):
            // Build 82 — background force-decode before SCNHost create / crossfade.
            let decodeStart = CFAbsoluteTimeGetCurrent()
            let decoded = await SpaceLinkPanoramaTextureCache.shared.predecode(url: url)
            let decodeMs = SpaceLink82Timing.ms(since: decodeStart)
            SpaceLink82Timing.log("predecodeGate", [
                "ms": decodeMs,
                "ok": decoded != nil
            ])

            let audioResolveStart = CFAbsoluteTimeGetCurrent()
            let audioURL = await SpaceAudioManager.shared.resolveAudioURL(spaceId: targetKey)
            SpaceLink82Timing.log("audioResolve", ["ms": SpaceLink82Timing.ms(since: audioResolveStart)])

            let session = SpaceViewerSession(
                id: targetKey,
                fileURL: url,
                audioURL: audioURL,
                videoURL: AppState.preferredVideoURL(for: targetKey)
            )

            targetEntryFOV = zoomTarget
            sourceOpacity = 1
            targetOpacity = 0
            targetReadyPending = false
            SpaceLink82Timing.log("stackAppend")
            isCrossfading = true
            stack.append(session)

            let waitStart = CFAbsoluteTimeGetCurrent()
            await waitForTargetViewerReady(timeoutMs: 3_500)
            let waitMs = SpaceLink82Timing.ms(since: waitStart)
            SpaceLink82Timing.log("waitFirstFrame", ["ms": waitMs])

            let crossDur = reduceMotion
                ? SpaceLinkTransitionMath.reduceMotionCrossfadeDuration
                : SpaceLinkTransitionMath.crossfadeDuration
            let crossStart = CFAbsoluteTimeGetCurrent()
            withAnimation(.easeInOut(duration: crossDur)) {
                sourceOpacity = 0
                targetOpacity = 1
            }
            try? await Task.sleep(nanoseconds: UInt64(crossDur * 1_000_000_000))
            let crossMs = SpaceLink82Timing.ms(since: crossStart)
            SpaceLink82Timing.log("crossfadeComplete", ["ms": crossMs])

            // Keep source SCN alive (opacity 0) while target settles — avoid ARC/teardown hitch.
            deferSourceHold = true
            isCrossfading = false
            sourceOpacity = 1
            targetOpacity = 1

            let settleStart = CFAbsoluteTimeGetCurrent()
            let settleFOV = VRViewingFOVMath.defaultFOV
            if let targetHost = SpaceLinkTransitionBridge.shared.activeHost {
                targetHost.setSpaceLinkTransitionLocked(true)
                if !reduceMotion {
                    targetHost.applyPresentationFOV(zoomTarget)
                    await targetHost.animateFieldOfView(
                        to: settleFOV,
                        duration: SpaceLinkTransitionMath.settleDuration,
                        easeOut: true
                    )
                } else {
                    targetHost.applyPresentationFOV(settleFOV)
                }
                targetHost.commitUserViewingFOV(settleFOV)
                // Visual stable → next tick → re-anchor / resume motion.
                await Task.yield()
                SpaceLink82Timing.log("motionResume start")
                targetHost.setSpaceLinkTransitionLocked(false)
                SpaceLink82Timing.log("motionResume end")
            }
            let settleMs = SpaceLink82Timing.ms(since: settleStart)

            targetEntryFOV = VRViewingFOVMath.defaultFOV
            suppressStackAudio = false
            isTransitioning = false
            SpaceLink82Timing.log("interactionReady")

            // Audio must not block interaction; slight delay keeps AVAudioSession off settle frame.
            let playTarget = targetKey
            let playURL = audioURL
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                let audioStart = CFAbsoluteTimeGetCurrent()
                SpaceLink82Timing.log("audioPrepare start")
                await SpaceAudioManager.shared.playForSpace(spaceId: playTarget, preferredURL: playURL)
                SpaceLink82Timing.log("audioPrepare end", ["ms": SpaceLink82Timing.ms(since: audioStart)])
            }

            scheduleDeferredSourceRelease()

            let totalMs = SpaceLink82Timing.ms(since: t0)
            SpaceLink82Timing.log("done", [
                "resolveMs": resolveMs,
                "decodeMs": decodeMs,
                "alignMs": alignMs,
                "waitReadyMs": waitMs,
                "crossfadeMs": crossMs,
                "settleMs": settleMs,
                "totalMs": totalMs
            ])

        case .failure:
            SpaceLink82Timing.log("targetLoadFailure", ["resolveMs": resolveMs])
            await sourceHost.restoreAfterFailedSpaceLinkTransition()
            isCrossfading = false
            deferSourceHold = false
            targetEntryFOV = VRViewingFOVMath.defaultFOV
            suppressStackAudio = false
            isTransitioning = false
            navigateError = "공간을 불러오지 못했어요"
            await playAudioForTopOfStack()
        }
    }

    @MainActor
    private func scheduleDeferredSourceRelease() {
        sourceHoldTask?.cancel()
        let cleanupStart = CFAbsoluteTimeGetCurrent()
        sourceHoldTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            SpaceLink82Timing.log("sourceCleanup start")
            deferSourceHold = false
            SpaceLink82Timing.log("sourceCleanup end", [
                "holdMs": SpaceLink82Timing.ms(since: cleanupStart)
            ])
            SpaceLink82Timing.log("stableInteraction")
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
                    SpaceLink82Timing.log("waitFirstFrame timeout")
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
            _ = await SpaceLinkPanoramaTextureCache.shared.predecode(url: url)
            let audioURL = await SpaceAudioManager.shared.resolveAudioURL(spaceId: targetKey)
            let session = SpaceViewerSession(
                id: targetKey,
                fileURL: url,
                audioURL: audioURL,
                videoURL: AppState.preferredVideoURL(for: targetKey)
            )
            stack.append(session)
            withAnimation(.easeInOut(duration: 0.28)) {
                fadeOpacity = 0
            }
            suppressStackAudio = false
            isTransitioning = false
            Task {
                await SpaceAudioManager.shared.playForSpace(spaceId: targetKey, preferredURL: audioURL)
            }
            try? await Task.sleep(nanoseconds: 280_000_000)
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
    private func navigatePublicOrShare(targetKey: String, link: SpaceLink) async {
        isTransitioning = true
        suppressStackAudio = true
        defer {
            suppressStackAudio = false
            isTransitioning = false
        }

        let api = MobilePublicSpacesAPIClient()
        do {
            if targetKey.hasPrefix("public:") {
                let slug = String(targetKey.dropFirst("public:".count))
                let detail = try await api.getPublicSpace(accessToken: MobileAuthTokenStore.shared.getAccessToken(), slug: slug)
                let file = try await api.downloadPanorama(
                    accessToken: MobileAuthTokenStore.shared.getAccessToken(),
                    panoramaUrl: detail.panoramaUrl,
                    cacheKey: "public-\(slug)"
                )
                _ = await SpaceLinkPanoramaTextureCache.shared.predecode(url: file)
                let overlay = PublicViewerOverlay(detail: detail, apiBaseURL: await api.apiBaseURL)
                let session = SpaceViewerSession(
                    id: "public:\(slug)",
                    fileURL: file,
                    audioURL: nil,
                    startInEditMode: false,
                    allowsOwnerControls: false,
                    publicOverlay: overlay
                )
                targetEntryFOV = SpaceLinkTransitionMath.baseFOV
                stack.append(session)
                return
            }

            if targetKey.hasPrefix("share:") {
                let token = String(targetKey.dropFirst("share:".count))
                let detail = try await api.getShareSpace(token: token)
                let file = try await api.downloadPanorama(
                    accessToken: nil,
                    panoramaUrl: detail.panoramaUrl,
                    cacheKey: "share-\(token)"
                )
                _ = await SpaceLinkPanoramaTextureCache.shared.predecode(url: file)
                // Share path: hotspots without cross-space public overlay (existing share semantics).
                let session = SpaceViewerSession(
                    id: "share:\(token)",
                    fileURL: file,
                    audioURL: nil,
                    startInEditMode: false,
                    allowsOwnerControls: false,
                    publicOverlay: nil
                )
                targetEntryFOV = SpaceLinkTransitionMath.baseFOV
                stack.append(session)
                return
            }
            navigateError = "연결할 공간을 찾을 수 없어요"
        } catch {
            navigateError = "공간을 불러오지 못했어요"
            _ = link
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
