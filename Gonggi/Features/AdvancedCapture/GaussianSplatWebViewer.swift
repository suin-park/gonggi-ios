import SwiftUI
import WebKit

/// Embeds 3D Locker SuperSplat viewer HTML for free navigation inside a completed Gaussian space.
///
/// Loading UX (build 70):
/// - Native overlay from the first frame with distinct phases:
///   공간 다운로드 중 → 공간 준비 중 → (hidden) 표시 완료, or 실패 + 다시 시도.
/// - The overlay hides only on bridge `render_ready`, which viewer-html sends after the package's
///   first valid frame with splats loaded and a readable camera — never on "download 100%".
/// - Stuck phases end in a reason-specific failure (no blind timer reloads).
/// - Recovery: WKWebView content-process termination, WebGL context loss that does not restore,
///   and a render loop that does not resume after foregrounding recreate the viewer at the last
///   camera. Automatic recovery is bounded (`GaussianViewerSession.maxAutoRecoveries`).
/// - One viewer per load token; retry is disabled while a load is running.
struct GaussianSplatWebViewer: View {
    let spaceId: String
    /// When true, shows Original / Cleaned PLY A/B (cleanupMode query). Default on for TF62 compare.
    var enableCleanupCompare: Bool = true
    var onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase

    @State private var showHint = true
    @State private var hasCollision = false
    @State private var navigationMode: GaussianNavMode = .fly
    @State private var cleanupMode: GaussianCleanupMode = .original
    @State private var webBridge: GaussianSplatWebBridge?
    @State private var reloadToken = 0
    /// Stable cache-bust — set once at State init (never `Date()` inside a computed URL).
    @State private var assetRev: String = String(Int(Date().timeIntervalSince1970))
    @State private var session = GaussianViewerSession()
    /// Last engine camera (viewer-y-up) captured while displayed — used to resume after recovery.
    @State private var lastCameraJSON: String?
    /// Camera frozen at the moment of a recovery reload (keeps the URL stable for that load).
    @State private var resumeCameraJSON: String?
    @State private var watchdogTask: Task<Void, Never>?
    @State private var cameraTask: Task<Void, Never>?
    @State private var contextRestoreTask: Task<Void, Never>?
    @State private var resumeCheckTask: Task<Void, Never>?
    @State private var navigationStarted = false
    @State private var telemetrySent = false
    @State private var closeRecorded = false
    /// Context lost while backgrounded: judge restoration only once the app is active again.
    @State private var pendingContextCheck: (wasReady: Bool, restoredBefore: Int)?

