import FileProvider
import UniformTypeIdentifiers

class FileProviderItem: NSObject, NSFileProviderItem {
    let id: String
    let parentID: String?
    let name: String
    let isFolder: Bool
    let fileSize: Int64
    let contentHashValue: String?
    let modifiedDate: Date
    let itemIsDownloaded: Bool

    var itemIdentifier: NSFileProviderItemIdentifier {
        return NSFileProviderItemIdentifier(id)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        guard let parentID = parentID else {
            return .rootContainer
        }
        // If parent is the on-demand folder, map to root container
        if parentID == SharedConfig.onDemandFolderID() {
            return .rootContainer
        }
        return NSFileProviderItemIdentifier(parentID)
    }

    var filename: String { name }

    var contentType: UTType {
        if isFolder { return .folder }
        return UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
    }

    var capabilities: NSFileProviderItemCapabilities {
        if isFolder {
            return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems, .allowsRenaming, .allowsDeleting]
        }
        return [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting, .allowsEvicting]
    }

    var documentSize: NSNumber? {
        return NSNumber(value: fileSize)
    }

    var contentModificationDate: Date? {
        return modifiedDate
    }

    var itemVersion: NSFileProviderItemVersion {
        let hash = (contentHashValue ?? id).data(using: .utf8) ?? Data()
        return NSFileProviderItemVersion(contentVersion: hash, metadataVersion: hash)
    }

    // Accept extended attributes (resource forks, FinderInfo, etc.) so Finder
    // doesn't reject copies with "name is too long or invalid characters" error.
    var extendedAttributes: [String: Data] { [:] }

    // Tell macOS this file is NOT downloaded — it needs to be fetched on access
    var isDownloaded: Bool { itemIsDownloaded }

    // Files should be downloadable on demand, not eagerly downloaded
    var isUploaded: Bool { true }
    var isUploading: Bool { false }
    var isDownloading: Bool { false }

    init(serverFile: FPServerFile, isDownloaded: Bool = false) {
        self.id = serverFile.id
        self.parentID = serverFile.parentID
        self.name = serverFile.name
        self.isFolder = serverFile.isDir
        self.fileSize = serverFile.size
        self.contentHashValue = serverFile.contentHash
        self.itemIsDownloaded = isDownloaded

        let formatter = ISO8601DateFormatter()
        if let updatedAt = serverFile.updatedAt {
            self.modifiedDate = formatter.date(from: updatedAt) ?? Date()
        } else {
            self.modifiedDate = Date()
        }

        super.init()
    }

    static func rootContainer() -> FileProviderItem {
        let item = FileProviderItem(
            id: NSFileProviderItemIdentifier.rootContainer.rawValue,
            name: "SyncVault",
            isFolder: true
        )
        return item
    }

    private init(id: String, name: String, isFolder: Bool) {
        self.id = id
        self.parentID = nil
        self.name = name
        self.isFolder = isFolder
        self.fileSize = 0
        self.contentHashValue = nil
        self.itemIsDownloaded = true
        self.modifiedDate = Date()
        super.init()
    }
}
