import FileProvider
import os.log

class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain
    let logger = Logger(subsystem: "com.syncvault.fileprovider", category: "Extension")
    let cache: ItemCache?
    private var pollTimer: DispatchSourceTimer?

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.cache = try? ItemCache()
        super.init()
        logger.info("FileProviderExtension initialized for domain: \(domain.displayName)")
        startPollingTimer()
    }

    func invalidate() {
        pollTimer?.cancel()
        pollTimer = nil
        logger.info("FileProviderExtension invalidated")
    }

    // MARK: - Background polling (Fase 6)

    private func startPollingTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            Task { await self.pollForChanges() }
        }
        timer.resume()
        pollTimer = timer
    }

    private func pollForChanges() async {
        do {
            let client = try SharedConfig.sharedClient()
            let folderID = SharedConfig.onDemandFolderID()
            guard !folderID.isEmpty else { return }

            let files = try await client.listFiles(parentID: folderID)
            guard let cache = cache else { return }

            let cachedItems = await cache.allItems()
            let serverIDs = Set(files.map { $0.id })
            let cachedIDs = Set(cachedItems.map { $0.id })

            var changed = false

            // New or updated items
            for file in files {
                let existing = await cache.getItem(file.id)
                if existing == nil || existing?.updatedAt != file.updatedAt {
                    await cache.upsert(file)
                    changed = true
                }
            }

            // Deleted items (in cache but not on server)
            for cachedID in cachedIDs where !serverIDs.contains(cachedID) {
                await cache.markDeleted(cachedID)
                changed = true
            }

            if changed {
                logger.info("pollForChanges: detected changes, signaling enumerator")
                signalChange(for: .rootContainer)
            }
        } catch {
            // Silent fail — will retry in 30s
        }
    }

    // MARK: - Signal helper

    private func signalChange(for parentIdentifier: NSFileProviderItemIdentifier) {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        manager.signalEnumerator(for: parentIdentifier) { error in
            if let error = error {
                self.logger.error("signalEnumerator(\(parentIdentifier.rawValue, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        manager.signalEnumerator(for: .workingSet) { _ in }
    }

    // MARK: - Item lookup (Fase 3: cache-first)

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
                    // Cache-first: try local cache, fallback to server
                    if let cached = await cache?.getItem(identifier.rawValue) {
                        completionHandler(FileProviderItem(serverFile: cached.toServerFile(), isDownloaded: cached.isDownloaded), nil)
                    } else {
                        let client = try SharedConfig.sharedClient()
                        let serverFile = try await client.getFile(id: identifier.rawValue)
                        await cache?.upsert(serverFile)
                        completionHandler(FileProviderItem(serverFile: serverFile), nil)
                    }
                }
                progress.completedUnitCount = 1
            } catch {
                logger.error("item(for: \(identifier.rawValue, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, error)
            }
        }
        return progress
    }

    // MARK: - Download (Fase 7: download state tracking)

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

                // Update cache with download state
                await cache?.upsert(serverFile, downloaded: true)

                SharedConfig.setProgress(action: "Downloaded", filename: serverFile.name, bytesTransferred: serverFile.size, totalBytes: serverFile.size)
                SharedConfig.addRecentFile(filename: serverFile.name, action: "downloaded")
                SharedConfig.clearProgress()
                completionHandler(tempURL, item, nil)
                progress.completedUnitCount = 100

                signalChange(for: item.parentItemIdentifier)
            } catch {
                logger.error("Download failed for \(itemIdentifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, nil, error)
            }
        }
        return progress
    }

    // MARK: - Error conversion (macOS only understands NSFileProviderError)

    private func toFileProviderError(_ error: Error) -> NSError {
        if let fpError = error as? FPAPIError {
            switch fpError {
            case .unauthorized:
                return NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.notAuthenticated.rawValue)
            case .serverError(let code):
                if code == 404 {
                    return NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.noSuchItem.rawValue)
                } else if code == 409 {
                    return NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.filenameCollision.rawValue)
                }
                return NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.serverUnreachable.rawValue,
                              userInfo: [NSLocalizedDescriptionKey: "Server error (\(code))"])
            case .invalidResponse:
                return NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.serverUnreachable.rawValue)
            }
        }
        return error as NSError
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
                // Skip macOS FileProvider system test files and hidden files
                if itemTemplate.filename.hasPrefix("drive_test_") || (itemTemplate.filename.hasPrefix(".") && itemTemplate.filename != ".sync") {
                    completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError))
                    progress.completedUnitCount = 100
                    return
                }

                let client = try SharedConfig.sharedClient()
                let parentID = itemTemplate.parentItemIdentifier == .rootContainer
                    ? SharedConfig.onDemandFolderID()
                    : itemTemplate.parentItemIdentifier.rawValue

                guard !parentID.isEmpty else {
                    logger.error("createItem: parentID is EMPTY")
                    completionHandler(nil, [], false, NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.notAuthenticated.rawValue))
                    return
                }

                logger.info("createItem: \(itemTemplate.filename, privacy: .public) in parent=\(parentID, privacy: .public)")

                if itemTemplate.contentType == .folder {
                    let result = try await client.createFolder(name: itemTemplate.filename, parentID: parentID)
                    await cache?.upsert(result)
                    let item = FileProviderItem(serverFile: result)
                    completionHandler(item, [], false, nil)
                } else if let url = url {
                    // Consume resource fork (Fase 8)
                    let rsrcUrl = url.appendingPathComponent("..namedfork/rsrc")
                    let _ = try? Data(contentsOf: rsrcUrl, options: .alwaysMapped)

                    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                    let fileSize = (attrs[.size] as? Int64) ?? 0

                    SharedConfig.setProgress(action: "Uploading", filename: itemTemplate.filename, bytesTransferred: 0, totalBytes: fileSize)

                    let result = try await client.uploadFileFromDisk(fileURL: url, filename: itemTemplate.filename, parentID: parentID)

                    await cache?.upsert(result, downloaded: true)

                    SharedConfig.setProgress(action: "Uploaded", filename: itemTemplate.filename, bytesTransferred: fileSize, totalBytes: fileSize)
                    SharedConfig.addRecentFile(filename: itemTemplate.filename, action: "uploaded")
                    SharedConfig.clearProgress()
                    let item = FileProviderItem(serverFile: result, isDownloaded: true)
                    completionHandler(item, [], false, nil)
                } else {
                    completionHandler(nil, [], false, NSError.fileProviderErrorForNonExistentItem(withIdentifier: itemTemplate.itemIdentifier))
                }
                progress.completedUnitCount = 100
                signalChange(for: itemTemplate.parentItemIdentifier)
            } catch {
                logger.error("createItem(\(itemTemplate.filename, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, [], false, toFileProviderError(error))
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

                // Handle extended attributes only (Fase 8)
                if changedFields == .extendedAttributes {
                    if let cached = await cache?.getItem(item.itemIdentifier.rawValue) {
                        completionHandler(FileProviderItem(serverFile: cached.toServerFile(), isDownloaded: cached.isDownloaded), [], false, nil)
                    } else {
                        let serverFile = try await client.getFile(id: item.itemIdentifier.rawValue)
                        completionHandler(FileProviderItem(serverFile: serverFile), [], false, nil)
                    }
                    progress.completedUnitCount = 100
                    return
                }

                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    let newParentID = item.parentItemIdentifier == .rootContainer
                        ? SharedConfig.onDemandFolderID()
                        : item.parentItemIdentifier.rawValue
                    try await client.moveFile(id: item.itemIdentifier.rawValue, name: item.filename, parentID: newParentID)
                }

                // Consume resource fork (Fase 8)
                if let url = newContents {
                    let rsrcUrl = url.appendingPathComponent("..namedfork/rsrc")
                    let _ = try? Data(contentsOf: rsrcUrl, options: .alwaysMapped)
                }

                if changedFields.contains(.contents), let url = newContents {
                    let parentID = item.parentItemIdentifier == .rootContainer ? SharedConfig.onDemandFolderID() : item.parentItemIdentifier.rawValue
                    let _ = try await client.uploadFileFromDisk(fileURL: url, filename: item.filename, parentID: parentID)
                }

                let serverFile = try await client.getFile(id: item.itemIdentifier.rawValue)
                await cache?.upsert(serverFile, downloaded: newContents != nil)
                let updatedItem = FileProviderItem(serverFile: serverFile, isDownloaded: newContents != nil)
                completionHandler(updatedItem, [], false, nil)
                progress.completedUnitCount = 100
                signalChange(for: item.parentItemIdentifier)
            } catch {
                logger.error("modifyItem(\(item.filename, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, [], false, toFileProviderError(error))
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
                await cache?.markDeleted(identifier.rawValue)
                completionHandler(nil)
                progress.completedUnitCount = 1
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
        return FileProviderEnumerator(containerItemIdentifier: containerItemIdentifier, domain: domain, cache: cache)
    }
}
