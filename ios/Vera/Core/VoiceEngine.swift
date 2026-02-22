import Foundation
import AVFoundation
import Combine

/// Handles mic recording, WebSocket communication with the bridge server,
/// and TTS audio playback. Forwards received audio to Simli for lip-sync.
class VoiceEngine: ObservableObject {

    // MARK: - Published State
    @Published var isListening = false
    @Published var isSpeaking = false
    @Published var transcript = ""
    @Published var veraText = ""
    @Published var currentEmotion: Emotion = .warm
    @Published var audioAmplitude: Float = 0.0
    @Published var pendingCall: CallInstruction?
    @Published var messages: [ChatMessage] = []

    struct CallInstruction: Equatable {
        let phone: String
        let name: String
    }

    struct ChatMessage: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isUser: Bool
        let timestamp = Date()
    }

    enum Emotion: String {
        case warm, amused, annoyed, flirty, focused
    }

    // Audio forwarding to Simli
    var onAudioReceived: ((Data) -> Void)?

    // MARK: - Private
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    private var wsTask: URLSessionWebSocketTask?
    private var wsGeneration = 0  // Track which WS connection is current
    private var isConnected = false
    private var audioBufferQueue: [Data] = []
    private var isPlayingAudio = false

    private var audioEngineReady = false
    private var micPermissionGranted = false
    private var micRetryCount = 0
    private var engineSampleRate: Double = 0  // Track what rate the engine was built at

    init() {
        // Listen for audio route changes (Simli WebRTC can change sample rate)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        connect()
        requestMicPermission()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        let session = AVAudioSession.sharedInstance()
        let newRate = session.sampleRate
        if engineSampleRate > 0 && newRate != engineSampleRate {
            print("[VoiceEngine] Audio route changed: \(engineSampleRate) → \(newRate) Hz — will rebuild engine on next use")
            // Don't rebuild immediately (might be mid-playback), just mark as stale
            audioEngineReady = false
        }
    }

    // MARK: - Audio Engine Setup

    private func requestMicPermission() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.micPermissionGranted = granted
                if granted {
                    print("[VoiceEngine] Mic permission granted")
                    self.setupAudioSession()
                } else {
                    print("[VoiceEngine] Mic permission denied")
                }
            }
        }
    }

    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Use .default mode (not .voiceChat) to avoid conflict with WKWebView WebRTC
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
            try session.setPreferredSampleRate(48000)
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true, options: [])
            print("[VoiceEngine] Audio session active, hw sampleRate: \(session.sampleRate), inputAvailable: \(session.isInputAvailable)")
        } catch {
            print("[VoiceEngine] Audio session setup failed: \(error)")
            return
        }

        buildAudioEngine()
    }

    private func buildAudioEngine() {
        // Stop listening if active — must remove tap before tearing down engine
        if isListening {
            audioEngine?.inputNode.removeTap(onBus: 0)
            isListening = false
        }

        // Tear down old engine if any
        if let oldEngine = audioEngine {
            oldEngine.stop()
            if let oldPlayer = playerNode {
                oldEngine.detach(oldPlayer)
            }
        }

        let engine = AVAudioEngine()

        // Access inputNode BEFORE starting — forces audio route initialization
        let inputNode = engine.inputNode
        let inputFmt = inputNode.outputFormat(forBus: 0)
        print("[VoiceEngine] Input node format before start: \(inputFmt.sampleRate) Hz, \(inputFmt.channelCount) ch")

        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

        do {
            try engine.start()
            self.audioEngine = engine
            self.playerNode = player
            self.audioEngineReady = true
            let fmt = engine.inputNode.outputFormat(forBus: 0)
            self.engineSampleRate = fmt.sampleRate
            print("[VoiceEngine] Audio engine started — input: \(fmt.sampleRate) Hz, \(fmt.channelCount) ch")
        } catch {
            print("[VoiceEngine] Audio engine start failed: \(error)")
        }
    }

    // MARK: - WebSocket Connection

    private func connect() {
        // Cancel any existing connection
        let oldTask = wsTask
        wsTask = nil
        oldTask?.cancel(with: .goingAway, reason: nil)

        wsGeneration += 1
        let thisGeneration = wsGeneration

        guard let url = URL(string: Config.bridgeWS) else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        wsTask = task
        task.resume()
        print("[VoiceEngine] Connecting to bridge at \(Config.bridgeWS)... (gen \(thisGeneration))")

        // Send a ping to verify the connection is actually open
        task.sendPing { [weak self] error in
            guard let self = self, self.wsGeneration == thisGeneration else { return }
            if let error = error {
                print("[VoiceEngine] Ping failed — WS not actually connected: \(error.localizedDescription)")
                self.isConnected = false
            } else {
                print("[VoiceEngine] Ping OK — WS confirmed connected (gen \(thisGeneration))")
                DispatchQueue.main.async { self.isConnected = true }
            }
        }
        receiveLoop(generation: thisGeneration)
    }

    private func receiveLoop(generation: Int) {
        guard generation == wsGeneration else {
            print("[VoiceEngine] Stale receive loop (gen \(generation) vs current \(wsGeneration)) — stopping")
            return
        }
        wsTask?.receive { [weak self] result in
            guard let self = self, generation == self.wsGeneration else { return }
            switch result {
            case .success(.data(let data)):
                // Binary = TTS PCM16 audio from bridge
                if self.audioBufferQueue.isEmpty && !self.isPlayingAudio {
                    print("[VoiceEngine] First TTS audio chunk received: \(data.count) bytes")
                }
                self.audioBufferQueue.append(data)
                self.onAudioReceived?(data)
                if !self.isPlayingAudio {
                    DispatchQueue.main.async { self.playNextChunk() }
                }

            case .success(.string(let text)):
                self.handleJSON(text)

            case .failure(let error):
                print("[VoiceEngine] WS error (gen \(generation)): \(error.localizedDescription)")
                guard generation == self.wsGeneration else { return }
                self.isConnected = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self = self, generation == self.wsGeneration else { return }
                    self.connect()
                }
                return // don't continue receive loop
            @unknown default:
                break
            }
            self.receiveLoop(generation: generation) // keep listening
        }
    }

    private func handleJSON(_ json: String) {
        guard let data = json.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = msg["type"] as? String else { return }

        DispatchQueue.main.async {
            switch type {
            case "transcript":
                let t = msg["text"] as? String ?? ""
                self.transcript = t
                let isFinal = msg["isFinal"] as? Bool ?? false
                if isFinal && !t.isEmpty {
                    self.messages.append(ChatMessage(text: t, isUser: true))
                }
                print("[VoiceEngine] Transcript: \"\(t.prefix(60))\"")

            case "vera_response":
                let r = msg["text"] as? String ?? ""
                self.veraText = r
                if !r.isEmpty {
                    self.messages.append(ChatMessage(text: r, isUser: false))
                }
                print("[VoiceEngine] Vera response: \"\(r.prefix(60))\"")

            case "emotion":
                if let e = msg["emotion"] as? String {
                    self.currentEmotion = Emotion(rawValue: e) ?? .warm
                }

            case "speaking_start":
                print("[VoiceEngine] Vera speaking start")
                self.isSpeaking = true

            case "speaking_end":
                print("[VoiceEngine] Vera speaking end")
                self.isSpeaking = false
                self.audioAmplitude = 0

            case "call":
                let phone = msg["phone"] as? String ?? ""
                let name = msg["name"] as? String ?? ""
                self.pendingCall = CallInstruction(phone: phone, name: name)

            default:
                break
            }
        }
    }

    // MARK: - Recording

    private var audioSendCount = 0

    func startListening() {
        // Prevent duplicate taps
        guard !isListening else {
            print("[VoiceEngine] Already listening, ignoring")
            return
        }
        guard isConnected else {
            print("[VoiceEngine] Not connected to bridge, can't listen")
            return
        }
        guard micPermissionGranted else {
            print("[VoiceEngine] No mic permission, requesting...")
            requestMicPermission()
            return
        }

        // Check if engine needs rebuilding (e.g. after Simli changed sample rate)
        if !audioEngineReady {
            print("[VoiceEngine] Audio engine not ready, rebuilding...")
            setupAudioSession()
            // Retry after engine is rebuilt
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startListening()
            }
            return
        }

        guard let engine = audioEngine else {
            print("[VoiceEngine] No audio engine")
            setupAudioSession()
            return
        }

        // Read the CURRENT hardware format
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        // If hardware sample rate changed (WebRTC can do this), rebuild engine
        if hwFormat.sampleRate != engineSampleRate || hwFormat.sampleRate == 0 || hwFormat.channelCount == 0 {
            print("[VoiceEngine] Hardware format changed: engine=\(engineSampleRate) hw=\(hwFormat.sampleRate) Hz — rebuilding")
            audioEngineReady = false
            setupAudioSession()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startListening()
            }
            return
        }
        micRetryCount = 0

        isListening = true
        transcript = ""
        audioSendCount = 0

        // Use the actual hardware format for the tap (NOT a cached value)
        let inputFormat = hwFormat
        print("[VoiceEngine] Starting mic tap: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch")

        // Target format for bridge: 16kHz mono float
        guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1) else { return }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            print("[VoiceEngine] Could not create audio converter from \(inputFormat.sampleRate) Hz")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Amplitude for UI
            if let channelData = buffer.floatChannelData?[0] {
                let frames = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frames { sum += abs(channelData[i]) }
                DispatchQueue.main.async {
                    self.audioAmplitude = min(sum / Float(frames) * 10, 1.0)
                }
            }

            // Convert to 16kHz mono then PCM16
            let ratio = 16000.0 / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard capacity > 0, let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if let convError = error {
                if self.audioSendCount == 0 { print("[VoiceEngine] Converter error: \(convError)") }
            } else if let pcm16 = self.toPCM16(convertedBuffer) {
                self.audioSendCount += 1
                if self.audioSendCount == 1 {
                    print("[VoiceEngine] First audio chunk: \(pcm16.count) bytes, wsState: \(self.wsTask?.state.rawValue ?? -1)")
                }
                if self.audioSendCount % 50 == 0 {
                    print("[VoiceEngine] Sent \(self.audioSendCount) audio chunks")
                }
                self.wsTask?.send(.data(pcm16)) { sendError in
                    if let sendError = sendError, self.audioSendCount <= 2 {
                        print("[VoiceEngine] WS send error: \(sendError.localizedDescription)")
                    }
                }
            }
        }
    }

    func stopListening() {
        isListening = false
        audioAmplitude = 0
        audioEngine?.inputNode.removeTap(onBus: 0)
        wsTask?.send(.string("{\"type\":\"end_speech\"}")) { _ in }
    }

    /// Send a text message directly (bypasses mic/STT)
    func sendText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard isConnected else {
            print("[VoiceEngine] Not connected, can't send chat")
            return
        }
        print("[VoiceEngine] Sending chat: \"\(trimmed.prefix(60))\"")
        let json = try? JSONSerialization.data(withJSONObject: ["type": "chat", "text": trimmed])
        if let json = json, let str = String(data: json, encoding: .utf8) {
            wsTask?.send(.string(str)) { error in
                if let error = error {
                    print("[VoiceEngine] Chat send error: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Playback

    private var playbackChunkCount = 0

    private func playNextChunk() {
        guard !audioBufferQueue.isEmpty else {
            if isPlayingAudio {
                print("[VoiceEngine] Playback done — \(playbackChunkCount) chunks played")
                playbackChunkCount = 0
            }
            isPlayingAudio = false
            return
        }

        // Rebuild engine if needed (might have been invalidated by route change)
        if !audioEngineReady || audioEngine?.isRunning != true {
            print("[VoiceEngine] Engine not ready for playback — rebuilding")
            setupAudioSession()
        }

        guard let player = playerNode, let engine = audioEngine, engine.isRunning else {
            print("[VoiceEngine] Cannot play — engine running: \(audioEngine?.isRunning ?? false), player: \(playerNode != nil)")
            audioBufferQueue.removeAll()
            isPlayingAudio = false
            return
        }

        isPlayingAudio = true
        let data = audioBufferQueue.removeFirst()
        let frameCount = data.count / 2

        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            playNextChunk()
            return
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        data.withUnsafeBytes { bytes in
            let int16Ptr = bytes.bindMemory(to: Int16.self)
            for i in 0..<frameCount {
                buffer.floatChannelData![0][i] = Float(int16Ptr[i]) / 32768.0
            }
        }

        playbackChunkCount += 1
        if playbackChunkCount == 1 {
            print("[VoiceEngine] Playing first audio chunk: \(frameCount) frames, player playing: \(player.isPlaying)")
        }

        // Peak amplitude for UI
        let peak = data.withUnsafeBytes { bytes -> Float in
            let ptr = bytes.bindMemory(to: Int16.self)
            var p: Float = 0
            for i in 0..<frameCount { p = max(p, abs(Float(ptr[i]) / 32768.0)) }
            return min(p * 3, 1.0)
        }
        self.audioAmplitude = peak

        player.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async { self?.playNextChunk() }
        }
        if !player.isPlaying { player.play() }
    }

    // MARK: - Helpers

    private func toPCM16(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let floatData = buffer.floatChannelData else { return nil }
        let count = Int(buffer.frameLength)
        var pcm = Data(count: count * 2)
        pcm.withUnsafeMutableBytes { bytes in
            let ptr = bytes.bindMemory(to: Int16.self)
            for i in 0..<count {
                ptr[i] = Int16(max(-32768, min(32767, Int(floatData[0][i] * 32767))))
            }
        }
        return pcm
    }
}
