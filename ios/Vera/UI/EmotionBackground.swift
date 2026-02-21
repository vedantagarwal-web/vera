import SwiftUI

struct EmotionBackground: View {
    let emotion: VoiceEngine.Emotion

    var body: some View {
        ZStack {
            Color.black

            RadialGradient(
                colors: [emotionColor.opacity(0.15), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 400
            )
        }
        .animation(.easeInOut(duration: 1.5), value: emotion)
    }

    private var emotionColor: Color {
        switch emotion {
        case .warm: return Color(hex: "#F59E0B")
        case .amused: return Color(hex: "#10B981")
        case .annoyed: return Color(hex: "#EF4444")
        case .flirty: return Color(hex: "#EC4899")
        case .focused: return Color(hex: "#3B82F6")
        }
    }
}
