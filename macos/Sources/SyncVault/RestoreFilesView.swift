import SwiftUI
import AppKit

/// Synology-style point-in-time browser.
///
/// Layout
/// ┌─────────────────────────────────────────────────────────────────┐
/// │ Niel / Werkmap / 180777_C&A_Denim                               │
/// ├─────────────┬───────────────────────────────────────────────────┤
/// │ ▾ Niel      │  Name           Size  v   Modified                │
/// │   ▾ Werkmap │  ───────────────────────────────────────────────  │
/// │      180310 │  denim_concept_v3.psd …                          │
/// │      180725 │  color_palette.ai     …                          │
/// │    [180777] │  brief.docx           …                          │
/// │      180805 │  references/                                      │
/// │   ▸ Dev     │                                                   │
/// ├─────────────┴───────────────────────────────────────────────────┤
/// │ Selected: 25 May 14:42                  [Download N files]      │
/// │ Apr               May                                Now│       │
/// │ ····|····|····|····|····|····|····|····|····|····|····|         │
/// │              ● ● ●        ● ●         ●●●●●●●●●●●○             │
/// └─────────────────────────────────────────────────────────────────┘
///
/// Key UX rules
///  * Tree on the left is a true hierarchy (root → sync folder → subfolders),
///    expandable, no "Up" button. Breadcrumb mirrors the selected tree node.
///  * Right pane shows snapshot files for the active folder. Multi-select.
///  * Bottom timeline auto-fits the available date range (first version on
///    the left, most recent + Now on the right), with orange dots on
///    days that have versions.
///  * Single Download button. Label adapts:
///    - 0 selection           → "Download Files" (disabled)
///    - N file(s) selected    → "Download N files"
///    - 1 folder selected     → "Download folder NAME"
///    Click → NSOpenPanel("Choose Folder"), streams files in.
struct RestoreFilesView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    // MARK: - Selection state

    /// Path from root → currently-viewed folder. Drives both the breadcrumb
    /// and the highlight in the tree. Empty when nothing is selected.
    @State private var path: [TreeNode] = []
    /// Top-level root folders (sync-task remotes).
    @State private var roots: [TreeNode] = []
    /// Lazily-loaded children indexed by parent ID.
    @State private var children: [String: [TreeNode]] = [:]
    /// Folder IDs that are currently expanded in the tree.
    @State private var expanded: Set<String> = []

    /// Snapshot contents — files at the current folder at `selectedSnapshot`.
    @State private var snapshotFiles: [FileAtTime] = []
    /// File-list multi-selection. Keys are FileAtTime.id.
    @State private var selection: Set<String> = []

    /// Available restore points for the current folder + which one is active.
    @State private var restorePoints: [Date] = []
    @State private var selectedSnapshot: Date? = nil
    @State private var hoveredPoint: Date? = nil
    /// In-memory cache of the most-recent snapshot per folder. Lets a re-visit
    /// (e.g. clicking back & forth in the tree) paint instantly while a
    /// silent background refresh runs. Cleared when the window closes.
    @State private var snapshotCache: [String: CachedSnapshot] = [:]

    private struct CachedSnapshot {
        let points: [Date]
        let snapshot: Date?
        let files: [FileAtTime]
    }
    /// Anchor row for shift-click range selection — the most recent plain
    /// single-click. Cmd-click does NOT move the anchor.
    @State private var selectionAnchor: String? = nil
    /// Tree split width — recalculated from the longest root name once roots
    /// load. HSplitView snapshots the first-render frame so a computed
    /// property would return the stale "no roots yet" fallback.
    @State private var treeWidth: CGFloat = 140
    /// True once roots + their children are loaded AND treeWidth has been
    /// calculated. HSplitView reads its child frames once on first appearance
    /// and ignores later updates, so we delay creating it until the width
    /// is final.
    @State private var treeReady = false

    @State private var loading = false
    @State private var error: String? = nil
    @State private var downloading = false

    /// Tree node. Carries enough info to be both a row and a routing target.
    struct TreeNode: Identifiable, Hashable {
        let id: String
        let name: String
        let parentID: String?  // nil for roots
    }

    var currentFolderID: String { path.last?.id ?? "" }
    var currentFolderName: String { path.last?.name ?? "" }


    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Custom split — HSplitView ignored idealWidth and locked to 50/50,
            // making the tree absurdly wide. HStack + draggable Divider gives
            // exact control over both default width and resize behavior.
            if !treeReady {
                Spacer().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    tree.frame(width: treeWidth)
                    SplitDivider(width: $treeWidth, min: 120, max: 480)
                    fileList.frame(maxWidth: .infinity)
                }
            }
            Divider()
            timeline
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(SVColor.windowBg)
        .onAppear { Task { await loadRoots() } }
    }

    // MARK: - Header / breadcrumb

    private var header: some View {
        HStack(spacing: 6) {
            if path.isEmpty {
                Text("Restore Files").font(SVFont.bodyBold(14))
            } else {
                ForEach(Array(path.enumerated()), id: \.offset) { i, node in
                    Button(node.name) {
                        // Jump back to ancestor by trimming path.
                        let trimmed = Array(path.prefix(i + 1))
                        path = trimmed
                        Task { await loadCurrent() }
                    }
                    .buttonStyle(.plain)
                    .font(i == path.count - 1 ? SVFont.bodyBold(12.5) : SVFont.body(12.5))
                    .foregroundStyle(i == path.count - 1 ? SVColor.textPrimary : SVColor.accentBlue)
                    if i < path.count - 1 {
                        Text("/").foregroundStyle(SVColor.textSecondary).font(SVFont.body(12.5))
                    }
                }
            }
            Spacer()
            if loading { ProgressView().scaleEffect(0.55) }
        }
        .padding(.horizontal, SVSpacing.xl)
        .padding(.vertical, SVSpacing.l)
    }

    // MARK: - Left tree

    private var tree: some View {
        // Flatten the visible tree to a (node, depth) list ONCE per render
        // and ForEach over it. Recursive @ViewBuilder forced AnyView wrapping
        // which erases view identity → SwiftUI couldn't diff and rebuilt the
        // whole tree on any state change. Flat = identifiable rows = cheap diff.
        let flat = flattenedTree()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(flat, id: \.node.id) { entry in
                    treeRow(entry.node, depth: entry.depth)
                }
            }
            .padding(.vertical, SVSpacing.m)
        }
        .background(SVColor.cardBg)
    }

    /// One visible row in the rendered tree — a node with its indent depth.
    private struct TreeEntry {
        let node: TreeNode
        let depth: Int
    }

    /// Walk roots + their expanded subtrees, producing a flat ordered list.
    /// Iterative (uses a stack) — avoids the recursion that previously forced
    /// AnyView. Runs once per body render.
    private func flattenedTree() -> [TreeEntry] {
        var out: [TreeEntry] = []
        out.reserveCapacity(roots.count * 4)
        for root in roots {
            appendBranch(root, depth: 0, into: &out)
        }
        return out
    }

    private func appendBranch(_ node: TreeNode, depth: Int, into out: inout [TreeEntry]) {
        out.append(TreeEntry(node: node, depth: depth))
        guard expanded.contains(node.id), let kids = children[node.id] else { return }
        for kid in kids {
            appendBranch(kid, depth: depth + 1, into: &out)
        }
    }

    private func treeRow(_ node: TreeNode, depth: Int) -> some View {
        let isExpanded = expanded.contains(node.id)
        let isSelected = currentFolderID == node.id
        return Button {
            Task { await selectFolder(node) }
        } label: {
            HStack(spacing: 4) {
                Spacer().frame(width: CGFloat(depth) * 14)
                // Disclosure triangle — clickable separately from row select
                Button {
                    Task { await toggleExpand(node) }
                } label: {
                    Text(isExpanded ? "▾" : "▸")
                        .font(.system(size: 9))
                        .foregroundStyle(SVColor.textSecondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                Image(systemName: depth == 0 ? "person.crop.circle.fill" : "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(depth == 0 ? SVColor.textSecondary : SVColor.accentBlue.opacity(0.8))
                Text(node.name)
                    .font(SVFont.body(12.5))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, SVSpacing.m)
            .padding(.vertical, 4)
            .background(isSelected ? SVColor.accentBlue.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Right pane (snapshot file list)

    private var fileList: some View {
        Group {
            if path.isEmpty {
                Spacer()
                VStack(spacing: SVSpacing.m) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28))
                        .foregroundStyle(SVColor.textSecondary.opacity(0.6))
                    Text("Pick a folder on the left to browse its restore points")
                        .font(SVFont.body(12.5))
                        .foregroundStyle(SVColor.textSecondary)
                }
                Spacer()
            } else {
                // List instead of Table so we can fully control row styling —
                // the soft accent-blue selection used by the left tree isn't
                // achievable with native Table (it forces system selection
                // color). Column headers faked with a manual header row above.
                VStack(spacing: 0) {
                    // Header row (faked since List has no column headers)
                    HStack(spacing: 0) {
                        Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Size").frame(width: 80, alignment: .leading)
                        Text("v").frame(width: 40, alignment: .leading)
                        Text("Modified").frame(width: 140, alignment: .leading)
                    }
                    .font(SVFont.body(10.5).weight(.semibold))
                    .foregroundStyle(SVColor.textSecondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, SVSpacing.xl)
                    .padding(.vertical, SVSpacing.m)
                    .background(SVColor.cardBg.opacity(0.4))
                    Divider()

                    // ScrollView + LazyVStack + FileRow-as-struct. The crucial
                    // bit is FileRow as its own View: it takes `isSelected: Bool`
                    // and `file: FileAtTime` as `let` props, so SwiftUI's
                    // structural diff skips rebuilding rows whose selection
                    // state didn't change. Without that, a single click rebuilt
                    // all ~100 rows in the body — visibly laggy.
                    if snapshotFiles.isEmpty && loading {
                        Spacer()
                        ProgressView().scaleEffect(0.7)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(snapshotFiles) { f in
                                    FileRow(
                                        file: f,
                                        isSelected: selection.contains(f.id),
                                        onClick: { mods in handleClick(f, modifiers: mods) },
                                        onDoubleClickFolder: {
                                            let node = TreeNode(id: f.id, name: f.name, parentID: currentFolderID)
                                            Task { await selectFolder(node) }
                                        },
                                        contextMenuItems: { contextMenuForRow(f) }
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Context-menu items for a right-clicked row. If the row is part of the
    /// current multi-selection, the menu acts on the whole selection;
    /// otherwise it acts on just this row.
    ///
    /// Four cases:
    ///   1 folder selected           → "Download folder NAME"
    ///   N folders, 0 files          → "Download N folders"
    ///   N files (no folders)        → "Download N files"
    ///   mix of folders + files      → "Download N items"
    @ViewBuilder
    private func contextMenuForRow(_ f: FileAtTime) -> some View {
        let resolved: [FileAtTime] = selection.contains(f.id)
            ? snapshotFiles.filter { selection.contains($0.id) }
            : [f]
        let folders = resolved.filter(\.isDir)
        let files = resolved.filter { !$0.isDir }

        if resolved.count == 1, let folder = folders.first {
            Button("Download folder \(folder.name)") {
                Task { await contextDownload(items: [folder]) }
            }
        } else if folders.isEmpty && !files.isEmpty {
            Button("Download \(files.count) file\(files.count == 1 ? "" : "s")") {
                Task { await contextDownload(items: files) }
            }
        } else if files.isEmpty && folders.count > 1 {
            Button("Download \(folders.count) folders") {
                Task { await contextDownload(items: folders) }
            }
        } else if !folders.isEmpty && !files.isEmpty {
            Button("Download \(resolved.count) items") {
                Task { await contextDownload(items: resolved) }
            }
        }
    }

    /// Translate a click + modifier set into selection-set mutations,
    /// Finder-style: plain = replace, cmd = toggle, shift = range from anchor.
    private func handleClick(_ f: FileAtTime, modifiers: NSEvent.ModifierFlags) {
        let id = f.id
        if modifiers.contains(.command) {
            // Toggle this row in the set; anchor stays put.
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else if modifiers.contains(.shift), let anchor = selectionAnchor,
                  let a = snapshotFiles.firstIndex(where: { $0.id == anchor }),
                  let b = snapshotFiles.firstIndex(where: { $0.id == id }) {
            let range = a <= b ? a...b : b...a
            selection = Set(snapshotFiles[range].map(\.id))
        } else {
            // Plain click — replace selection + move anchor.
            selection = [id]
            selectionAnchor = id
        }
    }

    // MARK: - Bottom timeline

    /// Download button label driven by selection. Key rule: an EMPTY file
    /// selection inside a folder means "download the whole folder I'm
    /// currently viewing" — not "nothing", so the button stays active and
    /// names the implicit target.
    private var downloadLabel: String {
        let selectedItems = snapshotFiles.filter { selection.contains($0.id) }
        let folders = selectedItems.filter(\.isDir)
        let files = selectedItems.filter { !$0.isDir }

        if selectedItems.isEmpty {
            // No explicit file selection → implicit target is the current folder.
            if !currentFolderName.isEmpty {
                return "Download folder \(currentFolderName)"
            }
            return "Download Files"   // truly nothing reachable
        }
        if folders.count == 1 && files.isEmpty {
            return "Download folder \(folders[0].name)"
        }
        return "Download \(selectedItems.count) file\(selectedItems.count == 1 ? "" : "s")"
    }

    /// Can download whenever a folder is open (implicit = whole folder) or
    /// the user has explicitly selected items.
    private var canDownload: Bool { !currentFolderID.isEmpty && !downloading }

    private var timeline: some View {
        VStack(spacing: 6) {
            HStack(spacing: SVSpacing.m) {
                if let s = selectedSnapshot {
                    Text("Selected: ").font(SVFont.body(11)).foregroundStyle(SVColor.textSecondary)
                    Text(formatTimestamp(s)).font(SVFont.mono(11)).foregroundStyle(SVColor.textPrimary)
                } else if !path.isEmpty {
                    Text("Pick a restore point").font(SVFont.body(11)).foregroundStyle(SVColor.textSecondary)
                }
                Spacer()
                if let err = error {
                    Text(err).font(SVFont.body(11)).foregroundStyle(SVColor.accentRed).lineLimit(1)
                }
                Button {
                    Task { await doDownload() }
                } label: {
                    Label(downloadLabel, systemImage: "arrow.down.circle.fill")
                        .font(SVFont.body(12.5))
                }
                .buttonStyle(.borderedProminent)
                .tint(SVColor.accentBlue)
                .controlSize(.small)
                .disabled(!canDownload)
            }
            timelineGraphics
        }
        .padding(.horizontal, SVSpacing.xl)
        .padding(.vertical, SVSpacing.l)
        .background(SVColor.cardBg)
    }

    /// Auto-fit timeline: spans from first restore point to "now". Month
    /// labels are positioned by date; day ticks fill the background; orange
    /// dots mark days with versions; green Now line at the right edge.
    private var timelineGraphics: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let (start, end) = timelineRange()
            let totalDays = max(1, daysBetween(start, end))

            ZStack(alignment: .topLeading) {
                // Day ticks
                Path { p in
                    let step = totalWidth / CGFloat(totalDays)
                    var x: CGFloat = 0
                    while x <= totalWidth {
                        p.move(to: CGPoint(x: x, y: 34))
                        p.addLine(to: CGPoint(x: x, y: 48))
                        x += step
                    }
                }
                .stroke(Color.white.opacity(0.10), lineWidth: 1)

                // Month labels
                ForEach(monthLabels(start: start, end: end), id: \.self) { m in
                    let frac = CGFloat(daysBetween(start, m.date)) / CGFloat(totalDays)
                    Text(m.label)
                        .font(SVFont.mono(10))
                        .foregroundStyle(SVColor.textSecondary)
                        .position(x: frac * totalWidth, y: 8)
                }

                // Version dots
                ForEach(restorePoints, id: \.self) { d in
                    let frac = CGFloat(daysBetween(start, d)) / CGFloat(totalDays)
                    let isSel = selectedSnapshot == d
                    Circle()
                        .fill(isSel ? SVColor.accentBlue : SVColor.accentOrange)
                        .frame(width: isSel ? 11 : 8, height: isSel ? 11 : 8)
                        .overlay(
                            Circle().stroke(isSel ? SVColor.accentBlue.opacity(0.35) : Color.clear, lineWidth: 3)
                        )
                        .position(x: frac * totalWidth, y: 26)
                        .onTapGesture {
                            selectedSnapshot = d
                            Task { await loadSnapshot(at: d) }
                        }
                        .onHover { hovering in
                            hoveredPoint = hovering ? d : nil
                        }
                }

                // Now marker
                Path { p in
                    p.move(to: CGPoint(x: totalWidth - 0.5, y: 16))
                    p.addLine(to: CGPoint(x: totalWidth - 0.5, y: 48))
                }
                .stroke(SVColor.accentGreen, lineWidth: 1)
                .opacity(0.7)
                Text("Now")
                    .font(SVFont.mono(10))
                    .foregroundStyle(SVColor.accentGreen)
                    .position(x: totalWidth - 12, y: 8)

                // Hover tooltip
                if let h = hoveredPoint {
                    let frac = CGFloat(daysBetween(start, h)) / CGFloat(totalDays)
                    Text(formatTimestamp(h))
                        .font(SVFont.mono(10))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.black.opacity(0.85))
                        .foregroundStyle(SVColor.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.12)))
                        .position(x: frac * totalWidth, y: -2)
                }
            }
        }
        .frame(height: 56)
    }

    // MARK: - Data loading

    private func loadRoots() async {
        guard let client = appState.apiClient else { return }
        loading = true; defer { loading = false }
        do {
            let dirs = try await client.listFiles(parentID: nil).filter(\.isDir)
            roots = dirs.map { TreeNode(id: $0.id, name: $0.name, parentID: nil) }

            guard let firstRoot = roots.first else { return }

            // Show the window IMMEDIATELY with a sensible default width.
            // Without this, the user stares at a blank pane while children +
            // changeDates + filesAtTime sequentially resolve. Path is set so
            // the breadcrumb is correct from frame one; the ProgressView in
            // the header signals data is still loading.
            path = [firstRoot]
            expanded.insert(firstRoot.id)
            treeWidth = 220
            treeReady = true

            // Fire children + snapshot in parallel (selectFolder does that).
            await selectFolder(firstRoot)

            // Refine width to fit the actual longest subfolder. Chrome on a
            // depth-1 row: padding(8) + indent(14) + HStack-spacing(4)
            // + triangle(12) + spacing(4) + icon(11) + spacing(4) + padding(8)
            // = 65, +8 for the scrollbar gutter.
            let kids = children[firstRoot.id] ?? []
            if !kids.isEmpty {
                let font = NSFont.systemFont(ofSize: 12)
                let widest = kids.map { ($0.name as NSString).size(withAttributes: [.font: font]).width }.max() ?? 60
                let chrome: CGFloat = 65 + 8
                treeWidth = ceil(widest) + chrome + 24
            }
        } catch {
            self.error = "Could not load folders: \(error.localizedDescription)"
        }
    }

    /// User clicked a folder in the tree — switch the right pane to it.
    /// Children (for the tree) and loadCurrent (changeDates → filesAtTime,
    /// for the right pane + timeline) are independent HTTP calls keyed on
    /// the same parent_id, so they run in parallel.
    private func selectFolder(_ node: TreeNode) async {
        path = buildPath(to: node)
        expanded.insert(node.id)
        selection.removeAll()
        selectionAnchor = nil

        // Optimistic UI: paint from cache instantly so the right pane snaps
        // to the new folder. loadCurrent below silently refreshes; if the
        // server's answer matches what we showed, nothing visibly changes.
        // No cache → clear stale data so the spinner appears.
        if let cached = snapshotCache[node.id] {
            restorePoints = cached.points
            selectedSnapshot = cached.snapshot
            snapshotFiles = cached.files
        } else {
            restorePoints = []
            selectedSnapshot = nil
            snapshotFiles = []
        }

        async let kidsLoad: () = loadChildrenIfNeeded(node)
        async let currentLoad: () = loadCurrent()
        await kidsLoad
        await currentLoad
    }

    private func loadChildrenIfNeeded(_ node: TreeNode) async {
        if children[node.id] == nil { await loadChildren(node) }
    }

    private func toggleExpand(_ node: TreeNode) async {
        if expanded.contains(node.id) {
            expanded.remove(node.id)
        } else {
            expanded.insert(node.id)
            if children[node.id] == nil { await loadChildren(node) }
        }
    }

    private func loadChildren(_ node: TreeNode) async {
        guard let client = appState.apiClient else { return }
        do {
            let kids = try await client.listFiles(parentID: node.id).filter(\.isDir)
            children[node.id] = kids.map { TreeNode(id: $0.id, name: $0.name, parentID: node.id) }
        } catch {
            // Soft-fail: keep tree usable even if one folder fails to expand.
        }
    }

    /// Walk parent links to reconstruct the path from a root to this node.
    private func buildPath(to node: TreeNode) -> [TreeNode] {
        var chain: [TreeNode] = [node]
        var current: TreeNode? = node
        while let cur = current, let pid = cur.parentID {
            if let parent = findNode(id: pid) {
                chain.append(parent)
                current = parent
            } else {
                break
            }
        }
        return chain.reversed()
    }

    private func findNode(id: String) -> TreeNode? {
        if let r = roots.first(where: { $0.id == id }) { return r }
        for (_, kids) in children {
            if let n = kids.first(where: { $0.id == id }) { return n }
        }
        return nil
    }

    /// Load restore-dates + most-recent snapshot for the currently-selected
    /// folder. `currentFolderID` is captured at entry so a fast double-click
    /// (folder A then B) doesn't end up writing A's response over B's state.
    private func loadCurrent() async {
        guard let client = appState.apiClient else { return }
        let folderID = currentFolderID
        guard !folderID.isEmpty else { return }
        loading = true; defer { loading = false }
        do {
            let dateStrs = try await client.changeDates(parentID: folderID)
            guard folderID == currentFolderID else { return }   // user moved on
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            let points = dateStrs.compactMap { df.date(from: $0) }.sorted(by: <)
            let snap = points.last ?? Date()
            let files = try await client.filesAtTime(parentID: folderID, at: snap)
            guard folderID == currentFolderID else { return }
            restorePoints = points
            selectedSnapshot = snap
            snapshotFiles = files
            snapshotCache[folderID] = CachedSnapshot(points: points, snapshot: snap, files: files)
        } catch {
            self.error = "Could not load folder: \(error.localizedDescription)"
        }
    }

    /// Load files for a specific historical date (timeline dot click). Not
    /// cached — the cache only tracks the most-recent snapshot per folder.
    private func loadSnapshot(at: Date) async {
        guard let client = appState.apiClient else { return }
        let folderID = currentFolderID
        guard !folderID.isEmpty else { return }
        loading = true; defer { loading = false }
        selection.removeAll()
        do {
            let files = try await client.filesAtTime(parentID: folderID, at: at)
            guard folderID == currentFolderID else { return }
            snapshotFiles = files
        } catch {
            self.error = "Could not load snapshot: \(error.localizedDescription)"
        }
    }

    // MARK: - Download

    /// Three cases:
    ///  · explicit folder selected     → ZIP that folder
    ///  · explicit files selected      → loop, download each
    ///  · nothing selected, folder open → ZIP the WHOLE current folder
    private func doDownload() async {
        guard !currentFolderID.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose Folder"
        panel.message = "Where should the restored files go?"
        guard panel.runModal() == .OK, let target = panel.url else { return }

        downloading = true; error = nil
        defer { downloading = false }

        let selectedItems = snapshotFiles.filter { selection.contains($0.id) }

        // Implicit: no selection → ZIP the current folder as a whole.
        if selectedItems.isEmpty {
            let synthetic = FileAtTime(
                id: currentFolderID,
                name: currentFolderName,
                isDir: true, size: 0,
                versionNum: 0, versionID: "",
                contentHash: nil,
                updatedAt: ""
            )
            await downloadFolderZip(synthetic, into: target)
            return
        }

        // Explicit single folder → ZIP it.
        if selectedItems.count == 1, let folder = selectedItems.first, folder.isDir {
            await downloadFolderZip(folder, into: target)
            return
        }

        // Explicit files → loop. Folders in a mixed selection are skipped to
        // avoid the recursive-balloon case; user can pick the folder alone.
        for item in selectedItems where !item.isDir {
            await downloadOneFile(item, into: target)
        }
    }

    /// Context-menu entry point — same NSOpenPanel flow as the bottom button,
    /// but the items are explicit (the right-clicked row + selection).
    private func contextDownload(items: [FileAtTime]) async {
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose Folder"
        panel.message = "Where should the restored files go?"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        downloading = true; error = nil
        defer { downloading = false }
        // Loop through everything: folders → ZIP, files → individual download.
        // Single-folder is just the trivial case of this loop.
        for item in items {
            if item.isDir {
                await downloadFolderZip(item, into: target)
            } else {
                await downloadOneFile(item, into: target)
            }
        }
    }

    private func downloadFolderZip(_ folder: FileAtTime, into target: URL) async {
        guard let snapshot = selectedSnapshot,
              let client = appState.apiClient,
              let token = client.currentToken() else { return }
        let baseURL = appState.serverURL.isEmpty ? "https://sync.heesakkers.com" : appState.serverURL
        let iso = ISO8601DateFormatter().string(from: snapshot)
        guard let encAt = iso.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/api/files/history/download?parent_id=\(folder.id)&at=\(encAt)")
        else {
            error = "Could not build download URL"
            return
        }
        // Use URLSession download task with Authorization header. The server
        // streams a ZIP; we extract it into target/<folderName>/ on the fly.
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (zipURL, _) = try await URLSession.shared.download(for: req)
            let dest = target.appendingPathComponent(folder.name, isDirectory: true)
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            // Use NSWorkspace's `unzip` shell command — simplest reliable path.
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            proc.arguments = ["-o", zipURL.path, "-d", dest.path]
            try proc.run()
            proc.waitUntilExit()
            error = nil
            // Open Finder at the destination so the user sees the result.
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            self.error = "Folder download failed: \(error.localizedDescription)"
        }
    }

    private func downloadOneFile(_ file: FileAtTime, into target: URL) async {
        guard let client = appState.apiClient,
              let token = client.currentToken() else { return }
        let baseURL = appState.serverURL.isEmpty ? "https://sync.heesakkers.com" : appState.serverURL
        guard let url = URL(string: "\(baseURL)/api/files/\(file.id)/versions/\(file.versionNum)/download")
        else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (tmp, _) = try await URLSession.shared.download(for: req)
            let dest = target.appendingPathComponent(file.name)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            self.error = "Download failed for \(file.name): \(error.localizedDescription)"
        }
    }

    // MARK: - Timeline helpers

    /// Range that the timeline should cover. From first restore point to now,
    /// padded by 1 day so dots don't sit right on the edge. If no restore
    /// points yet, fall back to last 7 days.
    private func timelineRange() -> (Date, Date) {
        let now = Date()
        guard let first = restorePoints.first else {
            return (Calendar.current.date(byAdding: .day, value: -7, to: now)!, now)
        }
        let start = Calendar.current.date(byAdding: .day, value: -1, to: first) ?? first
        return (start, now)
    }

    private func daysBetween(_ a: Date, _ b: Date) -> Int {
        let cal = Calendar.current
        let aStart = cal.startOfDay(for: a)
        let bStart = cal.startOfDay(for: b)
        return cal.dateComponents([.day], from: aStart, to: bStart).day ?? 0
    }

    struct MonthLabel: Hashable { let label: String; let date: Date }

    /// Month-start dates that fall inside the range, used as text labels.
    private func monthLabels(start: Date, end: Date) -> [MonthLabel] {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month], from: start)
        comps.day = 1
        var d = cal.date(from: comps) ?? start
        if d < start { d = cal.date(byAdding: .month, value: 1, to: d) ?? d }
        let df = DateFormatter(); df.dateFormat = "MMM"
        var out: [MonthLabel] = []
        while d <= end {
            out.append(MonthLabel(label: df.string(from: d), date: d))
            d = cal.date(byAdding: .month, value: 1, to: d) ?? d.addingTimeInterval(31*86400)
        }
        return out
    }


    // MARK: - Format helpers

    private func formatBytes(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: b)
    }

    private func formatTimestamp(_ d: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: d)
    }

    private func formatDateShort(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return iso }
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df.string(from: date)
    }
}

