import SwiftUI
import AppKit

struct InfoTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("About").font(SVFont.bodyBold(17)).padding(.bottom, SVSpacing.xl)

                heroCard.padding(.bottom, SVSpacing.xl)

                SVSectionLabel(text: "Build")
                buildCard.padding(.bottom, SVSpacing.xl)

                SVSectionLabel(text: "Links")
                linksRow.padding(.bottom, SVSpacing.xl)

                Text("Made by the SyncVault team · MIT license\nUses Sparkle for updates, SQLite for metadata.")
                    .font(SVFont.body(12))
                    .foregroundStyle(SVColor.textSecondary)
                    .lineSpacing(2)
            }
            .padding(SVSpacing.xxxl)
        }
        .background(SVColor.windowBg)
    }

    private var heroCard: some View {
        HStack(spacing: SVSpacing.xxl) {
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(
                    colors: [SVColor.accentBlue, SVColor.accentPurple],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 64, height: 64)
                .overlay(Text("📁").font(.system(size: 32)))
                .shadow(color: SVColor.accentBlue.opacity(0.35), radius: 18, y: 6)
            VStack(alignment: .leading, spacing: 4) {
                Text("SyncVault").font(.system(size: 22, weight: .bold))
                Text("Version \(Bundle.main.shortVersion) (build \(Bundle.main.buildNumber))")
                    .font(SVFont.mono(12)).foregroundStyle(SVColor.textSecondary)
                Text(systemString)
                    .font(SVFont.mono(12)).foregroundStyle(SVColor.textSecondary)
            }
            Spacer()
        }
        .padding(SVSpacing.xxl)
        .background(SVColor.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var buildCard: some View {
        SVCard {
            infoRow(label: "Git commit", value: Bundle.main.gitSHA, action: "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Bundle.main.gitSHA, forType: .string)
            }
            infoRow(label: "Build date", value: Bundle.main.buildDate, action: nil) {}
            infoRow(label: "Sparkle key", value: "EdDSA", action: nil, isLast: true) {}
        }
    }

    private var linksRow: some View {
        HStack(spacing: SVSpacing.m) {
            linkChip("🌐", host(of: appState.serverURL)) { openURL(appState.serverURL) }
            linkChip("⌥", "GitHub") { openURL("https://github.com/NielHeesakkers/SyncVault") }
            linkChip("✉", "Report issue") { openURL("https://github.com/NielHeesakkers/SyncVault/issues/new") }
            linkChip("📋", "Diagnostics…") { exportDiagnostics() }
            Spacer()
        }
    }

    private func linkChip(_ glyph: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(glyph)
                Text(label).font(SVFont.body(12))
            }
            .padding(.horizontal, SVSpacing.xl).padding(.vertical, 7)
            .background(SVColor.subtleBg)
            .clipShape(RoundedRectangle(cornerRadius: SVRadius.card))
        }
        .buttonStyle(.plain)
        .foregroundStyle(SVColor.textPrimary)
    }

    private func infoRow(label: String, value: String, action: String?,
                         isLast: Bool = false, perform: @escaping () -> Void) -> some View {
        SVCardRow(isLast: isLast) {
            HStack(spacing: SVSpacing.xl) {
                Text(label).font(SVFont.body(12)).foregroundStyle(SVColor.textSecondary)
                    .frame(width: 130, alignment: .leading)
                Text(value).font(SVFont.mono(12)).foregroundStyle(SVColor.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if let action {
                    Button(action, action: perform)
                        .buttonStyle(.plain)
                        .font(SVFont.body(12))
                        .foregroundStyle(SVColor.accentBlue)
                }
            }
        }
    }

    private var systemString: String {
        let p = ProcessInfo.processInfo
        let v = p.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion) · \(p.machineHardwareName)"
    }

    private func host(of urlString: String) -> String {
        URL(string: urlString)?.host ?? (urlString.isEmpty ? "your server" : urlString)
    }

    private func openURL(_ s: String) {
        guard !s.isEmpty, let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }

    private func exportDiagnostics() {
        // Phase 5+ — for now no-op
    }
}

extension Bundle {
    var buildNumber: String { infoDictionary?["CFBundleVersion"] as? String ?? "0" }
    var gitSHA: String { infoDictionary?["GitSHA"] as? String ?? "—" }
    var buildDate: String { infoDictionary?["BuildDate"] as? String ?? "—" }
}

extension ProcessInfo {
    var machineHardwareName: String {
        var size: size_t = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
