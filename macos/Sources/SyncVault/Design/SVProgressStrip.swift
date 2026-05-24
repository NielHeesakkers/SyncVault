import SwiftUI

/// Filename + percentage + linear progress bar.
/// Used in active sync rows (green fill) and the update window (blue fill).
struct SVProgressStrip: View {
    let filename: String
    let progress: Double       // 0.0 – 1.0
    var fillColor: Color = SVColor.accentBlue
    var trailingText: String? = nil    // e.g. "4.2 MB/s"

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(filename)
                    .font(SVFont.body(12))
                    .foregroundStyle(SVColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let trailingText {
                    Text(trailingText).font(SVFont.mono(10.5)).foregroundStyle(fillColor)
                } else {
                    Text("\(Int(progress * 100))%")
                        .font(SVFont.monoBold(10.5)).foregroundStyle(fillColor)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(fillColor)
                        .frame(width: max(0, geo.size.width * progress))
                }
            }
            .frame(height: 4)
        }
    }
}

#Preview {
    VStack(spacing: 14) {
        SVProgressStrip(filename: "node_modules.tar", progress: 0.64, fillColor: SVColor.accentGreen)
        SVProgressStrip(filename: "SyncVault-3.2.0.dmg", progress: 0.23, fillColor: SVColor.accentBlue)
        SVProgressStrip(filename: "campaign-final.psd", progress: 1.0, fillColor: SVColor.accentGreen, trailingText: "100%")
    }
    .padding()
    .background(SVColor.cardBg)
}