// MARK: - FileRow (extracted for diffability)

/// Single row in the snapshot file list. Lives as its OWN View struct so
/// SwiftUI can diff by Equatable-style identity: when selection changes by
/// one row, only that row + the previously-selected row rebuild. The old
/// pattern (private func returning some View inside parent) treated every
/// row's body as part of the parent's body, so a single click rebuilt all
/// ~100+ rows visibly. Pulling it out drops that to ~2 rebuilds.
private struct FileRow: View, Equatable {
    let file: FileAtTime
    let isSelected: Bool
    /// Closures are NOT compared in Equatable — only file + isSelected.
    /// SwiftUI keeps the latest closures via its normal update machinery,
    /// it just won't trigger a rerender for closure identity alone.
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onDoubleClickFolder: () -> Void
    @ViewBuilder let contextMenuItems: () -> AnyView

    init(
        file: FileAtTime,
        isSelected: Bool,
        onClick: @escaping (NSEvent.ModifierFlags) -> Void,
        onDoubleClickFolder: @escaping () -> Void,
        @ViewBuilder contextMenuItems: @escaping () -> some View
    ) {
        self.file = file
        self.isSelected = isSelected
        self.onClick = onClick
        self.onDoubleClickFolder = onDoubleClickFolder
        self.contextMenuItems = { AnyView(contextMenuItems()) }
    }

