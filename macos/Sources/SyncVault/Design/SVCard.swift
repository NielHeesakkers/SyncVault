import SwiftUI

/// Card container with `#2c2c2e` background and 8px corner radius.
/// Children typically are `SVCardRow` instances separated by hairlines.
struct SVCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(SVColor.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: SVRadius.card, style: .continuous))
    }
}

/// One row inside an SVCard. Auto-adds a hairline divider underneath unless `isLast` is true.
struct SVCardRow<Content: View>: View {
    var isLast: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
                .padding(.horizontal, SVSpacing.xl)
                .padding(.vertical, 9)
            if !isLast {
                Rectangle()
                    .fill(SVColor.hairline)
                    .frame(height: 1)
            }
        }
    }
}

#Preview {
    SVCard {
        SVCardRow {
            HStack { Text("Launch at login"); Spacer(); Toggle("", isOn: .constant(true)).labelsHidden() }
        }
        SVCardRow(isLast: true) {
            HStack { Text("Hide dock icon"); Spacer(); Toggle("", isOn: .constant(false)).labelsHidden() }
        }
    }
    .padding()
    .background(SVColor.windowBg)
}
