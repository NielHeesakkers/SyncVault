import SwiftUI

struct SyncTasksTab: View {
    @ObservedObject var appState: AppState
    @State private var showingAddSheet = false
    @State private var addMode: SyncTask.SyncMode = .twoWay
    @State private var taskToEdit: SyncTask?
    @State private var taskToDelete: SyncTask?
    @State private var showingDeleteConfirmation = false

    var hasOnDemandTask: Bool {
        appState.syncTasks.contains { $0.mode == .onDemand }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(alignment: .firstTextBaseline) {
                    Text("Sync Tasks").font(SVFont.bodyBold(17))
                    Spacer()
                    Menu {
                        Button {
                            addMode = .twoWay
                            showingAddSheet = true
                        } label: {
                            Label("Two-way Sync", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(!appState.isConnected)

                        Button {
                            addMode = .uploadOnly
                            showingAddSheet = true
                        } label: {
                            Label("Backup (Upload Only)", systemImage: "arrow.up.doc")
                        }
                        .disabled(!appState.isConnected)

                        Button {
                            addMode = .onDemand
                            showingAddSheet = true
                        } label: {
                            Label("On-demand", systemImage: "icloud.and.arrow.down")
                        }
                        .disabled(!appState.isConnected || hasOnDemandTask)
                    } label: {
                        Text("+ Add Task")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .tint(SVColor.accentBlue)
                    .controlSize(.small)
                    .disabled(!appState.isConnected)
                }
                .padding(.bottom, SVSpacing.s)

                Text(summaryLine)
                    .font(SVFont.mono(11))
                    .foregroundStyle(SVColor.textSecondary)
                    .padding(.bottom, SVSpacing.xl)

                if appState.syncTasks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 36))
                            .foregroundStyle(SVColor.textTertiary)
                        Text("No sync tasks")
                            .font(SVFont.bodyBold(14))
                            .foregroundStyle(SVColor.textSecondary)
                        Text("Add a task to start syncing files.")
                            .font(SVFont.body(12))
                            .foregroundStyle(SVColor.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SVSpacing.xxxl)
                } else {
                    let tasks = sortedTasks
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { idx, task in
                        taskCard(task)
                            .padding(.bottom, SVSpacing.l)

                        // Hairline divider after the on-demand block
                        if task.mode == .onDemand,
                           idx + 1 < tasks.count,
                           tasks[idx + 1].mode != .onDemand {
                            Rectangle()
                                .fill(LinearGradient(
                                    colors: [.clear, SVColor.hairline, .clear],
                                    startPoint: .leading, endPoint: .trailing))
                                .frame(height: 1)
                                .padding(.bottom, SVSpacing.l)
                        }
                    }
                }
            }
            .padding(SVSpacing.xxxl)
        }
        .background(SVColor.windowBg)
        .sheet(isPresented: $showingAddSheet) {
            AddSyncTaskWizardView(isPresented: $showingAddSheet, initialMode: addMode)
                .environmentObject(appState)
        }
        .sheet(item: $taskToEdit) { task in
            EditSyncTaskView(appState: appState, task: task, isPresented: $taskToEdit)
        }
        .alert("Delete Sync Task", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { taskToDelete = nil }
            Button("Delete", role: .destructive) {
                if let task = taskToDelete {
                    appState.deleteSyncTask(task)
                    taskToDelete = nil
                }
            }
        } message: {
            if let task = taskToDelete {
                Text("Delete \"\(task.remoteFolderName)\"? This will not delete any files.")
            }
        }
    }

    private var summaryLine: String {
        let n = appState.syncTasks.count
        let plural = n == 1 ? "task" : "tasks"
        return "\(n) \(plural)"
    }

    private var sortedTasks: [SyncTask] {
        let onDemand = appState.syncTasks.filter { $0.mode == .onDemand }
        let folders = appState.syncTasks.filter { $0.mode != .onDemand }
            .sorted { $0.localPath < $1.localPath }
        return onDemand + folders
    }

    private func taskCard(_ task: SyncTask) -> some View {
        VStack(spacing: 0) {
            // Head row
            HStack(spacing: SVSpacing.xl) {
                SVChip(variant: task.mode == .onDemand ? .cloud : .folder, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(taskDisplayName(task)).font(SVFont.bodyBold(14))
                    Text("\(task.localPath) ↔ \(task.remoteFolderName)")
                        .font(SVFont.mono(10.5))
                        .foregroundStyle(SVColor.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                SVStatusPill(text: modeLabel(task.mode),
                             kind: task.mode == .onDemand ? .cloud : .neutral)
                Toggle("", isOn: Binding(
                    get: { task.isEnabled },
                    set: { newValue in
                        var updated = task
                        updated.isEnabled = newValue
                        appState.updateSyncTask(updated)
                    }
                )).labelsHidden()

                Button {
                    taskToEdit = task
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(SVColor.accentBlue)
                }
                .buttonStyle(.borderless)
                .help("Edit task")

                Button {
                    taskToDelete = task
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(SVColor.accentRed)
                }
                .buttonStyle(.borderless)
                .help("Delete task")
            }
            .padding(SVSpacing.xl)

            // Stats grid
            HStack(spacing: 0) {
                statCell("Files",     "—")
                statCell("Size",      "—")
                statCell("Last sync", "—", isLast: true)
            }
            .overlay(Rectangle().fill(SVColor.hairline).frame(height: 1), alignment: .top)
        }
        .background(SVColor.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: SVRadius.card))
    }

    private func taskDisplayName(_ task: SyncTask) -> String {
        URL(fileURLWithPath: task.localPath).lastPathComponent
    }

    private func modeLabel(_ mode: SyncTask.SyncMode) -> String {
        switch mode {
        case .twoWay:     return "two-way"
        case .uploadOnly: return "backup"
        case .onDemand:   return "on-demand"
        }
    }

    private func statCell(_ label: String, _ value: String, isLast: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(SVFont.sectionLabel)
                .foregroundStyle(SVColor.textTertiary)
            Text(value)
                .font(SVFont.mono(13))
                .foregroundStyle(SVColor.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SVSpacing.xl)
        .padding(.vertical, SVSpacing.l)
        .overlay(alignment: .trailing) {
            if !isLast { Rectangle().fill(SVColor.hairline).frame(width: 1) }
        }
    }
}

