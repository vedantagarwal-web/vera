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

    struct CallInstruction: Equatable {
        let phone: String
        let name: String
    }

    enum Emotion: String {
        case warm, amused, annoyed, flirty, focused
    }

    // Audio forwarding to Simli
    var onAudioReceived: ((Data) -> Void)?

    // MARK: - Private
    private var audioEngine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    private var wsTask: URLSessionWebSocketTask?
    private var isConnected = false
    private var audioBufferQueue: [Data] = []
    private var isPlayingAudio = false

    init() {
        setupAudioEngine()
        connect()
    }

    // MARK: - Audio Engine Setup

    private func setupAudioEngine() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try? session.setActive(true)

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: playbackFormat)
        try? audioEngine.start()
    }

    // MARK: - WebSocket Connection

    private func connect() {
        guard let url = URL(string: Config.bridgeWS) else { return }
        wsTask = URLSession.shared.webSocketTask(with: url)
        wsTask?.resume()
        isConnected = true
        receiveLoop()
        print("[VoiceEngine] Connected to bridge at \(Config.bridgeWS)")
    }

    private func receiveLoop() {
        wsTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(.data(let data)):
                // Binary = TTS PCM16 audio from bridge
                self.audioBufferQueue.append(data)
                self.onAudioReceived?(data)
                if !self.isPlayingAudio { self.playNextChunk() }

            case .success(.string(let text)):
                self.handleJSON(text)

            case .failure(let error):
                print("[VoiceEngine] WS error: \(error.localizedDescription)")
                self.isConnected = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.connect()
                }
                return // don't continue receive loop
            @unknown default:
                break
            }
            self.receiveLoop() // keep listening
        }
    }

    private func handleJSON(_ json: String) {
        guard let data = json.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = msg["type"] as? String else { return }

        DispatchQueue.main.async {
            switch type {
            case "transcript":
                self.transcript = msg["text"] as? String ?? ""

            case "vera_response":
                self.veraText = msg["text"] as? String ?? ""

            case "emotion":
                if let e = msg["emotion"] as? String {
                    self.currentEmotion = Emotion(rawValue: e) ?? .warm
                }

            case "speaking_start":
                self.isSpeaking = true

            case "speaking_end":
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

    func startListening() {
        guard isConnected else { return }
        isListening = true
        transcript = ""

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Validate format — simulator or missing mic can have 0 sample rate
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            print("[VoiceEngine] Invalid input format: \(inputFormat). No mic available?")
            return
        }

        // Target format for bridge: 16kHz mono float
        guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1) else { return }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            print("[VoiceEngine] Could not create audio converter")
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

            if error == nil, let pcm16 = self.toPCM16(convertedBuffer) {
                self.wsTask?.send(.data(pcm16)) { _ in }
            }
        }
    }

    func stopListening() {
        isListening = false
        audioAmplitude = 0
        audioEngine.inputNode.removeTap(onBus: 0)
        wsTask?.send(.string("{\"type\":\"end_speech\"}")) { _ in }
    }

    // MARK: - Playback

    private func playNextChunk() {
        guard !audioBufferQueue.isEmpty else {
            isPlayingAudio = false
            return
        }

        isPlayingAudio = true
        let data = audioBufferQueue.removeFirst()
        let frameCount = data.count / 2

        guard let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        data.withUnsafeBytes { bytes in
            let int16Ptr = bytes.bindMemory(to: Int16.self)
            for i in 0..<frameCount {
                buffer.floatChannelData![0][i] = Float(int16Ptr[i]) / 32768.0
            }
        }

        // Peak amplitude for UI
        let peak = data.withUnsafeBytes { bytes -> Float in
            let ptr = bytes.bindMemory(to: Int16.self)
            var p: Float = 0
            for i in 0..<frameCount { p = max(p, abs(Float(ptr[i]) / 32768.0)) }
            return min(p * 3, 1.0)
        }
        DispatchQueue.main.async { self.audioAmplitude = peak }

        playerNode.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async { self?.playNextChunk() }
        }
        if !playerNode.isPlaying { playerNode.play() }
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