    private var viewerURL: URL {
        let root = AppConfiguration.production.apiBaseURL.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var components = URLComponents(string: "\(root)/api/gaussian-spaces/\(spaceId)/viewer-html")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "navigationMode", value: "fly"),
            URLQueryItem(name: "gamingControls", value: "1"),
            URLQueryItem(name: "mobileChrome", value: "1"),
            URLQueryItem(name: "assetRev", value: "\(assetRev)-\(reloadToken)"),
        ]
        if enableCleanupCompare, cleanupMode != .original {
            items.append(URLQueryItem(name: "cleanupMode", value: cleanupMode.rawValue))
        }
        // Resume at the last camera after a recovery (one-shot, never persisted server-side).
        if reloadToken > 0, let cam = resumeCameraJSON,
           let tcam = cam.data(using: .utf8)?.base64URLEncoded(), tcam.count <= 2048 {
            items.append(URLQueryItem(name: "tcam", value: tcam))
            items.append(URLQueryItem(name: "treq", value: "resume\(reloadToken)"))
        }
        components.queryItems = items
        return components.url!
    }

    private var isLoading: Bool {
        switch session.phase {
        case .ready: return false
        default: return true
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // WebView stays behind native chrome / loading overlay.
            GaussianSplatWebView(
                url: viewerURL,
                reloadToken: reloadToken,
                bridge: $webBridge,
                onCollisionDetected: { hasCollision = $0 },
                onTimeline: { event in
                    GaussianViewerLoadLog.mark(event, since: session.openedAt)
                },
                onBridgeEvent: { event in
                    handleBridgeEvent(event)
                }
            )
            .id("\(spaceId)-\(cleanupMode.rawValue)-\(reloadToken)")
            .ignoresSafeArea()

            if isLoading {
                nativeLoadingOverlay
                    .transition(.opacity)
                    .zIndex(50)
            }

            VStack(alignment: .trailing, spacing: 10) {
                Button {
                    finishSession()
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 4)
                        .padding(.trailing, 12)
                        .padding(.top, 8)
                }
                .accessibilityLabel("닫기")

                if enableCleanupCompare {
                    Picker("클린업", selection: $cleanupMode) {
                        Text("원본").tag(GaussianCleanupMode.original)
                        Text("Cleaned").tag(GaussianCleanupMode.cleaned)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .padding(.trailing, 12)
                    .onChange(of: cleanupMode) { _, _ in
                        reload(manual: true, reason: "cleanup_mode_changed")
                    }
                }

                if hasCollision, !isLoading {
                    Picker("이동 모드", selection: $navigationMode) {
                        Text("자유 이동").tag(GaussianNavMode.fly)
                        Text("걷기").tag(GaussianNavMode.walk)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .padding(.trailing, 12)
                    .onChange(of: navigationMode) { _, mode in
                        webBridge?.setNavigationMode(mode)
                    }
                    .onAppear {
                        if navigationMode != .walk {
                            navigationMode = .walk
                            webBridge?.setNavigationMode(.walk)
                        }
                    }
                }
            }
            .zIndex(60)

            if showHint, !isLoading {
                VStack {
                    Spacer()
                    Text(
                        hasCollision
                            ? "걷기/자유이동 전환 · 왼쪽 조이스틱 이동 · 드래그로 시점"
                            : enableCleanupCompare
                            ? "원본/Cleaned 전환 · 왼쪽 조이스틱 이동 · 드래그로 시점"
                            : "왼쪽 조이스틱으로 이동 · 화면을 드래그해 시점 변경"
                    )
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 36)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            session.log("open")
            GaussianViewerLoadLog.mark("ViewerView.onAppear space=\(spaceId)", since: session.openedAt)
            startWatchdog()
            // Navigation must start; if WebKit never begins the request, reload once (bounded).
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard !navigationStarted, !session.isPaused, session.phase == .connecting else { return }
                if session.requestRecovery(.navigationDidNotStart) {
                    reload(manual: false, reason: "navigation_did_not_start")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
                withAnimation(.easeOut(duration: 0.4)) { showHint = false }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            GaussianViewerLoadLog.mark("scenePhase=\(String(describing: phase))", since: session.openedAt)
            switch phase {
            case .background:
                session.pause()
                session.log("background")
            case .active:
                guard session.isPaused else { break }
                session.resume()
                session.log("foreground")
                if let pending = pendingContextCheck {
                    pendingContextCheck = nil
                    startContextRestoreCheck(wasReady: pending.wasReady, restoredBefore: pending.restoredBefore)
                }
                verifyRenderAfterForeground()
            default:
                break
            }
        }
        .onDisappear {
            finishSession()
            watchdogTask?.cancel()
            cameraTask?.cancel()
            contextRestoreTask?.cancel()
            resumeCheckTask?.cancel()
        }
    }

    // MARK: Overlay

    private var overlayTitle: String {
        switch session.phase {
        case .connecting: return "공간을 여는 중이에요"
        case .downloading: return "공간 다운로드 중"
        case .preparing: return "공간 준비 중"
        case .displaying: return "공간 준비 중"
        case .ready: return ""
        case .recovering: return "화면을 복구하고 있어요"
        case .failed(let f): return f.title
        }
    }

    private var overlaySubtitle: String? {
        switch session.phase {
        case .downloading(let percent):
            var parts: [String] = []
            if let percent { parts.append("\(percent)%") }
            if let total = session.bytesTotal, total > 0 {
                let mb = Double(total) / 1_048_576
                if let percent {
                    parts.append(String(format: "%.0f / %.0f MB", mb * Double(percent) / 100, mb))
                } else {
                    parts.append(String(format: "%.0f MB", mb))
                }
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .preparing: return "3D 데이터를 읽고 있어요"
        case .displaying: return "화면에 그릴 준비를 하고 있어요"
        case .recovering: return "마지막 위치에서 다시 열어요"
        case .failed(let f): return f.detail
        default: return nil
        }
    }

    private var nativeLoadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.92)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                if case .failed = session.phase {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.9))
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.15)
                }

                Text(overlayTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                if let sub = overlaySubtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                }

                if case .failed = session.phase {
                    Button {
                        reload(manual: true, reason: "retry_tapped")
                    } label: {
                        Text("다시 시도")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.white, in: Capsule())
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 28)
        }
        .allowsHitTesting(true)
    }

    // MARK: Load / recovery

    /// New document load. Old WKWebView is torn down by the `.id` change (dismantleUIView).
    private func reload(manual: Bool, reason: String) {
        // Retry only from a failure (or explicit mode change) — never stack loads.
        if manual, reason == "retry_tapped", !session.phase.isTerminalFailure { return }
        session.beginReload(manual: manual)
        session.log("reload", reason)
        resumeCameraJSON = lastCameraJSON
        if manual { telemetrySent = false }
        navigationStarted = false
        pendingContextCheck = nil
        hasCollision = false
        contextRestoreTask?.cancel()
        resumeCheckTask?.cancel()
        GaussianViewerLoadLog.mark("reload reason=\(reason) token=\(reloadToken + 1)", since: session.openedAt)
        reloadToken += 1
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let failure = session.watchdog() {
                    GaussianViewerLoadLog.mark("watchdog \(failure.code)", since: session.openedAt)
                    session.fail(failure)
                    sendTelemetryOnce()
                }
            }
        }
    }

    /// While displayed, remember the camera so a recovery reopens at the same place.
    private func startCameraTracking() {
        cameraTask?.cancel()
        cameraTask = Task { @MainActor in
            while !Task.isCancelled {
                if let cam = await webBridge?.readCameraJSON() { lastCameraJSON = cam }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func recover(_ reason: GaussianViewerRecoveryReason) {
        cameraTask?.cancel()
        if session.requestRecovery(reason) {
            reload(manual: false, reason: reason.rawValue)
        } else {
            sendTelemetryOnce()
        }
    }

    /// Displayed, or recovering from a loss after it was displayed.
    private var canVerifyFrame: Bool {
        session.phase == .ready || (session.phase.isRecovering && session.everDisplayed)
    }

    /// After returning from background: ask for one verified frame; recreate if it never comes.
    private func verifyRenderAfterForeground() {
        guard canVerifyFrame, let bridge = webBridge else { return }
        resumeCheckTask?.cancel()
        resumeCheckTask = Task { @MainActor in
            // Let WebKit resume the page first (the page also self-checks on visibilitychange).
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, canVerifyFrame else { return }
            let requested = await bridge.requestFrame(reason: "foreground")
            if !requested {
                // JS unreachable (content process gone). didTerminate normally fires too.
                recover(.webContentProcessTerminated)
            }
        }
    }

    private func handleBridgeEvent(_ event: GaussianViewerBridgeEvent) {
        switch event {
        case .timeline(let name):
            GaussianViewerLoadLog.mark(name, since: session.openedAt)
            if name.hasPrefix("didStartProvisionalNavigation") { navigationStarted = true }

        case .navigationCommitted:
            navigationStarted = true
            session.noteNavigationCommitted()

        case .shellLoaded:
            session.noteNavigationCommitted()
            session.noteBridgeMessage()

        case .loadStage(let stage, let profile):
            GaussianViewerLoadLog.mark("load_stage=\(stage)", since: session.openedAt)
            navigationStarted = true
            if let profile { mergeProfile(profile) }
            session.applyStage(stage)
            session.log("stage", stage)

        case .progress(let percent, let bytesTotal):
            navigationStarted = true
            if let bytesTotal { session.bytesTotal = bytesTotal }
            session.applyProgress(percent: percent)

        case .profile(let profile):
            mergeProfile(profile)

        case .ready:
            GaussianViewerLoadLog.mark("render_ready → hide native overlay", since: session.openedAt)
            let wasRecovering = session.phase.isRecovering
            withAnimation(.easeOut(duration: 0.25)) { session.markReady() }
            session.log(wasRecovering ? "recovered_ready" : "ready")
            startCameraTracking()
            sendTelemetryOnce()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                webBridge?.probeCollision()
            }

        case .error(let code):
            GaussianViewerLoadLog.mark("viewer_error code=\(code)", since: session.openedAt)
            session.log("error", code)
            guard session.phase != .ready else { return }
            if code.contains("WINDOW_ERROR") || code.contains("UNHANDLED_REJECTION") {
                // A script error is not proof the load failed: keep loading; the watchdog decides.
                session.noteSoftError(code)
                return
            }
            if code.contains("FETCH") || code.contains("CONTENT_HTTP") || code.hasPrefix("NAV_") {
                session.fail(.network)
            } else {
                session.fail(.viewNotReady(code: String(code.prefix(40))))
            }
            sendTelemetryOnce()

        case .jsError(let wasReady):
            session.noteJSError()
            session.log("js_error", wasReady ? "after_ready" : "before_ready")

        case .contextLost:
            session.log("webgl_context_lost")
            contextRestoreTask?.cancel()
            cameraTask?.cancel()
            let wasReady = session.phase == .ready
            if wasReady {
                // Visible black screen → show "복구 중" while PlayCanvas tries to restore.
                guard session.requestRecovery(.webGLContextLost) else {
                    sendTelemetryOnce()
                    return
                }
            }
            let restoredBefore = session.contextRestored
            if session.isPaused {
                // iOS drops GPU contexts of background pages; restoration happens on return.
                pendingContextCheck = (wasReady, restoredBefore)
            } else {
                startContextRestoreCheck(wasReady: wasReady, restoredBefore: restoredBefore)
            }

        case .contextRestored:
            session.noteContextRestored()
            session.log("webgl_context_restored")

        case .renderResumed(let reason):
            session.log("render_resumed", reason)
            resumeCheckTask?.cancel()
            if session.phase.isRecovering, session.everDisplayed {
                contextRestoreTask?.cancel()
                withAnimation { session.markReady() }
                startCameraTracking()
            }

        case .renderResumeFailed(let reason):
            session.log("render_resume_failed", reason)
            // Only a displayed (or recovering-after-display) viewer can stall; ignore during load
            // and while backgrounded (no frames are drawn then; foreground re-checks).
            guard !session.isPaused, session.everDisplayed, session.phase == .ready || session.phase.isRecovering else { return }
            recover(.renderStalledAfterResume)

        case .processTerminated:
            GaussianViewerLoadLog.mark("webContentProcessDidTerminate", since: session.openedAt)
            recover(.webContentProcessTerminated)
        }
    }

    /// Give PlayCanvas 5 s (foreground time) to restore the context before recreating the viewer.
    private func startContextRestoreCheck(wasReady: Bool, restoredBefore: Int) {
        contextRestoreTask?.cancel()
        contextRestoreTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, !session.isPaused, session.contextRestored == restoredBefore else { return }
            // Context never came back: recreate the viewer (at the last camera).
            if wasReady {
                if session.phase.isRecovering { reload(manual: false, reason: "webgl_context_not_restored") }
            } else if session.phase != .ready, !session.phase.isTerminalFailure {
                recover(.webGLContextLost)
            }
        }
    }

    private func mergeProfile(_ profile: [String: Any]) {
        for (k, v) in profile { session.profile[k] = v }
        if let total = profile["bytesTotal"] as? NSNumber { session.bytesTotal = total.int64Value }
    }

    private func sendTelemetryOnce() {
        guard !telemetrySent else { return }
        telemetrySent = true
        GaussianViewerTelemetryUploader.send(spaceId: spaceId, payload: session.telemetryPayload())
    }

    /// Final record on close (only if nothing terminal was sent, or recoveries happened later).
    private func finishSession() {
        guard !closeRecorded else { return }
        closeRecorded = true
        let recoveredLater = session.everDisplayed && (session.processTerminated + session.contextLost) > 0
        guard !telemetrySent || recoveredLater else { return }
        session.log("close")
        telemetrySent = true
        GaussianViewerTelemetryUploader.send(spaceId: spaceId, payload: session.telemetryPayload())
    }
}

