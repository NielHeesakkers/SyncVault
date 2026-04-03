import FileProvider
import os.log

class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    let containerItemIdentifier: NSFileProviderItemIdentifier
    let domain: NSFileProviderDomain
    private let logger = Logger(subsystem: "com.syncvault.fileprovider", category: "Enumerator")

    init(containerItemIdentifier: NSFileProviderItemIdentifier, domain: NSFileProviderDomain) {
        self.containerItemIdentifier = containerItemIdentifier
        self.domain = domain
        super.init()
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        Task {
            do {
                let client = try SharedConfig.apiClient()
                let parentID: String

                if containerItemIdentifier == .rootContainer {
                    parentID = SharedConfig.onDemandFolderID()
                    guard !parentID.isEmpty else {
                        logger.error("enumerateItems: onDemandFolderID is EMPTY — cannot enumerate")
                        observer.finishEnumeratingWithError(
                            NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.notAuthenticated.rawValue)
                        )
                        return
                    }
                } else if containerItemIdentifier == .workingSet {
                    // Working set: enumerate all items recursively (for now, enumerate root)
                    parentID = SharedConfig.onDemandFolderID()
                    guard !parentID.isEmpty else {
                        observer.finishEnumerating(upTo: nil)
                        return
                    }
                } else {
                    parentID = containerItemIdentifier.rawValue
                }

                logger.info("enumerateItems: container=\(self.containerItemIdentifier.rawValue, privacy: .public) parentID=\(parentID, privacy: .public)")

                let files = try await client.listFiles(parentID: parentID)
                let items = files.map { FileProviderItem(serverFile: $0) }

                logger.info("enumerateItems: got \(items.count, privacy: .public) items for parentID=\(parentID, privacy: .public)")

                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                logger.error("enumerateItems failed: \(error.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        Task {
            do {
                let client = try SharedConfig.apiClient()
                let anchorDate = decodeSyncAnchor(syncAnchor) ?? Date.distantPast

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

                logger.info("enumerateChanges: \(updatedItems.count, privacy: .public) updated, \(deletedIDs.count, privacy: .public) deleted")

                if !updatedItems.isEmpty {
                    observer.didUpdate(updatedItems)
                }
                if !deletedIDs.isEmpty {
                    observer.didDeleteItems(withIdentifiers: deletedIDs)
                }

                let newAnchor = encodeSyncAnchor(Date())
                observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
            } catch {
                logger.error("enumerateChanges failed: \(error.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(encodeSyncAnchor(Date()))
    }

    // Encode/decode sync anchor as ISO8601 date
    private func encodeSyncAnchor(_ date: Date) -> NSFileProviderSyncAnchor {
        let str = ISO8601DateFormatter().string(from: date)
        return NSFileProviderSyncAnchor(str.data(using: .utf8)!)
    }

    private func decodeSyncAnchor(_ anchor: NSFileProviderSyncAnchor) -> Date? {
        guard let str = String(data: anchor.rawValue, encoding: .utf8) else { return nil }
        return ISO8601DateFormatter().date(from: str)
    }
}
