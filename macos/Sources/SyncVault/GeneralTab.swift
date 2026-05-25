import SwiftUI
import ServiceManagement

struct GeneralTab: View {
    @ObservedObject var appState: AppState
    @ObservedObject var updaterService: UpdaterService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("General")
                    .font(SVFont.bodyBold(17))
                    .padding(.bottom, SVSpacing.l)

                // STARTUP — single-line rows; mockup intentionally drops subtitles.
                SVSectionLabel(text: "Startup")
                SVCard {
                    SVCardRow { rowToggle(title: "Launch at login", binding: $appState.launchAtLogin) }
                    SVCardRow(isLast: true) {
                        rowToggle(title: "Hide dock icon", binding: $appState.hideDockIcon)
                    }
                }
                .padding(.bottom, SVSpacing.l)

                // NOTIFICATIONS
                SVSectionLabel(text: "Notifications")
                SVCard {
                    SVCardRow { rowToggle(title: "When sync completes", binding: $appState.notifyOnComplete) }
                    SVCardRow { rowToggle(title: "When sync fails", binding: $appState.notifyOnError) }
                    SVCardRow(isLast: true) {
                        rowToggle(title: "Play sound", binding: $appState.notifySound)
                    }
                }
                .padding(.bottom, SVSpacing.l)

                // BANDWIDTH
                SVSectionLabel(text: "Bandwidth")
                SVCard {
                    SVCardRow {
                        HStack(spacing: SVSpacing.xl) {
                            Text("Upload limit").font(SVFont.body(13))
                            Slider(value: $appState.uploadLimitMBps, in: 0...50)
                            Text(appState.uploadLimitMBps == 0 ? "∞" : String(format: "%.1f", appState.uploadLimitMBps))
                                .font(SVFont.mono(11))
                                .foregroundStyle(SVColor.textSecondary)
                                .frame(width: 32, alignment: .trailing)
                            Text("MB/s").font(SVFont.body(11)).foregroundStyle(SVColor.textSecondary)
                        }
                    }
                    SVCardRow(isLast: true) {
                        HStack(spacing: SVSpacing.xl) {
                            Text("Concurrent uploads").font(SVFont.body(13))
                            Spacer()
                            Picker("", selection: $appState.concurrentUploads) {
                                Text("1").tag(1); Text("2").tag(2); Text("4").tag(4); Text("8").tag(8)
                            }
                            .pickerStyle(.segmented).frame(width: 160).labelsHidden()
                        }
                    }
                }
                .padding(.bottom, SVSpacing.l)

                // UPDATES
                SVSectionLabel(text: "Updates")
                SVCard {
                    SVCardRow {
                        HStack {
                            Text("Check for updates now").font(SVFont.body(13))
                            Spacer()
                            Button("Check Now") { updaterService.checkForUpdates() }.controlSize(.small)
                        }
                    }
                    SVCardRow(isLast: true) {
                        rowToggle(title: "Automatically check for updates",
                                  binding: $updaterService.automaticallyChecksForUpdates)
                    }
                }

                // Available-update banner stays — orange chip so it stands out from
                // the configuration rows above.
                if let version = updaterService.availableVersion {
                    HStack {
                        HStack(spacing: 8) {
                            Text("↑").foregroundStyle(SVColor.accentOrange)
                            Text("v\(version) available")
                                .font(SVFont.body(12.5)).foregroundStyle(SVColor.accentOrange)
                        }
                        Spacer()
                        Button("Show update…") {
                            updaterService.openUpdateWindow()
                        }
                        .buttonStyle(.plain)
                        .font(SVFont.body(12))
                        .foregroundStyle(SVColor.accentBlue)
                    }
                    .padding(.horizontal, SVSpacing.xl).padding(.vertical, SVSpacing.l)
                    .background(SVColor.accentOrange.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: SVRadius.card))
                    .padding(.top, SVSpacing.m)
                }
            }
            .padding(SVSpacing.xxxl)
        }
        .background(SVColor.windowBg)
    }

    /// Single-line toggle row: just title and switch. No subtitle.
    @ViewBuilder
    private func rowToggle(title: String, binding: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: SVSpacing.xl) {
            Text(title).font(SVFont.body(13))
            Spacer()
            Toggle("", isOn: binding).labelsHidden()
        }
    }
}