    static func == (lhs: FileRow, rhs: FileRow) -> Bool {
        lhs.file.id == rhs.file.id
            && lhs.file.versionNum == rhs.file.versionNum
            && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: file.isDir ? "folder.fill" : "doc")
                    .foregroundStyle(isSelected ? SVColor.accentBlue : SVColor.textSecondary)
                Text(file.name)
                    .font(SVFont.body(12.5))
                    .foregroundStyle(SVColor.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(file.isDir ? "—" : Self.formatBytes(file.size))
                .font(SVFont.mono(11))
                .foregroundStyle(SVColor.textSecondary)
                .frame(width: 80, alignment: .leading)
            Text("v\(file.versionNum)")
                .font(SVFont.mono(11))
                .foregroundStyle(SVColor.accentBlue)
                .frame(width: 40, alignment: .leading)
            Text(Self.formatDateShort(file.updatedAt))
                .font(SVFont.mono(11))
                .foregroundStyle(SVColor.textSecondary)
                .frame(width: 140, alignment: .leading)
        }
        .padding(.horizontal, SVSpacing.xl)
        .padding(.vertical, 5)
        .background(isSelected ? SVColor.accentBlue.opacity(0.22) : Color.clear)
        .contentShape(Rectangle())
        .overlay(
            RowClickHandler(
                isFolder: file.isDir,
                onSingleClick: onClick,
                onDoubleClick: onDoubleClickFolder
            )
        )
        .contextMenu { contextMenuItems() }
    }

    private static func formatBytes(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: b)
    }

    private static func formatDateShort(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return iso }
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df.string(from: date)
    }
}

