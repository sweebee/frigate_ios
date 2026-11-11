import Foundation
import Observation
import SwiftUI

/// Live state of one configured server.
@Observable @MainActor
final class ServerConnection: Identifiable {
    enum Status: Equatable {
        case connecting
        case online
        case offline(String)
    }

    var server: ServerConfig
    var status: Status = .connecting
    var client: FrigateClient?
    var usingRemote = false
    var version: String?
    var config: FrigateConfig?
    var stats: FrigateStats?
    var summary: ReviewSummary?
    /// Labels of objects currently being tracked, per camera.
    var activeObjects: [String: [String]] = [:]
    /// Start of the most recent review item, per camera.
    var lastActivity: [String: Date] = [:]

    nonisolated var id: UUID { serverID }
    private let serverID: UUID

    init(server: ServerConfig) {
        self.server = server
        self.serverID = server.id
    }

    var isOnline: Bool { status == .online }
    var cameras: [CameraConfig] { config?.orderedCameras ?? [] }

    var lastSeen: Date? {
        get { UserDefaults.standard.object(forKey: "lastSeen.\(server.id)") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastSeen.\(server.id)") }
    }

    func isCameraOnline(_ name: String) -> Bool {
        guard isOnline else { return false }
        guard let fps = stats?.cameras[name]?.cameraFps else { return true }
        return fps > 0
    }

    func isDetectEnabled(_ cam: CameraConfig) -> Bool {
        stats?.cameras[cam.name]?.detectionEnabled ?? cam.detect?.enabled ?? true
    }

    /// "6 cameras · v0.18 · Local" or "Offline · last seen 2 days ago".
    var metaLine: String {
        switch status {
        case .connecting: return L("Connecting…")
        case .offline:
            if let lastSeen { return L("Offline · last seen \(FrigateFormat.relative(lastSeen).lowercased())") }
            return L("Offline")
        case .online:
            var parts = [L("\(cameras.count) cameras")]
            if let version { parts.append(FrigateFormat.shortVersion(version)) }
            parts.append(usingRemote ? L("Remote") : L("Local"))
            return parts.joined(separator: " · ")
        }
    }

    var unreviewedAlerts: Int { summary?.last24Hours?.unreviewedAlerts ?? 0 }

    // MARK: Connecting

    func connect() async {
        if client == nil { status = .connecting }
        var candidates: [(URL, Bool)] = []
        if let u = ServerConfig.normalizedURL(server.url) { candidates.append((u, false)) }
        if let r = server.remoteURL, let u = ServerConfig.normalizedURL(r) { candidates.append((u, true)) }
        guard !candidates.isEmpty else { status = .offline(FrigateError.invalidURL.localizedDescription); return }

        var lastError: Error = FrigateError.notFrigate
        for (url, remote) in candidates {
            let c = FrigateClient(baseURL: url)
            do {
                let v = try await Self.authenticate(client: c, server: server, password: server.password)
                client = c
                usingRemote = remote
                version = v
                config = try await c.config()
                status = .online
                lastSeen = Date()
                await refresh()
                return
            } catch {
                if Task.isCancelled { return }
                lastError = error
            }
        }
        status = .offline(lastError.localizedDescription)
    }

    /// Checks the server responds, logging in first when credentials are set. Returns the version.
    nonisolated static func authenticate(client: FrigateClient, server: ServerConfig, password: String?) async throws -> String {
        if let user = server.username, !user.isEmpty {
            // Probe first: an unauthenticated port answers without a login.
            if let v = try? await client.version(timeout: 5) { return v }
            try await client.login(user: user, password: password ?? "")
        }
        return try await client.version()
    }

    /// Refreshes the frequently changing state.
    func refresh() async {
        guard let client else { return }
        async let statsReq = try? client.stats()
        async let summaryReq = try? client.reviewSummary()
        async let activeReq = try? client.activeEvents()
        async let recentReq = try? client.reviews(after: Date().addingTimeInterval(-86400), limit: 200)
        let (s, sum, active, recent) = await (statsReq, summaryReq, activeReq, recentReq)
        // A cancelled refresh (view went away) says nothing about the server.
        if Task.isCancelled { return }

        if s == nil && sum == nil {
            // Lost the server; try to reconnect next time.
            if (try? await client.version(timeout: 4)) == nil {
                if Task.isCancelled { return }
                status = .offline(L("Not reachable"))
                return
            }
        }
        status = .online
        lastSeen = Date()
        if let s { stats = s }
        if let sum { summary = sum }
        if let active {
            var map: [String: [String]] = [:]
            for e in active where map[e.camera]?.contains(e.label) != true {
                map[e.camera, default: []].append(e.label)
            }
            activeObjects = map
        }
        if let recent {
            var map: [String: Date] = [:]
            for r in recent where (map[r.camera] ?? .distantPast) < r.start { map[r.camera] = r.start }
            lastActivity = map
        }
    }
}

@Observable @MainActor
final class AppModel {
    enum Tab: Hashable { case live, review, history, settings }
    enum Scope: Hashable, Codable {
        case all
        case server(UUID)
    }

