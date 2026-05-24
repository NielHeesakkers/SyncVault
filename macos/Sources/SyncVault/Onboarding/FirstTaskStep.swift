import SwiftUI
import AppKit

struct FirstTaskStep: View {
    @ObservedObject var controller: OnboardingController

    var body: some View {
        VStack(alignment: .leading, spacing: SVSpacing.xl) {
            Text("Create your first sync task").font(.system(size: 18, weight: .semibold))
            Text("Begin met één map. Je kunt later meer toevoegen in Settings.")
                .font(SVFont.body(12.5)).foregroundStyle(SVColor.textSecondary)

            picker(label: "Local folder", icon: "📁", value: controller.localPath) {
                chooseLocalFolder()
            }
            picker(label: "Server folder", icon: "☁", value: "/" + controller.username + "/" + controller.remoteFolderName) {
                // Server-folder picker not implemented in onboarding — use default.
            }

            HStack {
                ForEach([SyncTask.SyncMode.twoWay, .uploadOnly, .onDemand], id: \.self) { mode in
                    Button(modeLabel(mode)) {
                        controller.syncMode = mode
                    }
                    .buttonStyle(.plain)
                    .font(SVFont.body(12))
                    .padding(.horizontal, SVSpacing.l).padding(.vertical, 7)
                    .background(controller.syncMode == mode ? SVColor.cloudTint : Color.clear)
                    .foregroundStyle(controller.syncMode == mode ? SVColor.cloudFg : SVColor.textSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(3)
            .background(SVColor.subtleBg)
            .clipShape(RoundedRectangle(cornerRadius: SVRadius.card - 1))

            Text("Files in both directions stay in sync · changes propagate within 100 ms")
                .font(SVFont.body(11)).foregroundStyle(SVColor.textTertiary)
        }
        .frame(maxWidth: 380)
        .padding(SVSpacing.xxxl)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func picker(label: String, icon: String, value: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: SVSpacing.l) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(SVColor.subtleBg).frame(width: 28, height: 28)
                Text(icon).font(.system(size: 14))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(SVFont.body(11)).foregroundStyle(SVColor.textSecondary)
                Text(value).font(SVFont.mono(12)).foregroundStyle(SVColor.textPrimary)
            }
            Spacer()
            Button("Choose…", action: action)
                .buttonStyle(.plain).font(SVFont.body(12)).foregroundStyle(SVColor.accentBlue)
        }
        .padding(SVSpacing.l)
        .background(SVColor.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: SVRadius.card - 1))
    }

    private func modeLabel(_ mode: SyncTask.SyncMode) -> String {
        switch mode {
        case .twoWay:     return "Two-way sync"
        case .uploadOnly: return "Backup only"
        case .onDemand:   return "On-demand"
        }
    }

    private func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: controller.localPath)
        if panel.runModal() == .OK, let url = panel.url {
            controller.localPath = url.path
            controller.remoteFolderName = url.lastPathComponent
        }
    }
}
