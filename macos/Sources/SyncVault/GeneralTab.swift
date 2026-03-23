import SwiftUI

struct GeneralTab: View {
    @ObservedObject var updaterService: UpdaterService
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showNotifications") private var showNotifications = true

    @State private var changelog: String? = nil
    @State private var isLoadingChangelog = false

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

            Divider()

            // About
            sectionHeader("About")
            Text("SyncVault v\(appVersion)")
                .font(.system(size: 12))
                .padding(.leading, 4)

            // Changelog
            sectionHeader("What's New")
            Group {
                if isLoadingChangelog {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6)
                        Text("Loading...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                } else if let notes = changelog {
                    ScrollView {
                        Text(notes)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                } else {
                    Text("Changelog unavailable.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.leading, 4)

            Spacer()
        }
        .padding(20)
        .task {
            await loadChangelog()
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.secondary)
            .tracking(0.5)
    }

    private func loadChangelog() async {
        let sharedDefaults = UserDefaults(suiteName: "DE59N86W33.com.syncvault.shared")
        guard let serverURL = sharedDefaults?.string(forKey: "serverURL"), !serverURL.isEmpty else { return }

        isLoadingChangelog = true
        defer { isLoadingChangelog = false }

        do {
            let url = URL(string: "\(serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/api/version")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            if let token = KeychainHelper.load(key: "access_token") {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let notes = json["changelog"] as? String ?? (json["release_notes"] as? String) {
                changelog = notes
            }
        } catch {
            // Silently ignore
        }
    }
}
