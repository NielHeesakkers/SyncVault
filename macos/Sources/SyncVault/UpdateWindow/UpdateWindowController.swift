import Foundation
import Combine

@MainActor
final class UpdateWindowController: ObservableObject {
    enum State: Equatable {
        case available
        case downloading(progress: Double)
        case ready(dmg: URL)
        case error(String)
    }

    let version: String
    let changelog: [String]
    let sizeBytes: Int64
    @Published private(set) var state: State = .available

    /// Bridged in Task 24 — controller calls these to drive the real download/install.
    var onInstallRequested: (() -> Void)? = nil
    var onQuitAndInstall: (() -> Void)? = nil
    var onCancelDownload: (() -> Void)? = nil

    init(version: String, changelog: [String], sizeBytes: Int64) {
        self.version = version
        self.changelog = changelog
        self.sizeBytes = sizeBytes
    }

    func install() {
        state = .downloading(progress: 0)
        onInstallRequested?()
    }

    func updateProgress(_ p: Double) {
        guard case .downloading = state else { return }
        state = .downloading(progress: max(0, min(1, p)))
    }

    func downloadCompleted(at url: URL) {
        state = .ready(dmg: url)
    }

    func failed(_ message: String) {
        state = .error(message)
    }

    func quitAndInstall() {
        onQuitAndInstall?()
    }

    func cancel() {
        onCancelDownload?()
        state = .available
    }
}
