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

    // MARK: - Signal helper (critical for keeping Finder in sync)

    private func signalChange(for parentIdentifier: NSFileProviderItemIdentifier) {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        manager.signalEnumerator(for: parentIdentifier) { error in
            if let error = error {
                self.logger.error("signalEnumerator(\(parentIdentifier.rawValue, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        manager.signalEnumerator(for: .workingSet) { _ in }
    }

    // MARK: - Item lookup

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        Task {
            do {
                if identifier == .rootContainer {
                    completionHandler(FileProviderItem.rootContainer(), nil)
                } else if identifier == .trashContainer || identifier == .workingSet {
                    completionHandler(nil, NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.noSuchItem.rawValue))
                } else {
                    let client = try SharedConfig.sharedClient()
                    let serverFile = try await client.getFile(id: identifier.rawValue)
                    completionHandler(FileProviderItem(serverFile: serverFile), nil)
                }
                progress.completedUnitCount = 1
            } catch {
                logger.error("item(for: \(identifier.rawValue, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, error)
            }
        }
        return progress
    }

    // MARK: - Download

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        Task {
            do {
                let client = try SharedConfig.sharedClient()
                SharedConfig.setProgress(action: "Downloading", filename: itemIdentifier.rawValue, bytesTransferred: 0, totalBytes: 0)
                let (tempURL, serverFile) = try await client.downloadFileToDisk(id: itemIdentifier.rawValue)
                let item = FileProviderItem(serverFile: serverFile, isDownloaded: true)
                logger.info("Downloaded: \(serverFile.name, privacy: .public) (\(serverFile.size) bytes)")
                SharedConfig.setProgress(action: "Downloaded", filename: serverFile.name, bytesTransferred: serverFile.size, totalBytes: serverFile.size)
                SharedConfig.addRecentFile(filename: serverFile.name, action: "downloaded")
                SharedConfig.clearProgress()
                completionHandler(tempURL, item, nil)
                progress.completedUnitCount = 100

                // Signal parent so download state is reflected
                signalChange(for: .rootContainer)
            } catch {
                logger.error("Download failed for \(itemIdentifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, nil, error)
            }
        }
        return progress
    }

    // MARK: - Create

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        Task {
            do {
                let client = try SharedConfig.sharedClient()
                let parentID = itemTemplate.parentItemIdentifier == .rootContainer
                    ? SharedConfig.onDemandFolderID()
                    : itemTemplate.parentItemIdentifier.rawValue

                guard !parentID.isEmpty else {
                    logger.error("createItem: parentID is EMPTY — onDemandFolderID not configured")
                    completionHandler(nil, [], false, NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.notAuthenticated.rawValue))
                    return
                }

                logger.info("createItem: \(itemTemplate.filename, privacy: .public) in parent=\(parentID, privacy: .public)")

                if itemTemplate.contentType == .folder {
                    let result = try await client.createFolder(
                        name: itemTemplate.filename,
                        parentID: parentID
                    )
                    let item = FileProviderItem(serverFile: result)
                    completionHandler(item, [], false, nil)
                } else if let url = url {
                    // Consume resource fork so Finder considers it handled
                    let rsrcUrl = url.appendingPathComponent("..namedfork/rsrc")
                    let _ = try? Data(contentsOf: rsrcUrl, options: .alwaysMapped)

                    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                    let fileSize = (attrs[.size] as? Int64) ?? 0

                    SharedConfig.setProgress(action: "Uploading", filename: itemTemplate.filename, bytesTransferred: 0, totalBytes: fileSize)

                    let result = try await client.uploadFileFromDisk(
                        fileURL: url,
                        filename: itemTemplate.filename,
                        parentID: parentID
                    )
                    SharedConfig.setProgress(action: "Uploaded", filename: itemTemplate.filename, bytesTransferred: fileSize, totalBytes: fileSize)
                    SharedConfig.addRecentFile(filename: itemTemplate.filename, action: "uploaded")
                    SharedConfig.clearProgress()
                    let item = FileProviderItem(serverFile: result, isDownloaded: true)
                    completionHandler(item, [], false, nil)
                } else {
                    completionHandler(nil, [], false, NSError.fileProviderErrorForNonExistentItem(withIdentifier: itemTemplate.itemIdentifier))
                }
                progress.completedUnitCount = 100

                // CRITICAL: Signal macOS to refresh the enumerator
                signalChange(for: itemTemplate.parentItemIdentifier)
            } catch {
                logger.error("createItem(\(itemTemplate.filename, privacy: .public), parent=\(itemTemplate.parentItemIdentifier.rawValue, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, [], false, error)
            }
        }
        return progress
    }

    // MARK: - Modify

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
                let client = try SharedConfig.sharedClient()

                // Handle extended attributes only — just acknowledge, don't upload
                if changedFields == .extendedAttributes {
                    let serverFile = try await client.getFile(id: item.itemIdentifier.rawValue)
                    let updatedItem = FileProviderItem(serverFile: serverFile)
                    completionHandler(updatedItem, [], false, nil)
                    progress.completedUnitCount = 100
                    return
                }

                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    let newParentID = item.parentItemIdentifier == .rootContainer
                        ? SharedConfig.onDemandFolderID()
                        : item.parentItemIdentifier.rawValue
                    try await client.moveFile(id: item.itemIdentifier.rawValue, name: item.filename, parentID: newParentID)
                }

                // Consume resource fork if present
                if let url = newContents {
                    let rsrcUrl = url.appendingPathComponent("..namedfork/rsrc")
                    let _ = try? Data(contentsOf: rsrcUrl, options: .alwaysMapped)
                }

                if changedFields.contains(.contents), let url = newContents {
                    let parentID = item.parentItemIdentifier == .rootContainer ? SharedConfig.onDemandFolderID() : item.parentItemIdentifier.rawValue
                    let _ = try await client.uploadFileFromDisk(
                        fileURL: url,
                        filename: item.filename,
                        parentID: parentID
                    )
                }

                let serverFile = try await client.getFile(id: item.itemIdentifier.rawValue)
                let updatedItem = FileProviderItem(serverFile: serverFile, isDownloaded: newContents != nil)
                completionHandler(updatedItem, [], false, nil)
                progress.completedUnitCount = 100

                // Signal change
                signalChange(for: item.parentItemIdentifier)
            } catch {
                logger.error("modifyItem(\(item.filename, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, [], false, error)
            }
        }
        return progress
    }

    // MARK: - Delete

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        Task {
            do {
                let client = try SharedConfig.sharedClient()
                try await client.deleteFile(id: identifier.rawValue)
                completionHandler(nil)
                progress.completedUnitCount = 1

                // Signal root container since we don't know the parent
                signalChange(for: .rootContainer)
            } catch {
                logger.error("deleteItem(\(identifier.rawValue, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(error)
            }
        }
        return progress
    }

    // MARK: - Enumerator

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        return FileProviderEnumerator(containerItemIdentifier: containerItemIdentifier, domain: domain)
    }
}
