import SwiftUI

struct GeneralTab: View {
    @ObservedObject var updaterService: UpdaterService
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showNotifications") private var showNotifications = true


    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Startup
            sectionHeader("Startup")
            Toggle("Launch at login", isOn: $launchAtLogin)
                .padding(.leading, 4)

            // Notifications
            sectionHeader("Notifications")
            Toggle("Show sync notifications", isOn: $showNotifications)
                .padding(.leading, 4)

            // Updates
            sectionHeader("Updates")
            Toggle("Automatically check for updates", isOn: $updaterService.automaticallyChecksForUpdates)
                .padding(.leading, 4)

            if let version = updaterService.availableVersion {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.orange)
                    Text("v\(version) available")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    Spacer()
                    Button("Download") {
                        updaterService.downloadAndInstallUpdate(version: version)
                    }
                    .disabled(updaterService.isDownloading)
                }
                .padding(.leading, 4)
            }

            if updaterService.isDownloading {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text("Downloading...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.leading, 4)
            }


            Spacer()
        }
        .padding(20)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.secondary)
            .tracking(0.5)
    }
}
