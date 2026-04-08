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
        VStack(alignment: .leading, spacing: 0) {
            if appState.syncTasks.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.3))
                    Text("No sync tasks")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("Add a task to start syncing files.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.7))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(appState.syncTasks) { task in
                            TaskCard(
                                task: task,
                                isSyncing: appState.isSyncing,
                                onEdit: { taskToEdit = task },
                                onDelete: {
                                    taskToDelete = task
                                    showingDeleteConfirmation = true
                                },
                                onToggle: { newValue in
                                    var updated = task
                                    updated.isEnabled = newValue
                                    appState.updateSyncTask(updated)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }

            // Bottom bar
            Divider()
            HStack(spacing: 8) {
                Button {
                    addMode = .twoWay
                    showingAddSheet = true
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11))
                }
                .disabled(!appState.isConnected)

                Button {
                    addMode = .uploadOnly
                    showingAddSheet = true
                } label: {
                    Label("Backup", systemImage: "arrow.up.doc")
                        .font(.system(size: 11))
                }
                .disabled(!appState.isConnected)

                Button {
                    addMode = .onDemand
                    showingAddSheet = true
                } label: {
                    Label("On-demand", systemImage: "icloud.and.arrow.down")
                        .font(.system(size: 11))
                }
                .disabled(!appState.isConnected || hasOnDemandTask)
                .help(hasOnDemandTask ? "Only one on-demand task allowed" : "Files download on open")

                Spacer()

                if appState.isSyncing {
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.5)
                        Text("Syncing...")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
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
}

// MARK: - Task Card

struct TaskCard: View {
    let task: SyncTask
    let isSyncing: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Status dot with pulse when syncing
            Group {
                if task.isEnabled && isSyncing {
                    PulsingDot(color: dotColor)
                } else {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 8, height: 8)
                }
            }

            // Main info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.remoteFolderName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if task.isTeamFolder {
                        Text("Team")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.purple, in: Capsule())
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.yellow)
                    Text(task.localPath)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            // Mode badge
            ModeBadge(mode: task.mode)

            // Toggle
            Toggle("", isOn: Binding(
                get: { task.isEnabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .scaleEffect(0.8)

            // Edit button
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.borderless)

            // Delete button
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                )
        )
    }

    private var dotColor: Color {
        if !task.isEnabled { return Color(white: 0.35) }
        if task.mode == .onDemand { return .purple }
        return isSyncing ? .blue : .green
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

    init(appState: AppState, task: SyncTask, isPresented: Binding<SyncTask?>) {
        self.appState = appState
        self.task = task
        self._isPresented = isPresented
        self._localPath = State(initialValue: task.localPath)
        self._mode = State(initialValue: task.mode)
        self._isEnabled = State(initialValue: task.isEnabled)
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
