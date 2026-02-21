import SwiftUI

struct MicButton: View {
    let isListening: Bool
    let amplitude: Float
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isListening {
                    Circle()
                        .stroke(.white.opacity(0.2), lineWidth: 1)
                        .frame(width: 80 + CGFloat(amplitude) * 20, height: 80 + CGFloat(amplitude) * 20)
                        .animation(.easeInOut(duration: 0.1), value: amplitude)
                }

                Circle()
                    .fill(isListening ? Color.white : Color.white.opacity(0.15))
                    .frame(width: 64, height: 64)

                Image(systemName: isListening ? "waveform" : "mic")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isListening ? .black : .white)
                    .symbolEffect(.variableColor.iterative, isActive: isListening)
            }
        }
        .animation(.spring(response: 0.3), value: isListening)
    }
}
