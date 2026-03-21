import SwiftUI

struct GeneralTab: View {
    @ObservedObject var updaterService: UpdaterService
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showNotifications") private var showNotifications = true

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
                LabeledContent("Version", value: "v\(appVersion)")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
            }
        }
        .padding()
    }
}
