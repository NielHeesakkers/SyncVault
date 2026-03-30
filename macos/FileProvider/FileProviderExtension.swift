import FileProvider
import os.log

class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain
    let logger = Logger(subsystem: "com.syncvault.fileprovider", category: "Extension")

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        logger.info("FileProviderExtension initialized for domain: \(domain.displayName)")
    }

    func invalidate() {
        logger.info("FileProviderExtension invalidated")
    }

    // Return metadata for a single item
    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        Task {
            do {
                let client = try SharedConfig.apiClient()
                if identifier == .rootContainer {
                    completionHandler(FileProviderItem.rootContainer(), nil)
                } else {
                    let serverFile = try await client.getFile(id: identifier.rawValue)
                    completionHandler(FileProviderItem(serverFile: serverFile), nil)
                }
                progress.completedUnitCount = 1
            } catch {
                completionHandler(nil, error)
            }
        }
        return progress
    }

    // Download file contents
    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        Task {
            do {
                let client = try SharedConfig.apiClient()
                let (tempURL, serverFile) = try await client.downloadFileToDisk(id: itemIdentifier.rawValue)
                let item = FileProviderItem(serverFile: serverFile, isDownloaded: true)
                logger.info("Downloaded: \(serverFile.name) (\(serverFile.size) bytes)")
                completionHandler(tempURL, item, nil)
                progress.completedUnitCount = 100
            } catch {
                logger.error("Download failed for \(itemIdentifier.rawValue): \(error)")
                completionHandler(nil, nil, error)
            }
        }
        return progress
    }

    // Upload new item to server
    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        Task {
            do {
                let client = try SharedConfig.apiClient()
                let parentID = itemTemplate.parentItemIdentifier == .rootContainer
                    ? SharedConfig.onDemandFolderID()
                    : itemTemplate.parentItemIdentifier.rawValue

                if itemTemplate.contentType == .folder {
                    // Create folder
                    let result = try await client.createFolder(
                        name: itemTemplate.filename,
                        parentID: parentID
                    )
                    let item = FileProviderItem(serverFile: result)
                    completionHandler(item, [], false, nil)
                } else if let url = url {
                    // Upload file
                    let data = try Data(contentsOf: url)
                    let result = try await client.uploadFile(
                        data: data,
                        filename: itemTemplate.filename,
                        parentID: parentID
                    )
                    let item = FileProviderItem(serverFile: result, isDownloaded: true)
                    completionHandler(item, [], false, nil)
                } else {
                    completionHandler(nil, [], false, NSError.fileProviderErrorForNonExistentItem(withIdentifier: itemTemplate.itemIdentifier))
                }
                progress.completedUnitCount = 100
            } catch {
                completionHandler(nil, [], false, error)
            }
        }
        return progress
    }

    // Modify existing item
    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        Task {
            do {
                let client = try SharedConfig.apiClient()

                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    // Rename or move
                    let newParentID = item.parentItemIdentifier == .rootContainer
                        ? SharedConfig.onDemandFolderID()
                        : item.parentItemIdentifier.rawValue
                    try await client.moveFile(id: item.itemIdentifier.rawValue, name: item.filename, parentID: newParentID)
                }

                if changedFields.contains(.contents), let url = newContents {
                    // Re-upload contents
                    let data = try Data(contentsOf: url)
                    let _ = try await client.uploadFile(
                        data: data,
                        filename: item.filename,
                        parentID: item.parentItemIdentifier == .rootContainer ? SharedConfig.onDemandFolderID() : item.parentItemIdentifier.rawValue
                    )
                }

                let serverFile = try await client.getFile(id: item.itemIdentifier.rawValue)
                let updatedItem = FileProviderItem(serverFile: serverFile, isDownloaded: newContents != nil)
                completionHandler(updatedItem, [], false, nil)
                progress.completedUnitCount = 100
            } catch {
                completionHandler(nil, [], false, error)
            }
        }
        return progress
    }

    // Delete item
    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        Task {
            do {
                let client = try SharedConfig.apiClient()
                try await client.deleteFile(id: identifier.rawValue)
                completionHandler(nil)
                progress.completedUnitCount = 1
            } catch {
                completionHandler(error)
            }
        }
        return progress
    }

    // Return enumerator for listing
    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        return FileProviderEnumerator(containerItemIdentifier: containerItemIdentifier)
    }
}
