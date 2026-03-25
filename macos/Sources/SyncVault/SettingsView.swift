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

        var iconColor: Color {
            switch self {
            case .connection: return .blue
            case .syncTasks: return .green
            case .general: return Color(nsColor: .systemGray)
            case .changelog: return .orange
            case .info: return .cyan
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Sidebar
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 9) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(tab.iconColor.gradient)
                                    .frame(width: 26, height: 26)
                                Image(systemName: tab.icon)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white)
                            }
                            Text(tab.rawValue)
                                .font(.system(size: 13))
                                .foregroundColor(selectedTab == tab ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background {
                            if selectedTab == tab {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.accentColor.opacity(0.15))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5)
                                    )
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Bottom version display
                HStack(spacing: 5) {
                    Image(systemName: "app.badge")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("v\(appVersion)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.4))
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .padding(.top, 12)
            .frame(width: 158)
            .background(
                VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
            )

            // MARK: - Divider
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)

            // MARK: - Content
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
        .frame(width: 620, height: 440)
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