/// Vertical 1px divider with a 6px-wide invisible hit area, drag-to-resize,
/// and a resize cursor on hover. Replaces HSplitView whose idealWidth was
/// silently ignored — this gives the parent exact control over the default
/// split width while still letting the user drag.
private struct SplitDivider: View {
    @Binding var width: CGFloat
    let min: CGFloat
    let max: CGFloat
    @State private var dragStart: CGFloat? = nil

    var body: some View {
        ZStack {
            Color.clear.frame(width: 6)
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStart == nil { dragStart = width }
                    let proposed = (dragStart ?? width) + value.translation.width
                    width = Swift.min(max, Swift.max(min, proposed))
                }
                .onEnded { _ in dragStart = nil }
        )
    }
}

/// Click capture with NSEvent modifier-flag access. Standalone struct so
/// FileRow's Equatable conformance doesn't need to care about it.
private struct RowClickHandler: NSViewRepresentable {
    let isFolder: Bool
    let onSingleClick: (NSEvent.ModifierFlags) -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = HitView()
        v.onSingleClick = onSingleClick
        v.onDoubleClick = onDoubleClick
        v.isFolder = isFolder
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? HitView else { return }
        v.onSingleClick = onSingleClick
        v.onDoubleClick = onDoubleClick
        v.isFolder = isFolder
    }

    final class HitView: NSView {
        var onSingleClick: ((NSEvent.ModifierFlags) -> Void)?
        var onDoubleClick: (() -> Void)?
        var isFolder: Bool = false
        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2, isFolder {
                onDoubleClick?()
            } else {
                onSingleClick?(event.modifierFlags)
            }
        }
    }
}
