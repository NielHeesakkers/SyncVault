import Foundation
import Network
import Combine

/// Watches the current network path and exposes whether the link is expensive
/// (cellular / personal hotspot) or constrained (Low Data Mode). Used by
/// AppState to auto-pause uploads on metered Wi-Fi so we don't burn through
/// someone's data plan with a 50 GB sync.
///
/// Strategy:
///  * NWPathMonitor fires whenever the path changes (Wi-Fi → cellular, etc.).
///  * Each change recomputes `isMetered` and notifies subscribers.
///  * AppState observes; if metered changes from false → true while connected,
///    pauses sync with an autoPaused flag so it can auto-resume later.
@MainActor
final class NetworkMonitor: ObservableObject {

    /// True when the current path is expensive (cellular tether, personal hotspot)
    /// or constrained (Low Data Mode). Wi-Fi / Ethernet → false.
    @Published var isMetered: Bool = false

    /// Last-known status string for diagnostics ("Wi-Fi", "Cellular", "Hotspot").
    @Published var statusText: String = "—"

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.syncvault.network-monitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let metered = path.isExpensive || path.isConstrained
            let status = Self.describe(path: path)
            Task { @MainActor [weak self] in
                self?.isMetered = metered
                self?.statusText = status
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    nonisolated private static func describe(path: NWPath) -> String {
        if path.usesInterfaceType(.wiredEthernet) { return "Ethernet" }
        if path.usesInterfaceType(.cellular)     { return path.isExpensive ? "Cellular" : "Cellular (unlimited)" }
        if path.usesInterfaceType(.wifi) {
            if path.isExpensive   { return "Wi-Fi (hotspot)" }
            if path.isConstrained { return "Wi-Fi (Low Data Mode)" }
            return "Wi-Fi"
        }
        if path.status == .unsatisfied { return "Offline" }
        return "Other"
    }
}
