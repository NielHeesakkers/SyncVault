import SwiftUI

struct SpeedGraphView: View {
    let history: [Double]

    private var peak: Double {
        history.max() ?? 0
    }

    private var current: Double {
        history.last ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Sparkline graph
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let maxVal = max(peak, 1)
                let points = history.enumerated().map { i, val in
                    CGPoint(
                        x: w * CGFloat(i) / CGFloat(max(history.count - 1, 1)),
                        y: h - (h * CGFloat(val / maxVal))
                    )
                }

                ZStack(alignment: .bottomLeading) {
                    // Fill under curve
                    if points.count > 1 {
                        Path { path in
                            path.move(to: CGPoint(x: points[0].x, y: h))
                            for p in points {
                                path.addLine(to: p)
                            }
                            path.addLine(to: CGPoint(x: points.last!.x, y: h))
                            path.closeSubpath()
                        }
                        .fill(
                            LinearGradient(
                                colors: [Color.green.opacity(0.3), Color.green.opacity(0.05)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        // Line
                        Path { path in
                            path.move(to: points[0])
                            for p in points.dropFirst() {
                                path.addLine(to: p)
                            }
                        }
                        .stroke(Color.green, lineWidth: 1.5)
                    }
                }
            }

            // Speed labels
            HStack {
                Text(formatSpeed(current))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.green)
                Spacer()
                Text("\(formatSpeed(peak)) peak")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color(white: 0.5))
            }
        }
    }

    private func formatSpeed(_ bps: Double) -> String {
        if bps > 1_000_000 { return String(format: "%.1f MB/s", bps / 1_000_000) }
        if bps > 1_000 { return String(format: "%.0f KB/s", bps / 1_000) }
        return String(format: "%.0f B/s", bps)
    }
}
