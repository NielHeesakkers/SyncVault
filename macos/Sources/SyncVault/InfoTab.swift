import SwiftUI

struct InfoTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // About
            Text("ABOUT")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .tracking(0.5)

            VStack(alignment: .leading, spacing: 8) {
                Text("SyncVault")
                    .font(.system(size: 18, weight: .semibold))

                Text("v\(appVersion)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)

                Text("Open-source file sync and backup solution, built as an alternative to Synology Drive.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // Credits
            Text("CREDITS")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .tracking(0.5)

            VStack(alignment: .leading, spacing: 4) {
                Text("Created by Niel Heesakkers")
                    .font(.system(size: 12))

                HStack(spacing: 4) {
                    Text("Vibe-coded with")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Link("Claude", destination: URL(string: "https://claude.ai")!)
                        .font(.system(size: 12))
                    Text("by Anthropic")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Contact
            Text("CONTACT")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .tracking(0.5)

            HStack(spacing: 6) {
                Image(systemName: "envelope")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Link("development@heesakkers.com", destination: URL(string: "mailto:development@heesakkers.com")!)
                    .font(.system(size: 12))
            }

            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Link("GitHub", destination: URL(string: "https://github.com/NielHeesakkers/SyncVault")!)
                    .font(.system(size: 12))
            }

            Spacer()
        }
        .padding(20)
    }
}
