import SwiftUI
import WebKit

/// Embeds 3D Locker SuperSplat viewer HTML for free navigation inside a completed Gaussian space.
struct GaussianSplatWebViewer: View {
    let spaceId: String
    var onClose: () -> Void

    @State private var showHint = true
    @State private var hasCollision = false
    @State private var navigationMode: GaussianNavMode = .fly
    @State private var webBridge: GaussianSplatWebBridge?

    private var viewerURL: URL {
        let root = AppConfiguration.production.apiBaseURL.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // P0: force Fly + gamingControls (virtual joystick) + Korean hint chrome.
        var components = URLComponents(string: "\(root)/api/gaussian-spaces/\(spaceId)/viewer-html")!
        components.queryItems = [
            URLQueryItem(name: "navigationMode", value: "fly"),
            URLQueryItem(name: "gamingControls", value: "1"),
            URLQueryItem(name: "mobileChrome", value: "1"),
        ]
        return components.url!
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GaussianSplatWebView(
                url: viewerURL,
                bridge: $webBridge,
                onCollisionDetected: { hasCollision = $0 }
            )
            .ignoresSafeArea()

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

                if hasCollision {
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
                }
            }

            if showHint {
                VStack {
                    Spacer()
                    Text("왼쪽 조이스틱으로 이동 · 화면을 드래그해 시점 변경")
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
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
                withAnimation(.easeOut(duration: 0.4)) { showHint = false }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                webBridge?.probeCollision()
            }
        }
    }
}

private enum GaussianNavMode: String, Hashable {
    case fly
    case walk

    var jsMode: String {
        switch self {
        case .fly: return "fly"
        case .walk: return "walk_collision"
        }
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
    @Binding var bridge: GaussianSplatWebBridge?
    var onCollisionDetected: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCollisionDetected: onCollisionDetected)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.navigationDelegate = context.coordinator

        let owned = GaussianSplatWebBridge()
        owned.webView = webView
        context.coordinator.bridge = owned
        DispatchQueue.main.async { bridge = owned }

        if let token = MobileAuthTokenStore.shared.getAccessToken() {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            webView.load(request)
        } else {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.onCollisionDetected = onCollisionDetected
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var bridge: GaussianSplatWebBridge?
        var onCollisionDetected: (Bool) -> Void
        private var observer: NSObjectProtocol?

        init(onCollisionDetected: @escaping (Bool) -> Void) {
            self.onCollisionDetected = onCollisionDetected
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

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.bridge?.probeCollision()
            }
        }
    }
}
