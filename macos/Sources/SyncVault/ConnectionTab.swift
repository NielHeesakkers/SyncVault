import SwiftUI

struct ConnectionTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Connection")
                    .font(SVFont.bodyBold(17))
                    .padding(.bottom, SVSpacing.xl)

                // 3 LIVE HEALTH CARDS
                healthCards.padding(.bottom, SVSpacing.xl)

                // SERVER
                SVSectionLabel(text: "Server")
                serverCard.padding(.bottom, SVSpacing.l)

                // VERSIONS
                SVSectionLabel(text: "Versions")
                versionsCard.padding(.bottom, SVSpacing.l)

                // THIS DEVICE
                SVSectionLabel(text: "This device")
                deviceCard

                // ACTIONS
                HStack(spacing: SVSpacing.m) {
                    Button("Reconnect") { Task { await appState.reconnect() } }
                        .buttonStyle(.borderedProminent)
                        .tint(SVColor.accentBlue)
                    Button("Test Server") { Task { await appState.testServer() } }
                        .buttonStyle(.bordered)
                }
                .padding(.top, SVSpacing.xl)
            }
            .padding(SVSpacing.xxxl)
        }
        .background(SVColor.windowBg)
    }

    private var healthCards: some View {
        HStack(spacing: SVSpacing.l) {
            healthCard(label: "Status",
                       value: appState.isConnected ? "Online" : "Offline",
                       color: appState.isConnected ? SVColor.accentGreen : SVColor.accentRed,
                       sub: appState.isConnected ? "Connected" : "Disconnected")
            healthCard(label: "Latency",
                       value: appState.latencyMs.map(String.init) ?? "—",
                       unit: " ms", color: SVColor.textPrimary,
                       sub: "Avg last 60s")
            healthCard(label: "Up since",
                       value: appState.serverUptimeShort,
                       color: SVColor.textPrimary,
                       sub: "Server uptime")
        }
    }

    private func healthCard(label: String, value: String, unit: String = "",
                            color: Color, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(SVFont.sectionLabel)
                .foregroundStyle(SVColor.textTertiary)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                if color == SVColor.accentGreen || color == SVColor.accentRed {
                    Circle().fill(color).frame(width: 8, height: 8)
                        .shadow(color: color.opacity(0.6), radius: 4)
                }
                Text(value)
                    .font(SVFont.monoBold(18))
                    .foregroundStyle(color)
                Text(unit)
                    .font(SVFont.body(13))
                    .foregroundStyle(SVColor.textSecondary)
            }
            Text(sub)
                .font(SVFont.mono(10.5))
                .foregroundStyle(SVColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SVSpacing.xl)
        .background(SVColor.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: SVRadius.card))
    }

    private var serverCard: some View {
        SVCard {
            infoRow(label: "URL", value: appState.serverURL.isEmpty ? "—" : appState.serverURL, action: nil)
            infoRow(label: "Signed in as", value: appState.username.isEmpty ? "—" : appState.username, action: "Sign Out") {
                Task { await appState.signOut() }
            }
            infoRow(label: "TLS certificate", value: "—", action: nil, isLast: true)
        }
    }

    private var versionsCard: some View {
        SVCard {
            infoRow(label: "Server", value: appState.serverVersion ?? "—",
                    trailingPill: appState.serverVersion != nil ? "connected" : "—",
                    pillKind: appState.serverVersion != nil ? .live : .neutral)
            infoRow(label: "Client (this Mac)", value: Bundle.main.shortVersion, trailingPill: "running")
            infoRow(label: "Push protocol", value: "SSE · /api/events",
                    trailingPill: appState.sseConnected ? "connected" : "disconnected",
                    pillKind: appState.sseConnected ? .live : .neutral,
                    isLast: true)
        }
    }

    private var deviceCard: some View {
        SVCard {
            infoRow(label: "Name", value: Host.current().localizedName ?? "This Mac", action: nil)
            infoRow(label: "Device ID",
                    value: appState.deviceID.isEmpty ? "—" : (String(appState.deviceID.prefix(13)) + "…"),
                    action: "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(appState.deviceID, forType: .string)
            }
            infoRow(label: "Registered", value: appState.deviceRegisteredDateFormatted, action: nil, isLast: true)
        }
    }

    private func infoRow(label: String, value: String, action: String? = nil,
                         trailingPill: String? = nil,
                         pillKind: SVStatusPill.Kind = .neutral,
                         isLast: Bool = false,
                         perform: (() -> Void)? = nil) -> some View {
        SVCardRow(isLast: isLast) {
            HStack(spacing: SVSpacing.xl) {
                Text(label)
                    .font(SVFont.body(12))
                    .foregroundStyle(SVColor.textSecondary)
                    .frame(width: 140, alignment: .leading)
                Text(value)
                    .font(SVFont.mono(12))
                    .foregroundStyle(SVColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let p = trailingPill {
                    SVStatusPill(text: p, kind: pillKind)
                }
                if let a = action {
                    Button(a) { perform?() }
                        .buttonStyle(.plain)
                        .font(SVFont.body(12))
                        .foregroundStyle(SVColor.accentBlue)
                }
            }
        }
    }
}

// MARK: - Labeled Field Helper (used by SyncTasksTab)

struct LabeledField<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 70, alignment: .trailing)
            content
        }
    }
}
