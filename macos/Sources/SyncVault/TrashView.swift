import SwiftUI

/// In-app trash management — list of deleted files with restore + permanent-
/// delete actions. Replaces the previous "go to web app to clean up" flow.
///
/// Reachable from the menu bar's "Open Trash…" row. Loads `/api/trash` on
/// appear, refreshes on demand, and lets the user:
///  * select one or many files
///  * Restore (POST /api/files/{id}/restore)
///  * Permanently delete (DELETE /api/trash/{id}) — confirmed
///  * Empty trash (DELETE /api/trash) — double-confirmed
struct TrashView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var files: [TrashedFile] = []
    @State private var selection: Set<String> = []
    @State private var loading = false
    @State private var error: String? = nil
    @State private var pendingPurge = false
    @State private var pendingPermDelete = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 480)
        .background(SVColor.windowBg)
        .onAppear { Task { await load() } }
        .confirmationDialog(
            "Permanently delete \(selection.count) item(s)? This cannot be undone.",
            isPresented: $pendingPermDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await permanentlyDeleteSelection() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Empty trash? All \(files.count) deleted item(s) will be permanently removed and cannot be recovered.",
            isPresented: $pendingPurge,
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) { Task { await purge() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Trash")
                .font(SVFont.bodyBold(17))
            Text("\(files.count) item\(files.count == 1 ? "" : "s")")
                .font(SVFont.mono(12))
                .foregroundStyle(SVColor.textSecondary)
            Spacer()
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(.horizontal, SVSpacing.xl)
        .padding(.vertical, SVSpacing.l)
    }

    private var list: some View {
        Group {
            if loading && files.isEmpty {
                Spacer()
                ProgressView("Loading trash…")
                    .font(SVFont.body(12))
                    .foregroundStyle(SVColor.textSecondary)
                Spacer()
            } else if files.isEmpty {
                Spacer()
                VStack(spacing: SVSpacing.m) {
                    Image(systemName: "trash")
                        .font(.system(size: 32))
                        .foregroundStyle(SVColor.textSecondary.opacity(0.6))
                    Text("Trash is empty")
                        .font(SVFont.body(13))
                        .foregroundStyle(SVColor.textSecondary)
                }
                Spacer()
            } else {
                Table(files, selection: $selection) {
                    TableColumn("Name") { f in
                        HStack(spacing: 8) {
                            Image(systemName: f.isDir ? "folder" : "doc")
                                .foregroundStyle(SVColor.textSecondary)
                            Text(f.name).font(SVFont.body(12))
                        }
                    }
                    TableColumn("Size") { f in
                        Text(formatBytes(f.size))
                            .font(SVFont.mono(11))
                            .foregroundStyle(SVColor.textSecondary)
                    }
                    .width(min: 80, ideal: 90, max: 110)
                    TableColumn("Deleted") { f in
                        Text(relativeDate(f.deletedAt))
                            .font(SVFont.mono(11))
                            .foregroundStyle(SVColor.textSecondary)
                    }
                    .width(min: 100, ideal: 120, max: 160)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: SVSpacing.m) {
            if let err = error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(SVColor.accentRed)
                Text(err)
                    .font(SVFont.body(11))
                    .foregroundStyle(SVColor.accentRed)
                    .lineLimit(2)
            }
            Spacer()
            Button("Empty Trash") { pendingPurge = true }
                .buttonStyle(.bordered)
                .disabled(files.isEmpty || loading)
            Button("Restore") { Task { await restoreSelection() } }
                .buttonStyle(.bordered)
                .disabled(selection.isEmpty || loading)
            Button("Delete Permanently") { pendingPermDelete = true }
                .buttonStyle(.borderedProminent)
                .tint(SVColor.accentRed)
                .disabled(selection.isEmpty || loading)
        }
        .padding(.horizontal, SVSpacing.xl)
        .padding(.vertical, SVSpacing.l)
    }

    // MARK: - Actions

    private func load() async {
        guard let client = appState.apiClient else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            files = try await client.listTrash()
            // Drop selection items that are no longer in the list.
            selection.formIntersection(Set(files.map(\.id)))
        } catch {
            self.error = "Could not load trash: \(error.localizedDescription)"
        }
    }

    private func restoreSelection() async {
        guard let client = appState.apiClient, !selection.isEmpty else { return }
        loading = true; error = nil
        defer { loading = false }
        for id in selection {
            do { try await client.restoreFromTrash(id: id) }
            catch { self.error = "Restore failed for \(id.prefix(8))…: \(error.localizedDescription)"; return }
        }
        selection.removeAll()
        await load()
    }

    private func permanentlyDeleteSelection() async {
        guard let client = appState.apiClient, !selection.isEmpty else { return }
        loading = true; error = nil
        defer { loading = false }
        for id in selection {
            do { try await client.permanentlyDelete(id: id) }
            catch { self.error = "Delete failed for \(id.prefix(8))…: \(error.localizedDescription)"; return }
        }
        selection.removeAll()
        await load()
    }

    private func purge() async {
        guard let client = appState.apiClient else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            try await client.purgeTrash()
            await load()
        } catch {
            self.error = "Empty trash failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func relativeDate(_ iso: String?) -> String {
        guard let iso = iso else { return "—" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "—" }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .short
        return rel.localizedString(for: date, relativeTo: Date())
    }
}
