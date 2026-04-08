import FileProvider
import os.log

class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    let containerItemIdentifier: NSFileProviderItemIdentifier
    let domain: NSFileProviderDomain
    let cache: ItemCache?
    private let logger = Logger(subsystem: "com.syncvault.fileprovider", category: "Enumerator")

    init(containerItemIdentifier: NSFileProviderItemIdentifier, domain: NSFileProviderDomain, cache: ItemCache?) {
        self.containerItemIdentifier = containerItemIdentifier
        self.domain = domain
        self.cache = cache
        super.init()
    }

    func invalidate() {}

    // MARK: - Enumerate items (Fase 3: cache-first with background refresh)

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        Task {
            do {
                let parentID: String

                if containerItemIdentifier == .rootContainer || containerItemIdentifier == .workingSet {
                    parentID = SharedConfig.onDemandFolderID()
                    guard !parentID.isEmpty else {
                        logger.error("enumerateItems: onDemandFolderID is EMPTY")
                        observer.finishEnumeratingWithError(
                            NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.notAuthenticated.rawValue)
                        )
                        return
                    }
                } else if containerItemIdentifier == .trashContainer {
                    // We don't enumerate trash
                    observer.finishEnumerating(upTo: nil)
                    return
                } else {
                    parentID = containerItemIdentifier.rawValue
                }

                // For working set: return ALL items from cache (recursive)
                if containerItemIdentifier == .workingSet {
                    if let cache = cache {
                        let cachedItems = await cache.allItems()
                        if !cachedItems.isEmpty {
                            let items = cachedItems.map { FileProviderItem(serverFile: $0.toServerFile(), isDownloaded: $0.isDownloaded) }
                            observer.didEnumerate(items)
                            logger.info("enumerateItems(workingSet): \(items.count, privacy: .public) items from cache")
                        }
                    }
                    observer.finishEnumerating(upTo: nil)

                    // Background refresh
                    Task.detached { [weak self] in
                        await self?.refreshFromServer(parentID: parentID)
                    }
                    return
                }

                // For regular containers: cache-first, then background refresh
                var items: [FileProviderItem] = []

                // 1. Try cache first
                if let cache = cache {
                    let cachedItems = await cache.listChildren(parentID: parentID)
                    if !cachedItems.isEmpty {
                        items = cachedItems.map { FileProviderItem(serverFile: $0.toServerFile(), isDownloaded: $0.isDownloaded) }
                        logger.info("enumerateItems: \(items.count, privacy: .public) items from cache for parentID=\(parentID, privacy: .public)")
                    }
                }

                // 2. If cache is empty, fetch from server directly (first time)
                if items.isEmpty {
                    let client = try SharedConfig.sharedClient()
                    let files = try await client.listFiles(parentID: parentID)

                    // Preserve download state from cache if item was previously uploaded
                    if let cache = cache {
                        var mappedItems: [FileProviderItem] = []
                        for file in files {
                            let existing = await cache.getItem(file.id)
                            let downloaded = existing?.isDownloaded ?? false
                            await cache.upsert(file, downloaded: downloaded)
                            mappedItems.append(FileProviderItem(serverFile: file, isDownloaded: downloaded))
                        }
                        items = mappedItems
                    } else {
                        items = files.map { FileProviderItem(serverFile: $0) }
                    }
                    logger.info("enumerateItems: \(items.count, privacy: .public) items from server for parentID=\(parentID, privacy: .public)")
                }

                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)

                // 3. Background refresh to catch server-side changes
                Task.detached { [weak self] in
                    await self?.refreshFromServer(parentID: parentID)
                }
            } catch {
                logger.error("enumerateItems failed: \(error.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    /// Refresh cache from server and signal if there are changes
    private func refreshFromServer(parentID: String) async {
        do {
            let client = try SharedConfig.sharedClient()
            let files = try await client.listFiles(parentID: parentID)
            guard let cache = cache else { return }

            let cachedItems = await cache.listChildren(parentID: parentID)
            let serverIDs = Set(files.map { $0.id })
            let cachedIDs = Set(cachedItems.map { $0.id })

            var changed = false

            for file in files {
                let existing = await cache.getItem(file.id)
                if existing == nil || existing?.updatedAt != file.updatedAt || existing?.name != file.name {
                    await cache.upsert(file, downloaded: existing?.isDownloaded ?? false)
                    changed = true
                }
            }

            // Mark items as deleted if they're in cache but not on server
            for id in cachedIDs where !serverIDs.contains(id) {
                await cache.markDeleted(id)
                changed = true
            }

            if changed {
                guard let manager = NSFileProviderManager(for: domain) else { return }
                if containerItemIdentifier == .workingSet {
                    manager.signalEnumerator(for: .workingSet) { _ in }
                }
                manager.signalEnumerator(for: containerItemIdentifier) { _ in }
            }
        } catch {
            // Silent fail — polling will retry
        }
    }

    // MARK: - Enumerate changes (uses local rank)

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        Task {
            if let cache = cache {
                let anchorRank = decodeSyncAnchorRank(syncAnchor)
                let (updated, deleted) = await cache.getChanges(sinceRank: anchorRank)

                if !updated.isEmpty {
                    let items = updated.map { FileProviderItem(serverFile: $0.toServerFile(), isDownloaded: $0.isDownloaded) }
                    observer.didUpdate(items)
                }
                if !deleted.isEmpty {
                    observer.didDeleteItems(withIdentifiers: deleted.map { NSFileProviderItemIdentifier($0) })
                }

                let currentRank = await cache.currentRank()
                logger.info("enumerateChanges: \(updated.count, privacy: .public) updated, \(deleted.count, privacy: .public) deleted (rank \(anchorRank) → \(currentRank))")
                observer.finishEnumeratingChanges(upTo: encodeSyncAnchorRank(currentRank), moreComing: false)
            } else {
                // Fallback: no cache, use date-based
                do {
                    let client = try SharedConfig.sharedClient()
                    let anchorDate = decodeSyncAnchorDate(syncAnchor) ?? Date.distantPast
                    let changes = try await client.getChanges(since: anchorDate)

                    var updatedItems: [FileProviderItem] = []
                    var deletedIDs: [NSFileProviderItemIdentifier] = []

                    for file in changes.changes {
                        if file.deletedAt != nil {
                            deletedIDs.append(NSFileProviderItemIdentifier(file.id))
                        } else {
                            updatedItems.append(FileProviderItem(serverFile: file))
                        }
                    }

                    if !updatedItems.isEmpty { observer.didUpdate(updatedItems) }
                    if !deletedIDs.isEmpty { observer.didDeleteItems(withIdentifiers: deletedIDs) }

                    observer.finishEnumeratingChanges(upTo: encodeSyncAnchorDate(Date()), moreComing: false)
                } catch {
                    observer.finishEnumeratingWithError(error)
                }
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        if let cache = cache {
            Task {
                let rank = await cache.currentRank()
                completionHandler(encodeSyncAnchorRank(rank))
            }
        } else {
            completionHandler(encodeSyncAnchorDate(Date()))
        }
    }

    // MARK: - Sync anchor encoding (rank-based for cache, date-based for fallback)

    private func encodeSyncAnchorRank(_ rank: Int64) -> NSFileProviderSyncAnchor {
        var r = rank
        let data = Data(bytes: &r, count: MemoryLayout<Int64>.size)
        return NSFileProviderSyncAnchor(data)
    }

    private func decodeSyncAnchorRank(_ anchor: NSFileProviderSyncAnchor) -> Int64 {
        guard anchor.rawValue.count == MemoryLayout<Int64>.size else { return 0 }
        return anchor.rawValue.withUnsafeBytes { $0.load(as: Int64.self) }
    }

    private func encodeSyncAnchorDate(_ date: Date) -> NSFileProviderSyncAnchor {
        let str = ISO8601DateFormatter().string(from: date)
        return NSFileProviderSyncAnchor(str.data(using: .utf8)!)
    }

    private func decodeSyncAnchorDate(_ anchor: NSFileProviderSyncAnchor) -> Date? {
        guard let str = String(data: anchor.rawValue, encoding: .utf8) else { return nil }
        return ISO8601DateFormatter().date(from: str)
    }
}
