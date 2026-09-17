import SwiftUI
import WebKit

/// Embeds 3D Locker SuperSplat viewer HTML for free navigation inside a completed Gaussian space.
///
/// Loading UX is driven by a **native** overlay (not HTML-only):
/// - Shows immediately on entry (`isLoading = true`) so WKWebView black never owns the screen.
/// - Stage copy updates from `gonggiViewer` bridge messages when available.
/// - Dismisses only on `render_ready` (or explicit retry after hard error).
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

    /// Native loading gate — true from first frame; never waits for WKWebView/JS.
    @State private var isLoading = true
    @State private var loadMessage = GaussianViewerLoadCopy.defaultMessage
    @State private var loadSubMessage: String? = nil
    @State private var loadFailed = false
    @State private var slowLoadHintShown = false
    @State private var appearAt = Date()
    @State private var slowLoadTask: Task<Void, Never>?
    @State private var didReceiveLoadStage = false
    @State private var resumeReloadArmed = false

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
        components.queryItems = items
        return components.url!
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
                    GaussianViewerLoadLog.mark(event, since: appearAt)
                },
                onBridgeEvent: { event in
                    handleBridgeEvent(event)
                }
            )
            .id("\(spaceId)-\(cleanupMode.rawValue)-\(reloadToken)")
            .ignoresSafeArea()

            if isLoading || loadFailed {
                nativeLoadingOverlay
                    .transition(.opacity)
                    .zIndex(50)
            }

            VStack(alignment: .trailing, spacing: 10) {
                Button {
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
                        beginLoadCycle(reason: "cleanup_mode_changed")
                    }
                }

                if hasCollision, !isLoading, !loadFailed {
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

            if showHint, !isLoading, !loadFailed {
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
            appearAt = Date()
            GaussianViewerLoadLog.mark("ViewerView.onAppear isLoading=\(isLoading)", since: appearAt)
            beginLoadCycle(reason: "onAppear")
            // first-entry WebKit stall: if no bridge stage after layout, nudge once.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                guard isLoading, !loadFailed, !didReceiveLoadStage, !resumeReloadArmed else { return }
                resumeReloadArmed = true
                GaussianViewerLoadLog.mark("first_entry_nudge_reload", since: appearAt)
                beginLoadCycle(reason: "first_entry_stall")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
                withAnimation(.easeOut(duration: 0.4)) { showHint = false }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            GaussianViewerLoadLog.mark("scenePhase=\(String(describing: phase))", since: appearAt)
            // Background→foreground often unsticks WebKit; force one reload if still silent.
            if phase == .active, isLoading, !loadFailed, !didReceiveLoadStage {
                GaussianViewerLoadLog.mark("resume_nudge_reload", since: appearAt)
                beginLoadCycle(reason: "scene_active_stall")
            }
        }
        .onDisappear {
            slowLoadTask?.cancel()
            slowLoadTask = nil
        }
    }

    private var nativeLoadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.92)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                if !loadFailed {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.15)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.9))
                }

                Text(loadMessage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                if let sub = loadSubMessage, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                }

                if loadFailed {
                    Button {
                        beginLoadCycle(reason: "retry_tapped")
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

    private func beginLoadCycle(reason: String) {
        slowLoadTask?.cancel()
        isLoading = true
        loadFailed = false
        loadMessage = GaussianViewerLoadCopy.defaultMessage
        loadSubMessage = nil
        slowLoadHintShown = false
        hasCollision = false
        didReceiveLoadStage = false
        GaussianViewerLoadLog.mark("beginLoadCycle reason=\(reason)", since: appearAt)

        // Always bump token except the very first onAppear (WebView makeUIView already loads).
        // Stall / retry / mode change must reload.
        if reason != "onAppear" {
            reloadToken += 1
        }

        slowLoadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, isLoading, !loadFailed else { return }
            if !didReceiveLoadStage {
                // Still no bridge traffic — force a reload once.
                GaussianViewerLoadLog.mark("stall_12s_force_reload", since: appearAt)
                loadMessage = GaussianViewerLoadCopy.slowMessage
                reloadToken += 1
                didReceiveLoadStage = false
            } else if !slowLoadHintShown {
                slowLoadHintShown = true
                loadMessage = GaussianViewerLoadCopy.slowMessage
                GaussianViewerLoadLog.mark("slow_load_hint", since: appearAt)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if !isLoading { webBridge?.probeCollision() }
        }
    }

    private func handleBridgeEvent(_ event: GaussianViewerBridgeEvent) {
        switch event {
        case .timeline(let name):
            GaussianViewerLoadLog.mark(name, since: appearAt)

        case .loadStage(let stage, let label, let sub):
            GaussianViewerLoadLog.mark("load_stage=\(stage)", since: appearAt)
            didReceiveLoadStage = true
            resumeReloadArmed = false
            guard isLoading, !loadFailed else { return }
            loadMessage = GaussianViewerLoadCopy.message(forStage: stage, fallbackLabel: label)
            if let sub, !sub.isEmpty {
                loadSubMessage = sub
            }

        case .ready:
            GaussianViewerLoadLog.mark("render_ready → hide native overlay", since: appearAt)
            didReceiveLoadStage = true
            resumeReloadArmed = false
            slowLoadTask?.cancel()
            withAnimation(.easeOut(duration: 0.25)) {
                isLoading = false
                loadFailed = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                webBridge?.probeCollision()
            }

        case .error(let code):
            GaussianViewerLoadLog.mark("viewer_error code=\(code)", since: appearAt)
            if GaussianViewerLoadCopy.isHardFailure(code) {
                slowLoadTask?.cancel()
                loadFailed = true
                isLoading = true
                loadMessage = GaussianViewerLoadCopy.failedMessage
                loadSubMessage = nil
            }
        }
    }
}

// MARK: - Copy / logging helpers

private enum GaussianViewerLoadCopy {
    static let defaultMessage = "공간을 불러오고 있어요"
    static let slowMessage = "공간을 불러오는 데 시간이 걸리고 있어요"
    static let failedMessage = "공간을 불러오지 못했어요"

    static func message(forStage stage: String, fallbackLabel: String?) -> String {
        let s = stage.lowercased()
        if let fallbackLabel, !fallbackLabel.isEmpty,
           s == "boot" || s == "error" {
            return fallbackLabel
        }
        if s.contains("download") || s == "content_request" {
            return "공간 데이터를 불러오고 있어요"
        }
        if s.contains("pars") || s.contains("prepar") {
            return "3D 데이터를 준비하고 있어요"
        }
        if s.contains("display") || s.contains("gpu") || s.contains("upload") || s.contains("render") {
            return "공간을 표시하고 있어요"
        }
        if s == "error" {
            return failedMessage
        }
        return fallbackLabel?.isEmpty == false ? fallbackLabel! : defaultMessage
    }

    static func isHardFailure(_ code: String) -> Bool {
        let c = code.uppercased()
        if c.contains("FETCH_FAILED") { return true }
        if c.contains("CONTENT_HTTP") { return true }
        if c.contains("CONTENT_FETCH") { return true }
        if c.contains("WEBGL_CONTEXT_LOST") { return true }
        if c.contains("GAUSSIAN_VIEWER_WINDOW_ERROR") { return true }
        if c.contains("NAV_PROVISIONAL_FAILED") { return true }
        if c.contains("NAV_FAILED") { return true }
        if c.contains("PLY") && c.contains("FAIL") { return true }
        return false
    }
}

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
    case loadStage(stage: String, label: String?, sub: String?)
    case ready
    case error(code: String)
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
        context.coordinator.onTimeline("WKWebView.created")
        context.coordinator.onBridgeEvent(.timeline("message_handler_ready gonggiViewer"))

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        if #available(iOS 14.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        let contentController = config.userContentController
        contentController.add(context.coordinator, name: "gonggiViewer")
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
        let urlChanged = context.coordinator.lastLoadedURL != url
        let tokenChanged = context.coordinator.lastReloadToken != reloadToken
        if urlChanged || tokenChanged {
            context.coordinator.lastLoadedURL = url
            context.coordinator.lastReloadToken = reloadToken
            context.coordinator.didReceiveFirstStage = false
            // Slight defer so SwiftUI finishes the current update pass.
            DispatchQueue.main.async {
                self.load(url, into: uiView, coordinator: context.coordinator)
            }
        }
    }

    private func load(_ url: URL, into webView: WKWebView, coordinator: Coordinator) {
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
        var didReceiveFirstStage = false
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
            guard message.name == "gonggiViewer" else { return }
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String
            else { return }

            switch type {
            case "load_stage":
                let stage = (body["stage"] as? String) ?? "unknown"
                let label = body["label"] as? String
                var sub: String?
                if let profile = body["profile"] as? [String: Any] {
                    var parts: [String] = []
                    if let bytes = profile["downloadedBytes"] as? Double, bytes > 0 {
                        parts.append(String(format: "%.1f MB", bytes / (1024 * 1024)))
                    } else if let bytes = profile["downloadedBytes"] as? Int, bytes > 0 {
                        parts.append(String(format: "%.1f MB", Double(bytes) / (1024 * 1024)))
                    }
                    if let elapsed = profile["elapsedMs"] as? Double {
                        parts.append(String(format: "%.0fs", elapsed / 1000))
                    } else if let elapsed = profile["elapsedMs"] as? Int {
                        parts.append("\(elapsed / 1000)s")
                    }
                    if !parts.isEmpty { sub = parts.joined(separator: " · ") }
                }
                if !didReceiveFirstStage {
                    didReceiveFirstStage = true
                    onTimeline("first_loading_stage_message stage=\(stage)")
                }
                onBridgeEvent(.loadStage(stage: stage, label: label, sub: sub))

            case "render_ready":
                onTimeline("render_ready")
                onBridgeEvent(.ready)

            case "content_request_started":
                onTimeline("PLY_download_start")
                onBridgeEvent(.loadStage(stage: "downloading", label: nil, sub: nil))

            case "content_downloaded":
                onTimeline("PLY_download_end")

            case "content_parsing":
                onTimeline("parse_start")
                onBridgeEvent(.loadStage(stage: "preparing", label: nil, sub: nil))

            case "content_fetch_failed", "render_failed":
                let code = (body["errorCode"] as? String) ?? type
                onBridgeEvent(.error(code: code))

            case "viewer_error":
                let code = (body["errorCode"] as? String) ?? "VIEWER_ERROR"
                if code == "CAMERA_NOT_READY" || code == "CAMERA_ENTITY_UNAVAILABLE" {
                    onTimeline("viewer_error_soft \(code)")
                } else {
                    onBridgeEvent(.error(code: code))
                }

            case "viewer_shell_loaded":
                onTimeline("JS_initialized viewer_shell_loaded")
                onBridgeEvent(.loadStage(stage: "boot", label: "공간을 준비하고 있어요", sub: nil))

            default:
                #if DEBUG
                print("[gonggiViewer] \(type)")
                #endif
                break
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onTimeline("didStartProvisionalNavigation")
            onBridgeEvent(.loadStage(stage: "boot", label: "공간을 불러오고 있어요", sub: nil))
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            onTimeline("didCommitNavigation (HTML first content)")
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
            onTimeline("didFailProvisionalNavigation \(error.localizedDescription)")
            onBridgeEvent(.error(code: "NAV_PROVISIONAL_FAILED"))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onTimeline("didFailNavigation \(error.localizedDescription)")
            onBridgeEvent(.error(code: "NAV_FAILED"))
        }
    }
}
