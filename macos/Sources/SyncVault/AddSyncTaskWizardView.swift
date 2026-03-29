import SwiftUI
import AppKit

enum InitialSyncDirection: String, CaseIterable {
    case downloadFromServer = "download"
    case uploadToServer = "upload"

    var label: String {
        switch self {
        case .downloadFromServer: return "Download from server"
        case .uploadToServer: return "Upload to server"
        }
    }

    var icon: String {
        switch self {
        case .downloadFromServer: return "arrow.down.circle"
        case .uploadToServer: return "arrow.up.circle"
        }
    }
}

struct AddSyncTaskWizardView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    var initialMode: SyncTask.SyncMode

    @State private var mode: SyncTask.SyncMode
    @State private var localPath: String = ""
    @State private var selectedFolderID: String?
    @State private var selectedFolderName: String?
    @State private var initialDirection: InitialSyncDirection?
    @State private var showDirectionPicker = false
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var isCheckingContent = false

    init(isPresented: Binding<Bool>, initialMode: SyncTask.SyncMode) {
        self._isPresented = isPresented
        self.initialMode = initialMode
        self._mode = State(initialValue: initialMode)
    }

    private var modeTitle: String {
        switch mode {
        case .twoWay: return "Sync Task"
        case .uploadOnly: return "Backup Task"
        case .onDemand: return "On-Demand Task"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: modeIcon)
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("Add \(modeTitle)")
                    .font(.headline)
                Spacer()
            }

            Divider()

            // Mode selector
            HStack {
                Text("Type")
                    .frame(width: 80, alignment: .trailing)
                    .foregroundColor(.secondary)
                Picker("", selection: $mode) {
                    Text("Two-way Sync").tag(SyncTask.SyncMode.twoWay)
                    Text("Backup (upload only)").tag(SyncTask.SyncMode.uploadOnly)
                    Text("On-Demand").tag(SyncTask.SyncMode.onDemand)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            // Remote folder browser
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Server")
                        .frame(width: 80, alignment: .trailing)
                        .foregroundColor(.secondary)
                    if let name = selectedFolderName {
                        Label(name, systemImage: "folder.fill")
                            .foregroundColor(.primary)
                    } else {
                        Text("Select a folder...")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                if let client = appState.apiClient {
                    RemoteFolderBrowserView(
                        apiClient: client,
                        selectedFolderID: $selectedFolderID,
                        selectedFolderName: $selectedFolderName
                    )
                    .padding(.leading, 84)
                } else {
                    Text("Not connected to server")
                        .foregroundColor(.red)
                        .padding(.leading, 84)
                }
            }

            // Local folder picker
            HStack {
                Text("Local")
                    .frame(width: 80, alignment: .trailing)
                    .foregroundColor(.secondary)
                TextField("Select local folder...", text: $localPath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
                Button("Browse...") {
                    selectLocalFolder()
                }
            }

            // Initial direction picker
            if showDirectionPicker {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Direction")
                            .frame(width: 80, alignment: .trailing)
                            .foregroundColor(.secondary)
                        Text("Both folders have files. Choose initial sync direction:")
                            .foregroundColor(.orange)
                            .font(.callout)
                    }

                    HStack(spacing: 12) {
                        Spacer().frame(width: 80)
                        ForEach(InitialSyncDirection.allCases, id: \.self) { dir in
                            Button(action: { initialDirection = dir }) {
                                HStack {
                                    Image(systemName: dir.icon)
                                    Text(dir.label)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(initialDirection == dir ? Color.accentColor.opacity(0.2) : Color(NSColor.controlBackgroundColor))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(initialDirection == dir ? Color.accentColor : Color(NSColor.separatorColor), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if isCheckingContent {
                HStack {
                    Spacer()
                    ProgressView("Checking folder contents...")
                    Spacer()
                }
            }

            // Error message
            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.callout)
                    .padding(.leading, 84)
            }

            Divider()

            // Buttons
            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    Task { await createTask() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onChange(of: selectedFolderID) { _ in
            checkBothSidesContent()
        }
        .onChange(of: localPath) { _ in
            checkBothSidesContent()
        }
    }

    private var modeIcon: String {
        switch mode {
        case .twoWay: return "arrow.triangle.2.circlepath"
        case .uploadOnly: return "arrow.up.doc"
        case .onDemand: return "icloud.and.arrow.down"
        }
    }

    private var canCreate: Bool {
        guard selectedFolderID != nil, !localPath.isEmpty, !isCreating else { return false }
        if showDirectionPicker && initialDirection == nil { return false }
        return true
    }

    private func selectLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Select the local folder to sync"

        if panel.runModal() == .OK, let url = panel.url {
            localPath = url.path
        }
    }

    private func checkBothSidesContent() {
        guard let folderID = selectedFolderID, !localPath.isEmpty,
              let client = appState.apiClient else {
            showDirectionPicker = false
            initialDirection = nil
            return
        }

        isCheckingContent = true
        Task {
            let localHasFiles: Bool
            do {
                let contents = try FileManager.default.contentsOfDirectory(atPath: localPath)
                localHasFiles = contents.contains { !$0.hasPrefix(".") }
            } catch {
                localHasFiles = false
            }

            let remoteHasFiles: Bool
            do {
                let files = try await client.listFiles(parentID: folderID)
                remoteHasFiles = !files.isEmpty
            } catch {
                remoteHasFiles = false
            }

            await MainActor.run {
                isCheckingContent = false
                if localHasFiles && remoteHasFiles {
                    showDirectionPicker = true
                } else {
                    showDirectionPicker = false
                    if localHasFiles {
                        initialDirection = .uploadToServer
                    } else if remoteHasFiles {
                        initialDirection = .downloadFromServer
                    } else {
                        initialDirection = nil
                    }
                }
            }
        }
    }

    private func createTask() async {
        guard let folderID = selectedFolderID,
              let folderName = selectedFolderName else { return }

        isCreating = true
        errorMessage = nil

        do {
            try await appState.addSyncTask(
                localPath: localPath,
                mode: mode,
                remoteFolderID: folderID,
                remoteFolderName: folderName,
                initialDirection: initialDirection?.rawValue
            )
            isPresented = false
        } catch {
            errorMessage = error.localizedDescription
        }

        isCreating = false
    }
}