// MARK: - Edit Sync Task

struct EditSyncTaskView: View {
    @ObservedObject var appState: AppState
    let task: SyncTask
    @Binding var isPresented: SyncTask?

    @State private var localPath: String
    @State private var mode: SyncTask.SyncMode
    @State private var isEnabled: Bool
    @State private var retentionDaily: Int = 90
    @State private var retentionWeekly: Int = 24
    @State private var retentionMonthly: Int = 12
    @State private var retentionMax: Int = 10
    @State private var excludePatternsText: String = ""

    init(appState: AppState, task: SyncTask, isPresented: Binding<SyncTask?>) {
        self.appState = appState
        self.task = task
        self._isPresented = isPresented
        self._localPath = State(initialValue: task.localPath)
        self._mode = State(initialValue: task.mode)
        self._isEnabled = State(initialValue: task.isEnabled)
        // Pre-fill the exclude editor with current patterns, one per line.
        self._excludePatternsText = State(initialValue: task.excludePatterns.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Sync Task")
                .font(.system(size: 14, weight: .semibold))

            VStack(alignment: .leading, spacing: 12) {
                LabeledField("Folder") {
                    HStack {
                        TextField("", text: $localPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse...") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            if panel.runModal() == .OK, let url = panel.url {
                                localPath = url.path
                                appState.saveBookmark(for: url)
                            }
                        }
                    }
                }

                LabeledField("Remote") {
                    Text(task.remoteFolderName)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                LabeledField("Mode") {
                    Picker("", selection: $mode) {
                        ForEach(SyncTask.SyncMode.allCases, id: \.self) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    .labelsHidden()
                }

                LabeledField("Enabled") {
                    Toggle("", isOn: $isEnabled)
                        .labelsHidden()
                }

                // Exclude patterns — one per line, glob-style (*.tmp, build/,
                // node_modules). FileWatcher honours these when enqueuing
                // changes so selective sync per subfolder works without a tree
                // picker; power users can just type paths.
                Divider()
                Text("Excludes")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    TextEditor(text: $excludePatternsText)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 80, maxHeight: 140)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                    Text("One pattern per line — e.g. *.tmp, node_modules, build/")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                // Retention Policy
                Divider()
                Text("Retention Policy")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                LabeledField("Daily versions") {
                    HStack {
                        TextField("", value: $retentionDaily, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("days")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                LabeledField("Weekly versions") {
                    HStack {
                        TextField("", value: $retentionWeekly, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("weeks")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                LabeledField("Monthly versions") {
                    HStack {
                        TextField("", value: $retentionMonthly, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("months")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                LabeledField("Max versions") {
                    HStack {
                        TextField("", value: $retentionMax, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("per file")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var updated = task
                    updated.localPath = localPath
                    updated.mode = mode
                    updated.isEnabled = isEnabled
                    // Parse one-per-line excludes; trim + drop empties so empty
                    // lines don't accidentally become "match-everything" patterns.
                    updated.excludePatterns = excludePatternsText
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    appState.updateSyncTask(updated)
                    if mode == .onDemand {
                        Task { try? await appState.setupOnDemandSync(folderID: updated.remoteFolderID) }
                    }
                    // Save retention policy
                    if let serverTaskID = task.serverTaskID, let client = appState.apiClient {
                        Task {
                            try? await client.setTaskRetention(taskID: serverTaskID, policy: RetentionPolicy(
                                hourly: 0, daily: retentionDaily, weekly: retentionWeekly,
                                monthly: retentionMonthly, yearly: 0
                            ))
                        }
                    }
                    isPresented = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(localPath.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if let serverTaskID = task.serverTaskID, let client = appState.apiClient {
                Task {
                    if let policy = try? await client.getTaskRetention(taskID: serverTaskID) {
                        await MainActor.run {
                            retentionDaily = policy.daily
                            retentionWeekly = policy.weekly
                            retentionMonthly = policy.monthly
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Add Sync Task

struct AddSyncTaskView: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool
    var initialMode: SyncTask.SyncMode

    @State private var localPath = ""
    @State private var mode: SyncTask.SyncMode
    @State private var isCreating = false
    @State private var errorMessage: String?

    init(appState: AppState, isPresented: Binding<Bool>, initialMode: SyncTask.SyncMode = .twoWay) {
        self.appState = appState
        self._isPresented = isPresented
        self.initialMode = initialMode
        self._mode = State(initialValue: initialMode)
    }

    var folderName: String {
        localPath.isEmpty ? "" : URL(fileURLWithPath: localPath).lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add \(mode.displayName) Task")
                .font(.system(size: 14, weight: .semibold))

            VStack(alignment: .leading, spacing: 12) {
                LabeledField("Folder") {
                    HStack {
                        TextField("Select a folder...", text: $localPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse...") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let url = panel.url {
                                localPath = url.path
                            }
                        }
                    }
                }

                if !folderName.isEmpty {
                    LabeledField("Remote") {
                        Text(folderName)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

                LabeledField("Type") {
                    Text(mode.displayName)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                if mode == .onDemand {
                    Text("Files appear in Finder but download only when opened.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.leading, 74)
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    isCreating = true
                    errorMessage = nil
                    Task {
                        do {
                            try await appState.addSyncTask(localPath: localPath, mode: mode)
                            isPresented = false
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                        isCreating = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(localPath.isEmpty || isCreating)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
