import SwiftUI

struct GeneralTab: View {
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
        }
        .padding()
    }
}
