import SwiftUI

/// 10pt uppercase letter-spaced label with optional right-aligned count.
/// Used above each card group and inside the menu bar popover.
struct SVSectionLabel: View {
    let text: String
    var count: String? = nil

    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(SVFont.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(SVColor.textTertiary)
            Spacer()
            if let count {
                Text(count)
                    .font(SVFont.monoBold(10))
                    .foregroundStyle(SVColor.textTertiary)
            }
        }
        .padding(.bottom, 6)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        SVSectionLabel(text: "Updates")
        SVSectionLabel(text: "Sync tasks", count: "4 / 4")
        SVSectionLabel(text: "Recently changed")
    }
    .padding()
    .background(SVColor.windowBg)
}
