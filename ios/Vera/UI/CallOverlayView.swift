import SwiftUI

/// Minimal call overlay — shown when Vera initiates a real phone call.
struct CallOverlayView: View {
    let name: String
    let onEnd: () -> Void

    @State private var animatePulse = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Pulsing phone icon
                ZStack {
                    Circle()
                        .fill(.green.opacity(0.15))
                        .frame(width: 100, height: 100)
                        .scaleEffect(animatePulse ? 1.2 : 1.0)
                        .animation(.easeInOut(duration: 1).repeatForever(), value: animatePulse)

                    Image(systemName: "phone.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.green)
                }

                Text("calling \(name)...")
                    .font(.system(size: 22, weight: .light, design: .serif))
                    .foregroundStyle(.white)

                Text("vera is handling this")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.4))

                Spacer()

                // End call button
                Button(action: onEnd) {
                    ZStack {
                        Circle()
                            .fill(.red)
                            .frame(width: 64, height: 64)
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.bottom, 80)
            }
        }
        .onAppear { animatePulse = true }
    }
}
