import SwiftUI

struct SyncTasksTab: View {
    @ObservedObject var appState: AppState
    @State private var showingAddTask = false

    var body: some View {
        VStack {
            List {
                ForEach(appState.syncTasks) { task in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(URL(fileURLWithPath: task.localPath).lastPathComponent)
                                .font(.headline)
                            Text("\(task.localPath) <-> \(task.remoteFolderName)")
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

            HStack {
                Button("Add Sync Task") {
                    showingAddTask = true
                }
                Spacer()
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
    @State private var remoteFolderName = "My Files"
    @State private var mode: SyncTask.SyncMode = .twoWay

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

                TextField("Remote Folder", text: $remoteFolderName)

                Picker("Mode", selection: $mode) {
                    Text("Two-way Sync").tag(SyncTask.SyncMode.twoWay)
                    Text("Upload Only (Backup)").tag(SyncTask.SyncMode.uploadOnly)
                }
            }

            HStack {
                Button("Cancel") { isPresented = false }
                Button("Add") {
                    let task = SyncTask(
                        localPath: localPath,
                        remoteFolderID: "",
                        remoteFolderName: remoteFolderName,
                        mode: mode
                    )
                    appState.syncTasks.append(task)
                    appState.saveConfig()
                    isPresented = false
                }
                .disabled(localPath.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }
}
