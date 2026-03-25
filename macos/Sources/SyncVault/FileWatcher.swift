import Foundation
import os

private let logger = Logger(subsystem: "com.syncvault.app", category: "FileWatcher")

/// Watches directories for file changes using FSEvents.
/// Only reports changed paths since last check, avoiding full directory scans.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let path: String
    private let queue = DispatchQueue(label: "com.syncvault.filewatcher", qos: .utility)
    private var changedPaths: Set<String> = []
    private let lock = NSLock()
    private var isInitialScan = true

    /// Called (on main queue) when file changes are detected. Debounced 1 second.
    var onChange: (() -> Void)?
    private var debounceWorkItem: DispatchWorkItem?

    init(path: String) {
        self.path = path
    }

    deinit {
        stop()
    }

    /// Start watching the directory for changes.
    func start() {
        guard stream == nil else { return }

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagUseCFTypes) |
            UInt32(kFSEventStreamCreateFlagFileEvents) |
            UInt32(kFSEventStreamCreateFlagNoDefer)

        guard let eventStream = FSEventStreamCreate(
            nil,
            { (_, info, numEvents, eventPaths, eventFlags, _) in
                guard let info = info else { return }
                let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
                let flags = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))

                watcher.handleEvents(paths: paths, flags: flags)
            },
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // latency in seconds
            flags
        ) else {
            logger.error("Failed to create FSEventStream for \(self.path)")
            return
        }

        stream = eventStream
        FSEventStreamSetDispatchQueue(eventStream, queue)
        FSEventStreamStart(eventStream)
        logger.info("Started watching: \(self.path)")
    }

    /// Stop watching.
    func stop() {
        guard let stream = stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        logger.info("Stopped watching: \(self.path)")
    }

    /// Get all changed paths since last call, then clear the set.
    /// Returns nil on first call (signals that a full scan is needed).
    func consumeChangedPaths() -> Set<String>? {
        lock.lock()
        defer { lock.unlock() }

        if isInitialScan {
            isInitialScan = false
            return nil // Signal: do a full scan
        }

        let paths = changedPaths
        changedPaths.removeAll()
        return paths
    }

    /// Mark that initial scan is complete (future calls return incremental changes).
    func markInitialScanComplete() {
        lock.lock()
        defer { lock.unlock() }
        isInitialScan = false
    }

    private func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        lock.lock()

        for (i, eventPath) in paths.enumerated() {
            let flag = flags[i]

            // Skip directory-level events, hidden files, and .DS_Store
            let name = URL(fileURLWithPath: eventPath).lastPathComponent
            if name == ".DS_Store" || name.hasPrefix(".") { continue }

            // Include created, modified, removed, renamed events
            let isRelevant =
                (flag & UInt32(kFSEventStreamEventFlagItemCreated)) != 0 ||
                (flag & UInt32(kFSEventStreamEventFlagItemModified)) != 0 ||
                (flag & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0 ||
                (flag & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0 ||
                (flag & UInt32(kFSEventStreamEventFlagItemInodeMetaMod)) != 0

            if isRelevant {
                changedPaths.insert(eventPath)
            }
        }

        lock.unlock()

        // Debounce: fire onChange 1 second after the last event
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange?()
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}