// MARK: - Logging helpers

private enum GaussianViewerLoadLog {
    static func mark(_ event: String, since t0: Date) {
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("[GonggiViewerLoad +\(ms)ms] \(event)")
    }
}

private enum GaussianCleanupMode: String, Hashable {
    case original
    case cleaned
}

private enum GaussianNavMode: String, Hashable {
    case fly
    case walk
}

private enum GaussianViewerBridgeEvent {
    case timeline(String)
    case navigationCommitted
    case shellLoaded
    case loadStage(stage: String, profile: [String: Any]?)
    case progress(percent: Int, bytesTotal: Int64?)
    case profile([String: Any])
    case ready
    case error(code: String)
    case jsError(wasReady: Bool)
    case contextLost
    case contextRestored
    case renderResumed(reason: String)
    case renderResumeFailed(reason: String)
    case processTerminated
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
final class GaussianSplatWebBridge: NSObject {
    weak var webView: WKWebView?

    fileprivate func setNavigationMode(_ mode: GaussianNavMode) {
        let js = """
        (function(){
          var id = '\(mode == .walk ? "fpsCamera" : "flyCamera")';
          var btn = document.getElementById(id);
          if (btn && typeof btn.click === 'function') { try { btn.click(); } catch (e2) {} }
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Engine camera as JSON (viewer-y-up camera_state payload), or nil.
    func readCameraJSON() async -> String? {
        guard let webView else { return nil }
        let js = "(function(){ try { var c = window.__gonggiViewer && window.__gonggiViewer.readCamera(); return c ? JSON.stringify(c) : null; } catch (e) { return null; } })();"
        return await withCheckedContinuation { cont in
            webView.evaluateJavaScript(js) { result, _ in
                cont.resume(returning: result as? String)
            }
        }
    }

    /// Request one verified frame; false when the page's JS is unreachable.
    func requestFrame(reason: String) async -> Bool {
        guard let webView else { return false }
        let safe = reason.filter { $0.isLetter || $0 == "_" }
        let js = "(function(){ try { return !!(window.__gonggiViewer && window.__gonggiViewer.requestFrame('\(safe)')); } catch (e) { return false; } })();"
        return await withCheckedContinuation { cont in
            webView.evaluateJavaScript(js) { result, error in
                cont.resume(returning: error == nil && (result as? Bool) == true)
            }
        }
    }

    func probeCollision() {
        let js = """
        (function(){
          var has = false;
          try {
            var fps = document.getElementById('fpsCamera');
            has = !!(fps && !fps.classList.contains('hidden') && fps.offsetParent !== null);
          } catch (e) {}
          return has;
        })();
        """
        webView?.evaluateJavaScript(js) { [weak self] result, _ in
            Task { @MainActor in
                if let has = result as? Bool {
                    NotificationCenter.default.post(
                        name: .gaussianViewerCollisionProbed,
                        object: self,
                        userInfo: ["hasCollision": has]
                    )
                }
            }
        }
    }
}

private extension Notification.Name {
    static let gaussianViewerCollisionProbed = Notification.Name("gaussianViewerCollisionProbed")
}

private struct GaussianSplatWebView: UIViewRepresentable {
    let url: URL
    var reloadToken: Int = 0
    @Binding var bridge: GaussianSplatWebBridge?
    var onCollisionDetected: (Bool) -> Void
    var onTimeline: (String) -> Void
    var onBridgeEvent: (GaussianViewerBridgeEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onCollisionDetected: onCollisionDetected,
            onTimeline: onTimeline,
            onBridgeEvent: onBridgeEvent
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.onTimeline("WKWebView.created token=\(reloadToken)")

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        if #available(iOS 14.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        // Weak proxy: the content controller must not retain the coordinator (released on close).
        config.userContentController.add(WeakScriptMessageHandler(context.coordinator), name: "gonggiViewer")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = context.coordinator
        #if DEBUG
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        #endif

        let owned = GaussianSplatWebBridge()
        owned.webView = webView
        context.coordinator.bridge = owned
        DispatchQueue.main.async { bridge = owned }

        // Defer first load until after fullScreenCover layout — avoids blank WKWebView
        // that only starts after app background/foreground.
        context.coordinator.lastLoadedURL = url
        context.coordinator.lastReloadToken = reloadToken
        DispatchQueue.main.async {
            self.load(url, into: webView, coordinator: context.coordinator)
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.onCollisionDetected = onCollisionDetected
        context.coordinator.onTimeline = onTimeline
        context.coordinator.onBridgeEvent = onBridgeEvent
        // Loads happen only in makeUIView: every reload / mode change is a new `.id` (one viewer
        // per load, old one dismantled) — never a second in-place load into the same page.
    }

    /// Release the page (PLY buffers, WebGL context) as soon as the viewer leaves.
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.onTimeline("WKWebView.dismantled")
        coordinator.isDismantled = true
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "gonggiViewer")
        uiView.loadHTMLString("", baseURL: nil)
    }

    private func load(_ url: URL, into webView: WKWebView, coordinator: Coordinator) {
        guard !coordinator.isDismantled else { return }
        // Path only — never log the query (tcam) or the bearer token.
        coordinator.onTimeline("load_request_started \(url.path)")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        if let token = MobileAuthTokenStore.shared.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        webView.load(request)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var bridge: GaussianSplatWebBridge?
        var onCollisionDetected: (Bool) -> Void
        var onTimeline: (String) -> Void
        var onBridgeEvent: (GaussianViewerBridgeEvent) -> Void
        var lastLoadedURL: URL?
        var lastReloadToken: Int = -1
        var isDismantled = false
        private var observer: NSObjectProtocol?

        init(
            onCollisionDetected: @escaping (Bool) -> Void,
            onTimeline: @escaping (String) -> Void,
            onBridgeEvent: @escaping (GaussianViewerBridgeEvent) -> Void
        ) {
            self.onCollisionDetected = onCollisionDetected
            self.onTimeline = onTimeline
            self.onBridgeEvent = onBridgeEvent
            super.init()
            observer = NotificationCenter.default.addObserver(
                forName: .gaussianViewerCollisionProbed,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self,
                      let bridge = note.object as? GaussianSplatWebBridge,
                      bridge === self.bridge,
                      let has = note.userInfo?["hasCollision"] as? Bool
                else { return }
                self.onCollisionDetected(has)
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard !isDismantled, message.name == "gonggiViewer" else { return }
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String
            else { return }
            let profile = body["profile"] as? [String: Any]

            switch type {
            case "load_stage":
                let stage = (body["stage"] as? String) ?? "unknown"
                onBridgeEvent(.loadStage(stage: stage, profile: profile))
            case "content_download_progress":
                let pct = (body["percent"] as? NSNumber)?.intValue ?? 0
                let total = (body["bytesTotal"] as? NSNumber)?.int64Value
                onBridgeEvent(.progress(percent: pct, bytesTotal: total))
            case "load_profile":
                if let profile { onBridgeEvent(.profile(profile)) }
            case "render_ready":
                onTimeline("render_ready")
                onBridgeEvent(.ready)
            case "content_request_started":
                onTimeline("PLY_download_start")
            case "content_downloaded":
                onTimeline("PLY_download_end")
            case "content_fetch_failed", "render_failed":
                if let profile { onBridgeEvent(.profile(profile)) }
                onBridgeEvent(.error(code: (body["errorCode"] as? String) ?? type))
            case "viewer_error":
                let code = (body["errorCode"] as? String) ?? "VIEWER_ERROR"
                onTimeline("viewer_error_soft \(code)")
            case "js_error":
                onBridgeEvent(.jsError(wasReady: (body["wasReady"] as? Bool) ?? false))
            case "webgl_context_lost":
                onBridgeEvent(.contextLost)
            case "webgl_context_restored":
                onBridgeEvent(.contextRestored)
            case "render_resumed":
                onBridgeEvent(.renderResumed(reason: (body["reason"] as? String) ?? ""))
            case "render_resume_failed":
                onBridgeEvent(.renderResumeFailed(reason: (body["errorCode"] as? String) ?? ""))
            case "page_visibility":
                onTimeline("page_visibility \((body["state"] as? String) ?? "")")
            case "viewer_shell_loaded":
                onTimeline("JS_initialized viewer_shell_loaded")
                onBridgeEvent(.shellLoaded)
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onBridgeEvent(.timeline("didStartProvisionalNavigation"))
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            onTimeline("didCommitNavigation (HTML first content)")
            onBridgeEvent(.navigationCommitted)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onTimeline("didFinishNavigation")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.bridge?.probeCollision()
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            onTimeline("didFailProvisionalNavigation code=\((error as NSError).code)")
            onBridgeEvent(.error(code: "NAV_PROVISIONAL_FAILED"))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onTimeline("didFailNavigation code=\((error as NSError).code)")
            onBridgeEvent(.error(code: "NAV_FAILED"))
        }

        /// WebContent process crashed / was killed (e.g. memory pressure) → black page.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard !isDismantled else { return }
            onBridgeEvent(.processTerminated)
        }
    }
}

/// Breaks the WKUserContentController → handler retain so the viewer can deallocate.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}
