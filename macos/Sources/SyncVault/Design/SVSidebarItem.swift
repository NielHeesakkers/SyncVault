import SwiftUI

/// Settings sidebar row: small chip + label, blue-tinted chip when active.
struct SVSidebarItem: View {
    let title: String
    let glyph: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isActive ? SVColor.cloudTint : SVColor.subtleBg)
                        .frame(width: 18, height: 18)
                    Text(glyph)
                        .font(.system(size: 10))
                        .foregroundStyle(isActive ? SVColor.cloudFg : SVColor.textPrimary.opacity(0.8))
                }
                Text(title)
                    .font(SVFont.body(12.5))
                    .foregroundStyle(isActive ? SVColor.textPrimary : SVColor.textPrimary.opacity(0.75))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SVSpacing.l)
            .padding(.vertical, 7)
            .background(isActive ? Color.white.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: SVRadius.card - 2, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack(spacing: 1) {
        SVSidebarItem(title: "General",    glyph: "⚙",  isActive: true)  { }
        SVSidebarItem(title: "Connection", glyph: "🌐", isActive: false) { }
        SVSidebarItem(title: "Sync Tasks", glyph: "📁", isActive: false) { }
    }
    .padding(SVSpacing.s)
    .frame(width: 180)
    .background(Color(red: 0.137, green: 0.137, blue: 0.145))
}
