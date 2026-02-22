import SwiftUI
import WebKit

/// Wraps a WKWebView that runs the Simli WebRTC client.
/// Displays the lip-synced avatar video with transparent background.
struct SimliAvatarView: UIViewRepresentable {
    @ObservedObject var simliManager: SimliManager

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Allow inline media playback without user gesture
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // Register message handler for JS → Swift communication
        let contentController = WKUserContentController()
        contentController.add(simliManager, name: "simli")

        // Inject console.log capture so we can see JS logs in Xcode
        let consoleScript = WKUserScript(
            source: """
            (function() {
                var origLog = console.log;
                var origError = console.error;
                var origWarn = console.warn;
                console.log = function() {
                    var msg = Array.from(arguments).map(String).join(' ');
                    window.webkit.messageHandlers.consoleLog.postMessage(msg);
                    origLog.apply(console, arguments);
                };
                console.error = function() {
                    var msg = 'ERROR: ' + Array.from(arguments).map(String).join(' ');
                    window.webkit.messageHandlers.consoleLog.postMessage(msg);
                    origError.apply(console, arguments);
                };
                console.warn = function() {
                    var msg = 'WARN: ' + Array.from(arguments).map(String).join(' ');
                    window.webkit.messageHandlers.consoleLog.postMessage(msg);
                    origWarn.apply(console, arguments);
                };
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(consoleScript)
        contentController.add(context.coordinator, name: "consoleLog")
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false

        // Load the Simli HTML
        if let htmlURL = Bundle.main.url(forResource: "simli", withExtension: "html") {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        } else {
            print("[SimliAvatarView] ERROR: simli.html not found in bundle")
        }

        // Give the manager a reference to the web view
        simliManager.webView = webView
        webView.navigationDelegate = simliManager

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    /// Captures JS console.log output → Xcode console
    class Coordinator: NSObject, WKScriptMessageHandler {
        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            if let text = message.body as? String {
                print("[JS] \(text)")
            }
        }
    }
}
