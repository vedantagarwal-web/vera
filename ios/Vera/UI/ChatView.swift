import SwiftUI

/// Slide-up chat panel with message history and text input.
struct ChatView: View {
    @ObservedObject var voice: VoiceEngine
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // ── Messages ─────────────────────────────────────
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(voice.messages) { msg in
                            HStack {
                                if msg.isUser { Spacer(minLength: 60) }

                                Text(msg.text)
                                    .font(.system(size: 15))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(
                                        msg.isUser
                                            ? Color.white.opacity(0.2)
                                            : Color.white.opacity(0.08)
                                    )
                                    .foregroundStyle(.white)
                                    .cornerRadius(18)

                                if !msg.isUser { Spacer(minLength: 60) }
                            }
                            .id(msg.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
                .onChange(of: voice.messages.count) { _, _ in
                    if let last = voice.messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // ── Input bar ────────────────────────────────────
            HStack(spacing: 10) {
                TextField("Type a message...", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(22)
                    .foregroundStyle(.white)
                    .focused($isInputFocused)
                    .onSubmit { send() }

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(inputText.trimmingCharacters(in: .whitespaces).isEmpty ? .white.opacity(0.2) : .white)
                }
                .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial.opacity(0.5))
        }
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        voice.sendText(text)
        inputText = ""
    }
}
