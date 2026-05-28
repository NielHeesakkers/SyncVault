import SwiftUI

/// Read-only timeline of a file's stored versions with a Restore button per
/// row. No textual diff (binary files would be useless anyway); the goal is
/// to let the user say "yes that one from yesterday at 3pm" and recover it
/// without bouncing to the web UI.
///
/// Opened as a sheet from anywhere we have a file ID and a friendly name —
/// today: right-click on a Recently-Changed row in the menu bar.
struct VersionDiffView: View {
    @ObservedObject var appState: AppState
    let fileID: String
    let fileName: String
    @Environment(\.dismiss) private var dismiss

    @State private var versions: [FileVersion] = []
    @State private var loading = false
    @State private var error: String? = nil
    @State private var pendingRestore: FileVersion? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 380)
        .background(SVColor.windowBg)
        .onAppear { Task { await load() } }
        .confirmationDialog(
            pendingRestore.map { "Restore version \($0.versionNum)? Current version will be saved as a new version first." } ?? "",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore") { Task { await restoreSelection() } }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Version history").font(SVFont.bodyBold(15))
                Text(fileName).font(SVFont.mono(11)).foregroundStyle(SVColor.textSecondary)
            }
            Spacer()
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh")
        }
        .padding(.horizontal, SVSpacing.xl)
        .padding(.vertical, SVSpacing.l)
    }

    private var list: some View {
        Group {
            if loading && versions.isEmpty {
                Spacer(); ProgressView("Loading versions…").font(SVFont.body(12)); Spacer()
            } else if versions.isEmpty {
                Spacer()
                VStack(spacing: SVSpacing.m) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28))
                        .foregroundStyle(SVColor.textSecondary.opacity(0.6))
                    Text("No previous versions").font(SVFont.body(12)).foregroundStyle(SVColor.textSecondary)
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(versions) { v in
                            row(v)
                            if v.id != versions.last?.id {
                                Divider().padding(.leading, SVSpacing.xl)
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(_ v: FileVersion) -> some View {
        HStack(spacing: SVSpacing.xl) {
            // Version number badge — mono so all rows align even if numbers differ in digit count.
            Text("v\(v.versionNum)")
                .font(SVFont.monoBold(13))
                .frame(width: 44, alignment: .leading)
                .foregroundStyle(SVColor.accentBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text(formatDate(v.createdAt)).font(SVFont.body(12))
                HStack(spacing: SVSpacing.m) {
                    Text(formatBytes(v.size))
                    if let h = v.contentHash { Text(String(h.prefix(10)) + "…") }
                    if let by = v.createdBy { Text("by \(by)") }
                }
                .font(SVFont.mono(10.5))
                .foregroundStyle(SVColor.textSecondary)
            }
            Spacer()
            Button("Restore") { pendingRestore = v }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, SVSpacing.xl)
        .padding(.vertical, SVSpacing.m)
    }

    private var footer: some View {
        HStack {
            if let err = error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SVColor.accentRed)
                Text(err).font(SVFont.body(11)).foregroundStyle(SVColor.accentRed).lineLimit(2)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, SVSpacing.xl)
        .padding(.vertical, SVSpacing.l)
    }

    // MARK: - Actions

    private func load() async {
        guard let client = appState.apiClient else { return }
        loading = true; error = nil
        defer { loading = false }
        do { versions = try await client.listVersions(fileID: fileID) }
        catch { self.error = "Could not load versions: \(error.localizedDescription)" }
    }

    private func restoreSelection() async {
        guard let v = pendingRestore, let client = appState.apiClient else { return }
        pendingRestore = nil
        loading = true; error = nil
        defer { loading = false }
        do {
            try await client.restoreVersion(fileID: fileID, versionNum: v.versionNum)
            await load()
        } catch {
            self.error = "Restore failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func formatBytes(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: b)
    }

    private func formatDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return iso }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: date)
    }
}
