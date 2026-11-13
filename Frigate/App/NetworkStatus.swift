import Network
import Observation

/// Tracks whether the current connection is expensive (cellular or a personal hotspot),
/// so the app can pick lighter streams and refresh less, and counts network changes
/// (Wi-Fi to mobile data, another Wi-Fi network) so servers can switch address.
@Observable @MainActor
final class NetworkStatus {
    static let shared = NetworkStatus()
    private(set) var isExpensive = false
    /// Goes up each time the network changes; not for the first reading at launch.
    private(set) var changes = 0
    private var signature: String?
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let expensive = path.isExpensive || path.usesInterfaceType(.cellular)
            // The gateway tells one Wi-Fi network from another.
            let types: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet, .other]
            let sig = "\(path.status) \(types.filter { path.usesInterfaceType($0) }) \(path.gateways)"
            Task { @MainActor in
                let status = NetworkStatus.shared
                status.isExpensive = expensive
                if let old = status.signature, old != sig { status.changes += 1 }
                status.signature = sig
            }
        }
        monitor.start(queue: DispatchQueue(label: "network-status"))
    }
}
