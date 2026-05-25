import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, connection, syncTasks, changelog, info

    var title: String {
        switch self {
        case .general:   return "General"
        case .connection: return "Connection"
        case .syncTasks: return "Sync Tasks"
        case .changelog: return "Changelog"
        case .info:      return "Info"
        }
    }

    var glyph: String {
        switch self {
        case .general:   return "⚙"
        case .connection: return "🌐"
        case .syncTasks: return "📁"
        case .changelog: return "📋"
        case .info:      return "ⓘ"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var updaterService: UpdaterService
    @State private var selected: SettingsTab = .general

    var body: some View {
        // HStack instead of NavigationSplitView — keeps the standard window
        // chrome (traffic lights + "SyncVault Settings" title bar) while giving
        // us a flat 2-column layout where content starts immediately under the
        // titlebar, identical to the mockup.
        HStack(spacing: 0) {
            // Sidebar
            VStack(spacing: 1) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    SVSidebarItem(title: tab.title, glyph: tab.glyph, isActive: selected == tab) {
                        selected = tab
                    }
                }
                Spacer()
            }
            .padding(SVSpacing.s)
            .frame(width: 188)
            .background(Color(red: 0.137, green: 0.137, blue: 0.145))

            // Hairline divider between sidebar and content
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 1)

            // Detail
            Group {
                switch selected {
                case .general:    GeneralTab(appState: appState, updaterService: updaterService)
                case .connection: ConnectionTab(appState: appState)
                case .syncTasks:  SyncTasksTab(appState: appState)
                case .changelog:  ChangelogTab()
                case .info:       InfoTab(appState: appState)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SVColor.windowBg)
        }
        .frame(width: 720, height: 540)
    }
}
