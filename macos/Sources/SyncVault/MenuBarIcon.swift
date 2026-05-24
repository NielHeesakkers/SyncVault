import SwiftUI

/// Seven menu bar states. Drives glyph + badge overlay choice.
enum MenuBarState: Hashable {
    case synced
    case syncing
    case paused
    case offline
    case error
    case updateAvailable
    case recentlyCompleted
}

struct MenuBarIcon: View {
    let state: MenuBarState

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: glyph)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.primary.opacity(state == .offline ? 0.35 : 1.0))
            if let badge {
                SVBadge(color: badge.color, pulse: badge.pulse)
                    .offset(x: 3, y: 3)
            }
        }
    }

    private var glyph: String {
        switch state {
        case .paused: return "pause.fill"
        default:      return "arrow.triangle.2.circlepath.icloud"
        }
    }

    private struct BadgeSpec { let color: SVBadge.Color; let pulse: Bool }

    private var badge: BadgeSpec? {
        // Priority order from spec §3: error > update > syncing > completed
        switch state {
        case .error:             return .init(color: .red,    pulse: false)
        case .updateAvailable:   return .init(color: .orange, pulse: false)
        case .syncing:           return .init(color: .blue,   pulse: true)
        case .recentlyCompleted: return .init(color: .green,  pulse: true)
        case .synced, .paused, .offline: return nil
        }
    }
}

#Preview {
    HStack(spacing: 18) {
        ForEach([MenuBarState.synced, .syncing, .paused, .offline, .error, .updateAvailable, .recentlyCompleted], id: \.self) { s in
            MenuBarIcon(state: s)
        }
    }
    .padding()
    .background(Color.black)
}
