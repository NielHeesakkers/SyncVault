import SwiftUI

struct SyncTasksTab: View {
    @ObservedObject var appState: AppState
    @State private var showingAddTask = false

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
                                Text(URL(fileURLWithPath: task.localPath).lastPathComponent)
                                    .font(.headline)
                                Text(task.localPath)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(task.mode == .twoWay ? "Two-way" : "Backup")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(task.mode == .twoWay ? Color.blue.opacity(0.1) : Color.orange.opacity(0.1))
                                .cornerRadius(4)
                            Toggle("", isOn: Binding(
                                get: { task.isEnabled },
                                set: { newValue in
                                    if let idx = appState.syncTasks.firstIndex(where: { $0.id == task.id }) {
                                        appState.syncTasks[idx].isEnabled = newValue
                                        appState.saveConfig()
                                    }
                                }
                            ))
                            .labelsHidden()
                        }
                    }
                    .onDelete { indexSet in
                        appState.syncTasks.remove(atOffsets: indexSet)
                        appState.saveConfig()
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
    }
}

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
                    Text("Two-way Sync").tag(SyncTask.SyncMode.twoWay)
                    Text("Upload Only (Backup)").tag(SyncTask.SyncMode.uploadOnly)
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
