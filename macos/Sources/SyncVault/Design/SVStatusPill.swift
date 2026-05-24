import SwiftUI

/// Mono-font status pill shown on the right of sync-task rows.
struct SVStatusPill: View {
    enum Kind {
        case neutral    // default — "synced", "847M", etc.
        case live       // active upload/download — green
        case cloud      // on-demand mode — blue tint
        case paused     // user-paused — orange tint
    }

    let text: String
    let kind: Kind

    var body: some View {
        Text(text)
            .font(SVFont.mono(10))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(RoundedRectangle(cornerRadius: SVRadius.pill, style: .continuous))
    }

    private var background: Color {
        switch kind {
        case .neutral: return SVColor.subtleBg
        case .live:    return SVColor.liveTint
        case .cloud:   return SVColor.cloudTint
        case .paused:  return SVColor.pausedTint
        }
    }
    private var foreground: Color {
        switch kind {
        case .neutral: return SVColor.textSecondary
        case .live:    return SVColor.accentGreen
        case .cloud:   return SVColor.cloudFg
        case .paused:  return SVColor.accentOrange
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        SVStatusPill(text: "synced",            kind: .neutral)
        SVStatusPill(text: "↑ 12M · syncing",   kind: .live)
        SVStatusPill(text: "on-demand",         kind: .cloud)
        SVStatusPill(text: "paused",            kind: .paused)
    }
    .padding()
    .background(SVColor.cardBg)
}
