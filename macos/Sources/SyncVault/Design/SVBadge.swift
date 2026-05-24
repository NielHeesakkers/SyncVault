import SwiftUI

/// Small overlay dot for the menu bar icon. Has a window-bg colored ring so it
/// reads against any wallpaper. Optionally pulses (for syncing / completed states).
struct SVBadge: View {
    enum Color {
        case blue, green, orange, red
    }
    let color: Color
    var pulse: Bool = false

    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(fillColor)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(SVColor.cardBg, lineWidth: 1.5))
            .scaleEffect(pulsing && pulse ? 0.7 : 1.0)
            .opacity(pulsing && pulse ? 0.5 : 1.0)
            .animation(pulse ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default,
                       value: pulsing)
            .onAppear { if pulse { pulsing.toggle() } }
    }

    private var fillColor: SwiftUI.Color {
        switch color {
        case .blue:   return SVColor.accentBlue
        case .green:  return SVColor.accentGreen
        case .orange: return SVColor.accentOrange
        case .red:    return SVColor.accentRed
        }
    }
}

#Preview {
    HStack(spacing: 18) {
        SVBadge(color: .blue, pulse: true)
        SVBadge(color: .green, pulse: true)
        SVBadge(color: .orange)
        SVBadge(color: .red)
    }
    .padding()
    .background(SVColor.cardBg)
}
