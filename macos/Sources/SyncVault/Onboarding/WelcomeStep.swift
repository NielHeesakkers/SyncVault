import SwiftUI

struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: SVSpacing.xl) {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [SVColor.accentBlue, SVColor.accentPurple],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 72, height: 72)
                .overlay(Image(systemName: "arrow.triangle.2.circlepath.icloud")
                            .font(.system(size: 36)).foregroundStyle(.white))
                .shadow(color: SVColor.accentBlue.opacity(0.35), radius: 24, y: 8)
            Text("Welcome to SyncVault").font(.system(size: 22, weight: .semibold))
            Text("Houd je bestanden synchroon op al je devices. We hebben 3 dingen nodig: een server-URL, je login, en de eerste map die je wilt syncen. Ongeveer 2 minuten.")
                .font(SVFont.body(13.5))
                .foregroundStyle(SVColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(SVSpacing.xxxl)
    }
}
