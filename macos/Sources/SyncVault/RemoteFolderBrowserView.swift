import SwiftUI

@MainActor
class FolderNode: ObservableObject, Identifiable {
    let id: String
    let name: String
    let parentID: String?
    @Published var children: [FolderNode]?
    @Published var isExpanded = false
    @Published var isLoading = false

    init(id: String, name: String, parentID: String?) {
        self.id = id
        self.name = name
        self.parentID = parentID
    }
}

struct RemoteFolderBrowserView: View {
    let apiClient: APIClient
    @Binding var selectedFolderID: String?
    @Binding var selectedFolderName: String?

    @State private var rootNodes: [FolderNode] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var createFolderParentID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView("Loading...")
                    Spacer()
                }
                .frame(height: 200)
            } else if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .frame(height: 200)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rootNodes) { node in
                            FolderTreeRow(
                                node: node,
                                selectedID: $selectedFolderID,
                                selectedName: $selectedFolderName,
                                apiClient: apiClient,
                                depth: 0
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 180, maxHeight: 280)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
            }

            // New folder button
            HStack {
                if isCreatingFolder {
                    Image(systemName: "folder.badge.plus")
                        .foregroundColor(.accentColor)
                    TextField("Folder name", text: $newFolderName, onCommit: {
                        Task { await createNewFolder() }
                    })
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                    Button("Create") {
                        Task { await createNewFolder() }
                    }
                    .disabled(newFolderName.isEmpty)

                    Button("Cancel") {
                        isCreatingFolder = false
                        newFolderName = ""
                    }
                } else {
                    Button(action: {
                        createFolderParentID = selectedFolderID
                        isCreatingFolder = true
                    }) {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.top, 6)
        }
        .task {
            await loadRootFolders()
        }
    }

    private func loadRootFolders() async {
        isLoading = true
        errorMessage = nil
        do {
            let folders = try await apiClient.listFolders(parentID: nil)
            rootNodes = folders.map { FolderNode(id: $0.id, name: $0.name, parentID: nil) }
            isLoading = false
        } catch {
            errorMessage = "Could not load folders"
            isLoading = false
        }
    }

    private func createNewFolder() async {
        guard !newFolderName.isEmpty else { return }
        let parentID = createFolderParentID

        do {
            let folder = try await apiClient.createFolder(name: newFolderName, parentID: parentID ?? "")
            let newNode = FolderNode(id: folder.id, name: folder.name, parentID: parentID)

            if let parentID = parentID {
                // Find parent node and add child
                addChildToNode(parentID: parentID, child: newNode, in: rootNodes)
            } else {
                rootNodes.append(newNode)
            }

            // Auto-select the new folder
            selectedFolderID = folder.id
            selectedFolderName = folder.name
            isCreatingFolder = false
            newFolderName = ""
        } catch {
            // Show inline error
        }
    }

    private func addChildToNode(parentID: String, child: FolderNode, in nodes: [FolderNode]) {
        for node in nodes {
            if node.id == parentID {
                if node.children == nil {
                    node.children = []
                }
                node.children?.append(child)
                node.isExpanded = true
                return
            }
            if let children = node.children {
                addChildToNode(parentID: parentID, child: child, in: children)
            }
        }
    }
}

struct FolderTreeRow: View {
    @ObservedObject var node: FolderNode
    @Binding var selectedID: String?
    @Binding var selectedName: String?
    let apiClient: APIClient
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                // Indent
                ForEach(0..<depth, id: \.self) { _ in
                    Spacer().frame(width: 16)
                }

                // Disclosure triangle
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        node.isExpanded.toggle()
                    }
                    if node.isExpanded && node.children == nil {
                        Task { await loadChildren() }
                    }
                }) {
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .frame(width: 16, height: 16)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Image(systemName: "folder.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 14))

                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if node.isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selectedID == node.id ? Color.accentColor.opacity(0.15) : Color.clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedID = node.id
                selectedName = node.name
            }

            // Children
            if node.isExpanded {
                if let children = node.children {
                    ForEach(children) { child in
                        FolderTreeRow(
                            node: child,
                            selectedID: $selectedID,
                            selectedName: $selectedName,
                            apiClient: apiClient,
                            depth: depth + 1
                        )
                    }
                }
            }
        }
    }

    private func loadChildren() async {
        node.isLoading = true
        do {
            let folders = try await apiClient.listFolders(parentID: node.id)
            node.children = folders.map { FolderNode(id: $0.id, name: $0.name, parentID: node.id) }
        } catch {
            node.children = []
        }
        node.isLoading = false
    }
}
