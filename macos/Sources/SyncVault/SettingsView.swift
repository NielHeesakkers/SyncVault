import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        TabView {
            ConnectionTab(appState: appState)
                .tabItem { Label("Connection", systemImage: "network") }

            SyncTasksTab(appState: appState)
                .tabItem { Label("Sync Tasks", systemImage: "arrow.triangle.2.circlepath") }

            GeneralTab()
                .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 500, height: 400)
    }
}
