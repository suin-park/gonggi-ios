import SwiftUI
import WebKit

/// Embeds 3D Locker SuperSplat viewer HTML for free navigation inside a completed Gaussian space.
struct GaussianSplatWebViewer: View {
    let spaceId: String
    var onClose: () -> Void

    private var viewerURL: URL {
        AppConfiguration.production.apiBaseURL
            .appendingPathComponent("api/gaussian-spaces/\(spaceId)/viewer-html")
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GaussianSplatWebView(url: viewerURL)
                .ignoresSafeArea()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 4)
                    .padding()
            }
            .accessibilityLabel("닫기")
        }
    }
}

private struct GaussianSplatWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        if let token = MobileAuthTokenStore.shared.getAccessToken() {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            webView.load(request)
        } else {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
