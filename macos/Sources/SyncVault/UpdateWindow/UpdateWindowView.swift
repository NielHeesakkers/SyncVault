import SwiftUI

struct UpdateWindowView: View {
    @ObservedObject var controller: UpdateWindowController

    var body: some View {
        VStack(spacing: 0) {
            content
            actionBar
        }
        .background(SVColor.windowBg)
        .frame(width: 480)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .available:                 availableContent
        case .downloading(let progress): downloadingContent(progress)
        case .ready:                     readyContent
        case .error(let msg):            errorContent(msg)
        }
    }

    // MARK: - State content

    private var availableContent: some View {
        VStack(alignment: .leading, spacing: SVSpacing.xl) {
            hero(symbol: "↑",
                 title: "A new version is available",
                 sub: "v\(Bundle.main.shortVersion) → v\(controller.version) · \(formatBytes(controller.sizeBytes))",
                 newAccent: SVColor.accentGreen)
            SVSectionLabel(text: "What's new")
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(controller.changelog, id: \.self) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•").foregroundStyle(SVColor.textSecondary)
                            Text(.init(line)).font(SVFont.body(12))
                        }
                    }
                }
                .padding(SVSpacing.xl)
            }
            .frame(maxHeight: 160)
            .background(SVColor.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: SVRadius.card))
        }
        .padding(SVSpacing.xxl)
    }

    private func downloadingContent(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: SVSpacing.xl) {
            hero(symbol: "↓",
                 title: "Downloading v\(controller.version)",
                 sub: "\(formatBytes(Int64(Double(controller.sizeBytes) * progress))) of \(formatBytes(controller.sizeBytes)) · \(Int(progress * 100))%")
            SVProgressStrip(filename: "SyncVault-\(controller.version).dmg",
                            progress: progress, fillColor: SVColor.accentBlue)
                .padding(SVSpacing.xl)
                .background(SVColor.cardBg)
                .clipShape(RoundedRectangle(cornerRadius: SVRadius.card))
        }
        .padding(SVSpacing.xxl)
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: SVSpacing.xl) {
            hero(symbol: "✓",
                 title: "v\(controller.version) is ready to install",
                 sub: "Download complete · app relaunches automatically",
                 iconGradient: [SVColor.accentGreen, SVColor.accentBlue],
                 shadow: SVColor.accentGreen)
            SVProgressStrip(filename: "SyncVault-\(controller.version).dmg",
                            progress: 1.0, fillColor: SVColor.accentGreen, trailingText: "100%")
                .padding(SVSpacing.xl)
                .background(SVColor.cardBg)
                .clipShape(RoundedRectangle(cornerRadius: SVRadius.card))
        }
        .padding(SVSpacing.xxl)
    }

    private func errorContent(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: SVSpacing.l) {
            hero(symbol: "!",
                 title: "Update failed",
                 sub: msg,
                 iconGradient: [SVColor.accentRed, SVColor.accentOrange],
                 shadow: SVColor.accentRed)
        }
        .padding(SVSpacing.xxl)
    }

    // MARK: - Hero block

    private func hero(symbol: String,
                      title: String,
                      sub: String,
                      newAccent: Color? = nil,
                      iconGradient: [Color] = [SVColor.accentBlue, SVColor.accentPurple],
                      shadow: Color = SVColor.accentBlue) -> some View {
        HStack(spacing: SVSpacing.xl) {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: iconGradient,
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 56, height: 56)
                .overlay(Text(symbol).font(.system(size: 28)).foregroundStyle(.white))
                .shadow(color: shadow.opacity(0.3), radius: 18, y: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 18, weight: .semibold))
                if let newAccent {
                    HStack(spacing: 0) {
                        let parts = sub.split(separator: "→").map { String($0).trimmingCharacters(in: .whitespaces) }
                        if parts.count == 2 {
                            Text(parts[0]).font(SVFont.mono(12)).foregroundStyle(SVColor.textSecondary)
                            Text(" → ").font(SVFont.mono(12)).foregroundStyle(SVColor.textTertiary)
                            Text(parts[1]).font(SVFont.mono(12)).foregroundStyle(newAccent)
                        } else {
                            Text(sub).font(SVFont.mono(12)).foregroundStyle(SVColor.textSecondary)
                        }
                    }
                } else {
                    Text(sub).font(SVFont.mono(12)).foregroundStyle(SVColor.textSecondary)
                }
            }
            Spacer()
        }
    }

    // MARK: - Action bar (varies per state)

    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: SVSpacing.m) {
            switch controller.state {
            case .available:
                Button("Skip this version") { skipThisVersion() }
                    .buttonStyle(.plain)
                    .foregroundStyle(SVColor.textSecondary)
                Spacer()
                Button("Remind me later") { NSApp.keyWindow?.close() }
                    .buttonStyle(.plain)
                    .foregroundStyle(SVColor.textSecondary)
                Button("Install Update") { controller.install() }
                    .buttonStyle(.borderedProminent)
                    .tint(SVColor.accentBlue)
            case .downloading:
                Spacer()
                Button("Cancel") { controller.cancel(); NSApp.keyWindow?.close() }
                    .buttonStyle(.plain)
                    .foregroundStyle(SVColor.textSecondary)
            case .ready:
                Button("Install on Quit") { NSApp.keyWindow?.close() }
                    .buttonStyle(.plain)
                    .foregroundStyle(SVColor.textSecondary)
                Spacer()
                Button("Quit & Install") { controller.quitAndInstall() }
                    .buttonStyle(.borderedProminent)
                    .tint(SVColor.accentGreen)
            case .error:
                Spacer()
                Button("OK") { NSApp.keyWindow?.close() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, SVSpacing.xxl)
        .padding(.vertical, SVSpacing.xl)
        .background(Color(red: 0.137, green: 0.137, blue: 0.145))
        .overlay(Rectangle().fill(SVColor.hairline).frame(height: 1), alignment: .top)
        .font(SVFont.body(12))
    }

    private func skipThisVersion() {
        UserDefaults.standard.set(controller.version, forKey: "skippedUpdateVersion")
        NSApp.keyWindow?.close()
    }

    private func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, b), countStyle: .file)
    }
}

#Preview("Available") {
    UpdateWindowView(controller: {
        let c = UpdateWindowController(
            version: "3.2.0",
            changelog: ["**New design system** rolling out", "Bug fixes", "Performance improvements"],
            sizeBytes: 3_000_000
        )
        return c
    }())
}

#Preview("Downloading") {
    UpdateWindowView(controller: {
        let c = UpdateWindowController(version: "3.2.0", changelog: [], sizeBytes: 3_000_000)
        c.install()
        c.updateProgress(0.64)
        return c
    }())
}

#Preview("Ready") {
    UpdateWindowView(controller: {
        let c = UpdateWindowController(version: "3.2.0", changelog: [], sizeBytes: 3_000_000)
        c.install()
        c.downloadCompleted(at: URL(fileURLWithPath: "/tmp/x.dmg"))
        return c
    }())
}
