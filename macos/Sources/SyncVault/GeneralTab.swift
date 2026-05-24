import SwiftUI
import ServiceManagement

struct GeneralTab: View {
    @ObservedObject var appState: AppState
    @ObservedObject var updaterService: UpdaterService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("General").font(SVFont.bodyBold(17)).padding(.bottom, SVSpacing.xl)

                // STARTUP
                SVSectionLabel(text: "Startup")
                SVCard {
                    SVCardRow {
                        rowToggle(title: "Launch SyncVault at login",
                                  sub: "Sync resumes automatically when you log in",
                                  binding: $appState.launchAtLogin)
                    }
                    SVCardRow(isLast: true) {
                        rowToggle(title: "Hide dock icon",
                                  sub: "Menu bar only — saves Cmd-Tab space",
                                  binding: $appState.hideDockIcon)
                    }
                }
                .padding(.bottom, SVSpacing.l)

                // NOTIFICATIONS
                SVSectionLabel(text: "Notifications")
                SVCard {
                    SVCardRow { rowToggle(title: "Banner when sync completes",
                                          sub: "macOS notification after each task finishes",
                                          binding: $appState.notifyOnComplete) }
                    SVCardRow { rowToggle(title: "Banner on errors",
                                          sub: "Always recommended",
                                          binding: $appState.notifyOnError) }
                    SVCardRow(isLast: true) {
                        rowToggle(title: "Sound",
                                  sub: "Subtle chime on completion",
                                  binding: $appState.notifySound)
                    }
                }
                .padding(.bottom, SVSpacing.l)

                // BANDWIDTH
                SVSectionLabel(text: "Bandwidth")
                SVCard {
                    SVCardRow {
                        HStack(spacing: SVSpacing.xl) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Upload limit").font(SVFont.body(13))
                                Text("Caps outgoing bandwidth — set to unlimited for LAN")
                                    .font(SVFont.body(11)).foregroundStyle(SVColor.textSecondary)
                            }
                            Spacer()
                            Slider(value: $appState.uploadLimitMBps, in: 0...50).frame(width: 140)
                            Text(appState.uploadLimitMBps == 0 ? "∞" : String(format: "%.1f MB/s", appState.uploadLimitMBps))
                                .font(SVFont.mono(11)).foregroundStyle(SVColor.textSecondary)
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                    SVCardRow(isLast: true) {
                        HStack(spacing: SVSpacing.xl) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Concurrent uploads").font(SVFont.body(13))
                                Text("More = faster on LAN, but uses more memory")
                                    .font(SVFont.body(11)).foregroundStyle(SVColor.textSecondary)
                            }
                            Spacer()
                            Picker("", selection: $appState.concurrentUploads) {
                                Text("1").tag(1); Text("2").tag(2); Text("4").tag(4); Text("8").tag(8)
                            }
                            .pickerStyle(.segmented).frame(width: 160)
                        }
                    }
                }
                .padding(.bottom, SVSpacing.l)

                // UPDATES — Check Now + auto-check + optional banner ONLY.
                // No download/install UI here; that lives in the dedicated update window (Task 24).
                SVSectionLabel(text: "Updates")
                SVCard {
                    SVCardRow {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Check for updates now").font(SVFont.body(13))
                                Text("Compares this build to the latest published release")
                                    .font(SVFont.body(11)).foregroundStyle(SVColor.textSecondary)
                            }
                            Spacer()
                            Button("Check Now") { updaterService.checkForUpdates() }.controlSize(.small)
                        }
                    }
                    SVCardRow(isLast: true) {
                        rowToggle(title: "Automatically check for updates",
                                  sub: "Every launch + once per day",
                                  binding: $updaterService.automaticallyChecksForUpdates)
                    }
                }

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

    @ViewBuilder
    private func rowToggle(title: String, sub: String, binding: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: SVSpacing.xl) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(SVFont.body(13))
                Text(sub).font(SVFont.body(11)).foregroundStyle(SVColor.textSecondary)
            }
            Spacer()
            Toggle("", isOn: binding).labelsHidden()
        }
    }
}
