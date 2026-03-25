import SwiftUI

struct GeneralTab: View {
    @ObservedObject var updaterService: UpdaterService
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showNotifications") private var showNotifications = true

    var body: some View {
        Form {
            // MARK: - App info header
            Section {
                HStack(spacing: 14) {
                    if let appIcon = NSImage(named: "AppIcon") {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.accentColor.gradient)
                            .frame(width: 52, height: 52)
                            .overlay(
                                Image(systemName: "arrow.triangle.2.circlepath.icloud")
                                    .font(.system(size: 24, weight: .medium))
                                    .foregroundColor(.white)
                            )
                            .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("SyncVault")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Version \(appVersion)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            // MARK: - Startup
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
            } header: {
                SectionHeader(title: "Startup")
            }

            // MARK: - Notifications
            Section {
                Toggle("Show sync notifications", isOn: $showNotifications)
            } header: {
                SectionHeader(title: "Notifications")
            }

            // MARK: - Updates
            Section {
                Toggle("Automatically check for updates", isOn: $updaterService.automaticallyChecksForUpdates)

                if let version = updaterService.availableVersion {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 15))
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("v\(version) available")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.orange)
                            Text("A new version is ready to download")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Download") {
                            updaterService.downloadAndInstallUpdate(version: version)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(updaterService.isDownloading)
                    }
                }

                if updaterService.isDownloading {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.7)
                        Text("Downloading update...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                SectionHeader(title: "Updates")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }
}
