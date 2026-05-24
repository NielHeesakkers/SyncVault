import SwiftUI

/// Wizard progress indicator. Active dot becomes a wider pill; completed dots turn green.
struct SVProgressDots: View {
    let total: Int
    let current: Int           // 0-based index of the active step

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(color(for: i))
                    .frame(width: i == current ? 20 : 7, height: 7)
                    .animation(.easeInOut(duration: 0.25), value: current)
            }
        }
    }

    private func color(for i: Int) -> Color {
        if i < current  { return SVColor.accentGreen }
        if i == current { return SVColor.accentBlue }
        return Color.white.opacity(0.18)
    }
}

#Preview {
    VStack(spacing: 16) {
        SVProgressDots(total: 4, current: 0)
        SVProgressDots(total: 4, current: 1)
        SVProgressDots(total: 4, current: 2)
        SVProgressDots(total: 4, current: 3)
    }
    .padding()
    .background(SVColor.windowBg)
}
