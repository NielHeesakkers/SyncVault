import SwiftUI

struct ChangelogTab: View {
    private let entries = ChangelogEntry.parseBundle()
    private let currentVersion = Bundle.main.shortVersion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SVSpacing.xl) {
                Text("Changelog").font(SVFont.bodyBold(17))
                ForEach(entries) { entry in
                    versionCard(entry)
                }
            }
            .padding(SVSpacing.xxxl)
        }
        .background(SVColor.windowBg)
    }

    private func versionCard(_ entry: ChangelogEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: SVSpacing.l) {
                Text(entry.version)
                    .font(SVFont.monoBold(14))
                    .foregroundStyle(entry.version == currentVersion ? SVColor.accentGreen : SVColor.textPrimary)
                if entry.version == currentVersion {
                    Text("· current").font(SVFont.body(11)).foregroundStyle(SVColor.textSecondary)
                }
                Text(entry.date).font(SVFont.mono(11)).foregroundStyle(SVColor.textTertiary)
                if let tag = entry.tag {
                    Text(tag.uppercased())
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(SVColor.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(SVColor.subtleBg)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(entry.bullets, id: \.self) { bullet in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").foregroundStyle(SVColor.textSecondary)
                        Text(.init(bullet)).font(SVFont.body(12.5))
                    }
                }
            }
            .padding(SVSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SVColor.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: SVRadius.card))
        }
    }
}

struct ChangelogEntry: Identifiable {
    var id: String { version }
    let version: String
    let date: String
    let tag: String?
    let bullets: [String]

    /// Parse `internal/api/rest/changelog.txt` shipped as a bundle resource.
    /// Format:
    ///   ## [3.2.0] — 2026-05-24
    ///   - bullet text
    ///   - **bold** bullet
    ///
    ///   ## [3.1.6] — 2026-05-24 (server-only)
    ///   - ...
    static func parseBundle() -> [ChangelogEntry] {
        guard let url = Bundle.main.url(forResource: "changelog", withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var entries: [ChangelogEntry] = []
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var pending: (version: String, date: String, tag: String?, bullets: [String])? = nil
        let header = try! NSRegularExpression(pattern: #"^##\s*\[([^\]]+)\]\s*[—-]\s*([^()]+?)(?:\s*\(([^)]+)\))?\s*$"#)
        for line in lines {
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            if let m = header.firstMatch(in: line, range: range) {
                if let p = pending { entries.append(.init(version: p.version, date: p.date, tag: p.tag, bullets: p.bullets)) }
                let v = nsLine.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let d = nsLine.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                let t = m.range(at: 3).location != NSNotFound
                    ? nsLine.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
                    : nil
                pending = (v, d, t, [])
            } else if line.hasPrefix("- ") {
                pending?.bullets.append(String(line.dropFirst(2)))
            }
        }
        if let p = pending { entries.append(.init(version: p.version, date: p.date, tag: p.tag, bullets: p.bullets)) }
        return entries
    }
}
