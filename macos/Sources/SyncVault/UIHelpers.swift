import SwiftUI
import AppKit

// MARK: - Visual Effect (Vibrancy / Blur) Background

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Pulsing Dot

struct PulsingDot: View {
    let color: Color
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(color, lineWidth: 2)
                    .scaleEffect(isPulsing ? 2 : 1)
                    .opacity(isPulsing ? 0 : 0.5)
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                    isPulsing = true
                }
            }
    }
}

// MARK: - Mode Badge

struct ModeBadge: View {
    let mode: SyncTask.SyncMode

    var body: some View {
        Text(mode.shortName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(mode.badgeColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(mode.badgeColor.opacity(0.15), in: Capsule())
            .overlay(Capsule().stroke(mode.badgeColor.opacity(0.3), lineWidth: 0.5))
    }
}

extension SyncTask.SyncMode {
    var badgeColor: Color {
        switch self {
        case .twoWay: return .blue
        case .uploadOnly: return .orange
        case .onDemand: return .purple
        }
    }

    var shortName: String {
        switch self {
        case .twoWay: return "Two-way"
        case .uploadOnly: return "Backup"
        case .onDemand: return "On-demand"
        }
    }
}

// MARK: - Card Container

struct CardContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                    )
            )
    }
}

// MARK: - Section Header (small-caps style)

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold, design: .default))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .tracking(0.8)
    }
}
