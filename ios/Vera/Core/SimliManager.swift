import Foundation
import WebKit
import Combine

/// Manages the Simli avatar session. Gets session token from the bridge server,
/// then bridges audio data to the WKWebView running the WebRTC client.
class SimliManager: NSObject, ObservableObject {

    @Published var isSessionActive = false
    @Published var isAvatarReady = false
    @Published var connectionState: ConnectionState = .disconnected

    enum ConnectionState: String {
        case disconnected, connecting, connected, error
    }

    weak var webView: WKWebView?

    // MARK: - Session Lifecycle

    func startSession() {
        guard connectionState == .disconnected || connectionState == .error else { return }
        connectionState = .connecting

        Task {
            do {
                let token = try await fetchSessionFromBridge()
                await MainActor.run {
                    isSessionActive = true
                    webView?.evaluateJavaScript("startSimli('\(token)')") { _, error in
                        if let error = error {
                            print("[SimliManager] JS error: \(error)")
                        }
                    }
                }
            } catch {
                print("[SimliManager] Session start failed: \(error)")
                await MainActor.run { connectionState = .error }
            }
        }
    }

    func stopSession() {
        webView?.evaluateJavaScript("stopSimli()") { _, _ in }
        isSessionActive = false
        isAvatarReady = false
        connectionState = .disconnected
    }

    // MARK: - Audio Forwarding

    /// Forward PCM16 audio to Simli for lip-sync via WKWebView JS bridge.
    func sendAudio(_ pcm16Data: Data) {
        guard isSessionActive else { return }
        let base64 = pcm16Data.base64EncodedString()
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("sendAudio('\(base64)')") { _, _ in }
        }
    }

    // MARK: - Bridge API

    private func fetchSessionFromBridge() async throws -> String {
        guard let url = URL(string: "\(Config.bridgeHTTP)/api/simli-session") else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            print("[SimliManager] Bridge error: \(body)")
            throw URLError(.badServerResponse)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["sessionToken"] as? String else {
            throw URLError(.cannotParseResponse)
        }

        print("[SimliManager] Got session token from bridge")
        return token
    }
}

// MARK: - WKScriptMessageHandler (JS → Swift)

extension SimliManager: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let event = body["event"] as? String else { return }

        DispatchQueue.main.async {
            switch event {
            case "connected":
                self.connectionState = .connected
            case "avatarReady":
                self.isAvatarReady = true
            case "disconnected":
                self.connectionState = .disconnected
                self.isAvatarReady = false
            case "error":
                self.connectionState = .error
            default:
                break
            }
        }
    }
}
