import Network
import Observation

/// Tracks whether the current connection is expensive (cellular or a personal hotspot),
/// so the app can pick lighter streams and refresh less.
@Observable @MainActor
final class NetworkStatus {
    static let shared = NetworkStatus()
    private(set) var isExpensive = false
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let expensive = path.isExpensive || path.usesInterfaceType(.cellular)
            Task { @MainActor in NetworkStatus.shared.isExpensive = expensive }
        }
        monitor.start(queue: DispatchQueue(label: "network-status"))
    }
}
