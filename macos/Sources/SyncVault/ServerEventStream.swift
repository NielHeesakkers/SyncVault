import Foundation
import os

private let logger = Logger(subsystem: "com.syncvault.app", category: "ServerEventStream")

/// Decoded `file` event from the server's SSE broadcaster.
struct ServerFileEvent: Codable {
    let type: String           // "file_created" | "file_updated" | "file_deleted"
    let file_id: String
    let owner_id: String
    let relative_path: String?
    let name: String?
    let is_dir: Bool?
    let size: Int64?
    let content_hash: String?
    let rank: Int64
    let at: String
}

/// Persistent SSE subscriber. Opens /api/events, parses `event: file` frames,
/// invokes a callback per event, and auto-reconnects with exponential backoff.
///
/// Single-task design: one `reader` Task owns the URLSession data stream + the
/// reconnect loop. `stop()` cancels everything cleanly.
final class ServerEventStream {
    private let baseURL: String
    private let tokenProvider: () async -> String?
    private let onFileEvent: (ServerFileEvent) -> Void
    private let onConnected: (() -> Void)?

    private var readerTask: Task<Void, Never>?
    private var session: URLSession?

    init(
        baseURL: String,
        tokenProvider: @escaping () async -> String?,
        onFileEvent: @escaping (ServerFileEvent) -> Void,
        onConnected: (() -> Void)? = nil
    ) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.tokenProvider = tokenProvider
        self.onFileEvent = onFileEvent
        self.onConnected = onConnected
    }

    func start() {
        guard readerTask == nil else { return }
        readerTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        readerTask?.cancel()
        readerTask = nil
        session?.invalidateAndCancel()
        session = nil
    }

    /// Reconnect loop with exponential backoff capped at 60s. Cancellable.
    private func runLoop() async {
        var backoff: UInt64 = 1
        while !Task.isCancelled {
            do {
                try await connectOnce()
                backoff = 1 // successful disconnect → reset backoff
            } catch is CancellationError {
                return
            } catch {
                logger.info("SSE disconnected (\(error.localizedDescription)) — retrying in \(backoff)s")
            }
            // Sleep with cancellation support
            do {
                try await Task.sleep(nanoseconds: backoff * 1_000_000_000)
            } catch {
                return
            }
            backoff = min(backoff * 2, 60)
        }
    }

    /// One connect-and-read cycle. Throws on disconnect / error.
    private func connectOnce() async throws {
        guard let token = await tokenProvider(), !token.isEmpty else {
            // No token yet — wait, will retry via backoff
            throw URLError(.userAuthenticationRequired)
        }
        let url = URL(string: "\(baseURL)/api/events")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = .infinity

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 0       // no per-request timeout for long-lived stream
        config.timeoutIntervalForResource = 0
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let sess = URLSession(configuration: config)
        self.session = sess
        defer {
            sess.finishTasksAndInvalidate()
            if self.session === sess { self.session = nil }
        }

        let (bytes, response) = try await sess.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw URLError(.userAuthenticationRequired)
        }
        onConnected?()
        logger.info("SSE connected")

        // Parse SSE frames: blocks separated by blank lines.
        // Each block: lines like "event: file", "data: <json>", possibly comments ":keepalive".
        var currentEvent = ""
        var currentData = ""
        for try await line in bytes.lines {
            if Task.isCancelled { return }
            if line.isEmpty {
                // End of frame — dispatch if we have data
                if currentEvent == "file", let dataBytes = currentData.data(using: .utf8) {
                    if let evt = try? JSONDecoder().decode(ServerFileEvent.self, from: dataBytes) {
                        onFileEvent(evt)
                    }
                }
                currentEvent = ""
                currentData = ""
                continue
            }
            if line.hasPrefix(":") { continue } // comment (keepalive)
            if line.hasPrefix("event:") {
                currentEvent = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let chunk = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                if currentData.isEmpty {
                    currentData = chunk
                } else {
                    currentData += "\n" + chunk
                }
            }
        }
        // Stream ended cleanly (server closed) — return so outer loop reconnects.
    }
}
