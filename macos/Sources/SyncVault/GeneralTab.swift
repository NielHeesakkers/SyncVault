import SwiftUI

struct GeneralTab: View {
    @ObservedObject var updaterService: UpdaterService
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showNotifications") private var showNotifications = true

    @State private var changelog: String? = nil
    @State private var isLoadingChangelog = false

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
            }

            Section("Notifications") {
                Toggle("Show sync notifications", isOn: $showNotifications)
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $updaterService.automaticallyChecksForUpdates)

                if let version = updaterService.availableVersion {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.orange)
                        Text("Update available: v\(version)")
                            .foregroundColor(.orange)
                        Spacer()
                        Button("Download") {
                            updaterService.downloadAndInstallUpdate(version: version)
                        }
                        .disabled(updaterService.isDownloading)
                    }
                }

                if updaterService.isDownloading {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Downloading update...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: "SyncVault v\(appVersion)")
            }

            Section("What's New in v\(appVersion)") {
                if isLoadingChangelog {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Loading changelog...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if let notes = changelog {
                    Text(notes)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Changelog unavailable.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .task {
            await loadChangelog()
        }
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