    var servers: [ServerConfig] = [] { didSet { saveServers() } }
    var connections: [UUID: ServerConnection] = [:]
    var scope: Scope = .all { didSet { saveScope() } }
    var tab: Tab = .live
    var livePath = NavigationPath()
    var reviewPath = NavigationPath()
    var historyPath = NavigationPath()
    /// Set by deep links to switch the Review segment (alert, detection, motion).
    var reviewKindRequest: String?
    /// Show review items from all servers instead of only the selected one. Off by default.
    private(set) var combinedReview: Bool = false

    func setCombinedReview(_ on: Bool) {
        combinedReview = on
        UserDefaults.standard.set(on, forKey: "combinedReview2")
    }
    /// Set to open the add-server sheet.
    var showAddServer = false

    init() {
        if let data = UserDefaults.standard.data(forKey: "servers"),
           let saved = try? JSONDecoder().decode([ServerConfig].self, from: data) {
            servers = saved
        }
        if let data = UserDefaults.standard.data(forKey: "scope"),
           let s = try? JSONDecoder().decode(Scope.self, from: data) {
            scope = s
        }
        combinedReview = UserDefaults.standard.bool(forKey: "combinedReview2")
        for s in servers { connections[s.id] = ServerConnection(server: s) }
        if case .server(let id) = scope, !servers.contains(where: { $0.id == id }) { scope = .all }
    }

    private func saveServers() {
        if let data = try? JSONEncoder().encode(servers) { UserDefaults.standard.set(data, forKey: "servers") }
    }
    private func saveScope() {
        if let data = try? JSONEncoder().encode(scope) { UserDefaults.standard.set(data, forKey: "scope") }
    }

    var orderedConnections: [ServerConnection] { servers.compactMap { connections[$0.id] } }
    var onlineConnections: [ServerConnection] { orderedConnections.filter(\.isOnline) }

    /// Connections in the current Live/History scope.
    var scopedConnections: [ServerConnection] {
        switch scope {
        case .all: return orderedConnections
        case .server(let id): return connections[id].map { [$0] } ?? []
        }
    }

    /// Connections used for Review, which may combine all servers.
    var reviewConnections: [ServerConnection] {
        combinedReview ? orderedConnections : scopedConnections
    }

    var scopeTitle: String {
        switch scope {
        case .all: return L("All servers")
        case .server(let id): return connections[id]?.server.name ?? L("Server")
        }
    }

    var unreviewedAlerts: Int { reviewConnections.reduce(0) { $0 + $1.unreviewedAlerts } }

    func connection(for id: UUID) -> ServerConnection? { connections[id] }

    func connectAll() async {
        await withTaskGroup(of: Void.self) { group in
            for c in orderedConnections { group.addTask { await c.connect() } }
        }
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for c in orderedConnections {
                group.addTask { @MainActor in
                    if c.client == nil || !c.isOnline { await c.connect() } else { await c.refresh() }
                }
            }
        }
    }

    // MARK: Editing servers

    func save(_ server: ServerConfig, password: String?) {
        var server = server
        if let i = servers.firstIndex(where: { $0.id == server.id }) {
            servers[i] = server
        } else {
            let used = Set(servers.map(\.tintIndex))
            server.tintIndex = (0..<Theme.serverTints.count).first { !used.contains($0) } ?? servers.count
            servers.append(server)
        }
        server.password = password
        let conn = ServerConnection(server: server)
        connections[server.id] = conn
        if servers.count == 1 { scope = .server(server.id) }
        Task { await conn.connect() }
    }

    func delete(_ server: ServerConfig) {
        server.password = nil
        servers.removeAll { $0.id == server.id }
        connections[server.id] = nil
        if scope == .server(server.id) { scope = .all }
    }
}
