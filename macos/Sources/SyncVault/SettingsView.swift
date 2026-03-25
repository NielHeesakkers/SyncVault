import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var updaterService: UpdaterService
    @State private var selectedTab: SettingsTab = .connection

    enum SettingsTab: String, CaseIterable {
        case connection = "Connection"
        case syncTasks = "Sync Tasks"
        case general = "General"
        case changelog = "Changelog"
        case info = "Info"

        var icon: String {
            switch self {
            case .connection: return "network"
            case .syncTasks: return "arrow.triangle.2.circlepath"
            case .general: return "gear"
            case .changelog: return "doc.text"
            case .info: return "info.circle"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 13))
                                .frame(width: 20)
                            Text(tab.rawValue)
                                .font(.system(size: 13))
                        }
                        .foregroundColor(selectedTab == tab ? .white : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            selectedTab == tab
                                ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor)
                                : nil
                        )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Text("v\(appVersion)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.5))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            .padding(.top, 12)
            .frame(width: 150)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            // Divider
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)

            // Content
            Group {
                switch selectedTab {
                case .connection:
                    ConnectionTab(appState: appState)
                case .syncTasks:
                    SyncTasksTab(appState: appState)
                case .general:
                    GeneralTab(updaterService: updaterService)
                case .changelog:
                    ChangelogTab()
                case .info:
                    InfoTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 600, height: 420)
        .onAppear {
            // Bring settings window to front
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows {
                    if window.isVisible && window.contentView != nil && window.styleMask.contains(.titled) {
                        window.level = .floating
                        window.makeKeyAndOrderFront(nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            window.level = .normal
                        }
                        break
                    }
                }
            }
        }
    }
}
