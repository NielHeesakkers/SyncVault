import SwiftUI

/// 24×24 rounded-square chip with a glyph.
/// Three semantic variants from spec §2: folder, file, cloud (on-demand).
struct SVChip: View {
    enum Variant {
        case folder
        case file
        case cloud
    }

    let variant: Variant
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SVRadius.chip, style: .continuous)
                .fill(background)
            Text(glyph)
                .font(.system(size: size * 0.5))
                .foregroundStyle(foreground)
        }
        .frame(width: size, height: size)
    }

    private var glyph: String {
        switch variant {
        case .folder: return "📁"
        case .file:   return "📄"
        case .cloud:  return "☁"
        }
    }
    private var background: Color {
        variant == .cloud ? SVColor.cloudTint : SVColor.subtleBg
    }
    private var foreground: Color {
        variant == .cloud ? SVColor.cloudFg : SVColor.textPrimary.opacity(0.85)
    }
}

#Preview {
    HStack(spacing: 14) {
        SVChip(variant: .folder)
        SVChip(variant: .file)
        SVChip(variant: .cloud)
    }
    .padding()
    .background(SVColor.cardBg)
}
