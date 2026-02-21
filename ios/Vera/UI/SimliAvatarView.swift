import SwiftUI
import WebKit

/// Wraps a WKWebView that runs the Simli WebRTC client.
/// Displays the lip-synced avatar video with transparent background.
struct SimliAvatarView: UIViewRepresentable {
    @ObservedObject var simliManager: SimliManager

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Allow inline media playback without user gesture
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // Register message handler for JS → Swift communication
        let contentController = WKUserContentController()
        contentController.add(simliManager, name: "simli")
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false

        // Disable bouncing
        webView.scrollView.bounces = false

        // Load the Simli HTML
        if let htmlURL = Bundle.main.url(forResource: "simli", withExtension: "html") {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        } else {
            print("[SimliAvatarView] ERROR: simli.html not found in bundle")
        }

        // Give the manager a reference to the web view
        simliManager.webView = webView

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // No dynamic updates needed — all communication via JS bridge
    }
}
