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
        NavigationSplitView {
            VStack(spacing: 1) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    SVSidebarItem(title: tab.title, glyph: tab.glyph, isActive: selected == tab) {
                        selected = tab
                    }
                }
                Spacer()
            }
            .padding(SVSpacing.s)
            .frame(minWidth: 180, idealWidth: 180, maxWidth: 200)
            .background(Color(red: 0.137, green: 0.137, blue: 0.145))
        } detail: {
            Group {
                switch selected {
                case .general:    GeneralTab(appState: appState, updaterService: updaterService)
                case .connection: ConnectionTab(appState: appState)
                case .syncTasks:  SyncTasksTab(appState: appState)
                case .changelog:  ChangelogTab()
                case .info:       InfoTab(appState: appState)
                }
            }
            .frame(minWidth: 520, minHeight: 460)
            .background(SVColor.windowBg)
        }
        .frame(width: 720, height: 540)
    }
}
