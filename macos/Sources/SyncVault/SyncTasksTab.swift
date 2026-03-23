import SwiftUI

struct SyncTasksTab: View {
    @ObservedObject var appState: AppState
    @State private var showingAddTask = false
    @State private var taskToEdit: SyncTask?
    @State private var taskToDelete: SyncTask?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack {
            if appState.syncTasks.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No sync tasks yet")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Add a sync task to start syncing files with your server.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(appState.syncTasks) { task in
                        HStack {
                            VStack(alignment: .leading) {
                                HStack(spacing: 6) {
                                    Text(URL(fileURLWithPath: task.localPath).lastPathComponent)
                                        .font(.headline)
                                    if task.isTeamFolder {
                                        Text("Team")
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.purple)
                                            .cornerRadius(4)
                                    }
                                }
                                Text(task.localPath)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(task.mode.displayName)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(badgeColor(for: task.mode).opacity(0.1))
                                .foregroundColor(badgeColor(for: task.mode))
                                .cornerRadius(4)
                            Toggle("", isOn: Binding(
                                get: { task.isEnabled },
                                set: { newValue in
                                    var updated = task
                                    updated.isEnabled = newValue
                                    appState.updateSyncTask(updated)
                                }
                            ))
                            .labelsHidden()

                            Button {
                                taskToEdit = task
                            } label: {
                                Image(systemName: "pencil.circle")
                                    .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.borderless)
                            .help("Edit sync task")

                            Button {
                                taskToDelete = task
                                showingDeleteConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("Delete sync task")
                        }
                    }
                }
            }

            HStack {
                Button("Add Sync Task") {
                    showingAddTask = true
                }
                .disabled(!appState.isConnected)

                Spacer()

                if appState.isSyncing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Syncing...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
        }
        .sheet(isPresented: $showingAddTask) {
            AddSyncTaskView(appState: appState, isPresented: $showingAddTask)
        }
        .sheet(item: $taskToEdit) { task in
            EditSyncTaskView(appState: appState, task: task, isPresented: $taskToEdit)
        }
        .alert("Delete Sync Task", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                taskToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let task = taskToDelete {
                    appState.deleteSyncTask(task)
                    taskToDelete = nil
                }
            }
        } message: {
            if let task = taskToDelete {
                Text("Are you sure you want to delete the sync task for \"\(URL(fileURLWithPath: task.localPath).lastPathComponent)\"? This will not delete any files.")
            }
        }
    }

    private func badgeColor(for mode: SyncTask.SyncMode) -> Color {
        switch mode {
        case .twoWay: return .blue
        case .uploadOnly: return .orange
        case .onDemand: return .purple
        }
    }
}

struct EditSyncTaskView: View {
    @ObservedObject var appState: AppState
    let task: SyncTask
    @Binding var isPresented: SyncTask?

    @State private var localPath: String
    @State private var mode: SyncTask.SyncMode
    @State private var isEnabled: Bool

    init(appState: AppState, task: SyncTask, isPresented: Binding<SyncTask?>) {
        self.appState = appState
        self.task = task
        self._isPresented = isPresented
        self._localPath = State(initialValue: task.localPath)
        self._mode = State(initialValue: task.mode)
        self._isEnabled = State(initialValue: task.isEnabled)
    }

    var folderName: String {
        localPath.isEmpty ? "" : URL(fileURLWithPath: localPath).lastPathComponent
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Sync Task")
                .font(.headline)

            Form {
                HStack {
                    TextField("Local Folder", text: $localPath)
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

                if !folderName.isEmpty {
                    LabeledContent("Remote Folder") {
                        Text(task.remoteFolderName)
                            .foregroundColor(.secondary)
                    }
                }

                Picker("Mode", selection: $mode) {
                    ForEach(SyncTask.SyncMode.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }

                Toggle("Enabled", isOn: $isEnabled)
            }

            HStack {
                Button("Cancel") {
                    isPresented = nil
                }
                Button("Save") {
                    var updated = task
                    updated.localPath = localPath
                    updated.mode = mode
                    updated.isEnabled = isEnabled
                    appState.updateSyncTask(updated)
                    // Handle on-demand: setup File Provider
                    if mode == .onDemand {
                        Task {
                            try? await appState.setupOnDemandSync(folderID: updated.remoteFolderID)
                        }
                    }
                    isPresented = nil
                }
                .disabled(localPath.isEmpty)
            }
        }
        .padding()
        .frame(width: 480)
    }
}

// MARK: - Add Sync Task

struct AddSyncTaskView: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var localPath = ""
    @State private var mode: SyncTask.SyncMode = .twoWay
    @State private var isCreating = false
    @State private var errorMessage: String?

    var folderName: String {
        localPath.isEmpty ? "" : URL(fileURLWithPath: localPath).lastPathComponent
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Sync Task")
                .font(.headline)

            Form {
                HStack {
                    TextField("Local Folder", text: $localPath)
                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url {
                            localPath = url.path
                        }
                    }
                }

                if !folderName.isEmpty {
                    LabeledContent("Remote Folder") {
                        Text(folderName)
                            .foregroundColor(.secondary)
                    }
                }

                Picker("Mode", selection: $mode) {
                    ForEach(SyncTask.SyncMode.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }

                if mode == .onDemand {
                    Text("Files appear in Finder but are downloaded only when opened. Requires macOS File Provider.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Button("Cancel") { isPresented = false }
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
                .disabled(localPath.isEmpty || isCreating)
            }
        }
        .padding()
        .frame(width: 450)
    }
}
