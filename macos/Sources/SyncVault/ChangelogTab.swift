import SwiftUI

struct ChangelogTab: View {
    @State private var changelog: String? = nil
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CHANGELOG")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .tracking(0.5)

            Text("Current version: v\(appVersion)")
                .font(.system(size: 12, weight: .medium))

            if isLoading {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text("Loading changelog...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            } else if let notes = changelog {
                ScrollView {
                    Text(notes)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            } else {
                Text("Changelog unavailable. Connect to the server to load.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(20)
        .task {
            await loadChangelog()
        }
    }

    private func loadChangelog() async {
        let sharedDefaults = UserDefaults(suiteName: "DE59N86W33.com.syncvault.shared")
        guard let serverURL = sharedDefaults?.string(forKey: "serverURL"), !serverURL.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let urlStr = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/version"
            guard let url = URL(string: urlStr) else { return }
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
