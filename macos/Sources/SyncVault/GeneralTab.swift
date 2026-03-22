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
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updaterService.updater.automaticallyChecksForUpdates },
                    set: { updaterService.updater.automaticallyChecksForUpdates = $0 }
                ))
            }

            Section("About") {
                LabeledContent("Version", value: "SyncVault v\(appVersion)")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
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
                    Text("Changelog unavailable. Connect to a server to load.")
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
        // Retrieve server URL from shared defaults (set on connect)
        let sharedDefaults = UserDefaults(suiteName: "DE59N86W33.com.syncvault.shared")
        guard let serverURL = sharedDefaults?.string(forKey: "serverURL"), !serverURL.isEmpty else { return }

        isLoadingChangelog = true
        defer { isLoadingChangelog = false }

        do {
            let url = URL(string: "\(serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/api/version")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            // Add auth token if available
            if let token = KeychainHelper.load(key: "access_token") {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let notes = json["changelog"] as? String ?? (json["release_notes"] as? String) {
                changelog = notes
            } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let version = json["version"] as? String {
                changelog = "Server version: \(version)"
            }
        } catch {
            // Silently ignore — changelog is non-critical
        }
    }
}
