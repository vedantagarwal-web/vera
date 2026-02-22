import SwiftUI

/// The entire Vera UI: a fullscreen avatar face, a mic button, and call overlay.
/// Nothing else. The personality and smarts come from OpenClaw.
struct VeraFaceView: View {
    @StateObject private var voice = VoiceEngine()
    @StateObject private var simli = SimliManager()
    @StateObject private var callManager = VeraCallManager()
    @State private var showChat = false

    var body: some View {
        ZStack {
            // Emotional background gradient
            EmotionBackground(emotion: voice.currentEmotion)
                .ignoresSafeArea()

            // ── Face mode (always rendered, hidden when chat is open) ──
            VStack(spacing: 0) {
                Spacer()

                // Vera's Face
                ZStack {
                    Circle()
                        .stroke(emotionColor.opacity(voice.isSpeaking ? 0.5 : 0.15), lineWidth: 2)
                        .frame(width: 300, height: 300)
                        .scaleEffect(voice.isSpeaking ? 1.0 + CGFloat(voice.audioAmplitude) * 0.05 : 1.0)
                        .animation(.easeInOut(duration: 0.1), value: voice.audioAmplitude)

                    Circle()
                        .fill(.black)
                        .frame(width: 280, height: 280)
                        .overlay {
                            SimliAvatarView(simliManager: simli)
                                .frame(width: 280, height: 280)
                                .clipShape(Circle())
                                .opacity(simli.isAvatarReady ? 1.0 : 0.0)
                                .animation(.easeInOut(duration: 0.5), value: simli.isAvatarReady)
                        }
                        .overlay {
                            if !simli.isAvatarReady {
                                Image(systemName: "person.circle.fill")
                                    .resizable()
                                    .frame(width: 120, height: 120)
                                    .foregroundStyle(.white.opacity(0.12))
                            }
                        }
                }

                Spacer().frame(height: 40)

                // Vera's words
                if !voice.veraText.isEmpty {
                    Text(voice.veraText)
                        .font(.system(size: 17, weight: .light, design: .serif))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                        .lineLimit(3)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.3), value: voice.veraText)
                }

                // User's words (while listening)
                if !voice.transcript.isEmpty && voice.isListening {
                    Text(voice.transcript)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.35))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 48)
                        .padding(.top, 8)
                }

                Spacer()

                // Bottom controls: chat button + mic button
                HStack(spacing: 32) {
                    Button {
                        withAnimation(.spring(response: 0.35)) { showChat = true }
                    } label: {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 48, height: 48)
                            .background(.white.opacity(0.08))
                            .clipShape(Circle())
                    }

                    MicButton(
                        isListening: voice.isListening,
                        amplitude: voice.audioAmplitude
                    ) {
                        if voice.isListening {
                            voice.stopListening()
                        } else {
                            voice.startListening()
                        }
                    }

                    Color.clear.frame(width: 48, height: 48)
                }
                .padding(.bottom, 60)
            }
            .opacity(showChat ? 0 : 1)

            // ── Chat mode (overlaid on top) ──────────────────
            if showChat {
                VStack(spacing: 0) {
                    // Top bar
                    HStack(spacing: 12) {
                        Circle()
                            .fill(.black)
                            .frame(width: 44, height: 44)
                            .overlay {
                                Image(systemName: "person.circle.fill")
                                    .resizable()
                                    .frame(width: 24, height: 24)
                                    .foregroundStyle(.white.opacity(0.3))
                            }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Vera")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                            if voice.isSpeaking {
                                Text("speaking...")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }

                        Spacer()

                        // Mic button (small)
                        Button {
                            if voice.isListening {
                                voice.stopListening()
                            } else {
                                voice.startListening()
                            }
                        } label: {
                            Image(systemName: voice.isListening ? "waveform" : "mic")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(voice.isListening ? .black : .white)
                                .frame(width: 36, height: 36)
                                .background(voice.isListening ? .white : .white.opacity(0.15))
                                .clipShape(Circle())
                        }

                        // Back to face
                        Button {
                            withAnimation(.spring(response: 0.35)) { showChat = false }
                        } label: {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 20))
                                .foregroundStyle(.white.opacity(0.7))
                                .frame(width: 36, height: 36)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial.opacity(0.3))

                    ChatView(voice: voice)
                }
                .transition(.opacity)
            }

            // ── Call overlay ─────────────────────────────────
            if callManager.isCallActive {
                CallOverlayView(name: callManager.callContactName ?? "") {
                    callManager.endCall()
                }
                .transition(.move(edge: .bottom))
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            voice.onAudioReceived = { [weak simli] data in
                simli?.sendAudio(data)
            }
            simli.startSession()
        }
        .onChange(of: voice.pendingCall) { _, call in
            guard let call = call else { return }
            withAnimation(.spring(response: 0.4)) {
                callManager.makeCall(phone: call.phone, name: call.name)
            }
        }
    }

    private var emotionColor: Color {
        switch voice.currentEmotion {
        case .warm: return Color(hex: "#F59E0B")
        case .amused: return Color(hex: "#10B981")
        case .annoyed: return Color(hex: "#EF4444")
        case .flirty: return Color(hex: "#EC4899")
        case .focused: return Color(hex: "#3B82F6")
        }
    }
}
