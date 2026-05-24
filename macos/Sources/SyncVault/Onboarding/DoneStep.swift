import SwiftUI

struct DoneStep: View {
    var body: some View {
        VStack(spacing: SVSpacing.xl) {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [SVColor.accentGreen, SVColor.accentBlue],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 72, height: 72)
                .overlay(Image(systemName: "checkmark").font(.system(size: 32, weight: .bold)).foregroundStyle(.white))
                .shadow(color: SVColor.accentGreen.opacity(0.4), radius: 24, y: 8)
            Text("You're all set").font(.system(size: 22, weight: .semibold))
            Text("SyncVault zit nu in je menu bar (rechtsboven). Je eerste sync is gestart.\n\nKlik het icoon om de status te zien, of voeg meer mappen toe in Settings.")
                .font(SVFont.body(13.5))
                .foregroundStyle(SVColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(SVSpacing.xxxl)
    }
}
