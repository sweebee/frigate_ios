import Foundation
import Observation
import SwiftUI

/// What a camera sees right now: motion, and labels of objects that are moving.
struct CameraActivity: Equatable {
    var motion = false
    var tracking: [String] = []
}

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
    /// go2rtc stream names, to offer only streams that exist and skip straight to snapshots
    /// for cameras without a restream. Nil until loaded.
    var go2rtcStreams: Set<String>?
    var stats: FrigateStats?
    var summary: ReviewSummary?
    /// Labels of objects currently being tracked, per camera.
    var activeObjects: [String: [String]] = [:]
    /// Start of the most recent review item, per camera.
    var lastActivity: [String: Date] = [:]
    /// When the config was last fetched; it is fetched again now and then to pick up new cameras.
    private var configLoaded = Date.distantPast
    /// Live motion and tracking per camera, pushed by Frigate over its websocket.
    var activity: [String: CameraActivity] = [:]
    private var activitySocket: URLSessionWebSocketTask?

    nonisolated var id: UUID { serverID }
    private let serverID: UUID

    init(server: ServerConfig) {
        self.server = server
        self.serverID = server.id
    }

    var isOnline: Bool { status == .online }
    var cameras: [CameraConfig] { config?.orderedCameras ?? [] }

    /// Zones configured on this server's cameras (all, or only `only` when it names cameras).
    func zones(only: Set<String> = []) -> [String] {
        let cams = cameras.filter { only.isEmpty || only.contains($0.name) }
        return Set(cams.flatMap { $0.zones?.keys.map { $0 } ?? [] })
            .sorted { FrigateFormat.prettyName($0).localizedStandardCompare(FrigateFormat.prettyName($1)) == .orderedAscending }
    }

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

    /// A server address that answered and accepted the login.
    private struct Attempt {
        let client: FrigateClient
        let remote: Bool
        let version: String
        let config: FrigateConfig
    }

    private enum Outcome {
        case answered(Attempt)
        case failed(Bool, Error)
        case graceOver
    }

    /// Connects through the home address or the remote one. Both are tried at once: the home
    /// address wins when it answers, and the remote one is taken as soon as the home address
    /// fails, or has not answered within a moment after the remote one did. Away from home a
    /// LAN address often just times out, which used to delay the switch by 20 seconds or more.
    func connect() async {
        if client == nil { status = .connecting }
        var candidates: [(URL, Bool)] = []
        if let u = ServerConfig.normalizedURL(server.url) { candidates.append((u, false)) }
        if let r = server.remoteURL, let u = ServerConfig.normalizedURL(r) { candidates.append((u, true)) }
        guard !candidates.isEmpty else { status = .offline(FrigateError.invalidURL.localizedDescription); return }

        let server = self.server
        var lastError: Error = FrigateError.notFrigate
        let picked: Attempt? = await withTaskGroup(of: Outcome.self) { group in
            for (url, remote) in candidates {
                group.addTask {
                    do { return .answered(try await Self.attempt(url, remote: remote, server: server)) }
                    catch { return .failed(remote, error) }
                }
            }
            var pending = candidates.count
            var remoteHit: Attempt?
            var homeFailed = !candidates.contains { !$0.1 }
            while let outcome = await group.next() {
                switch outcome {
                case .answered(let a) where !a.remote:
                    group.cancelAll()
                    return a
                case .answered(let a):
                    pending -= 1
                    if homeFailed { group.cancelAll(); return a }
                    remoteHit = a
                    group.addTask {
                        try? await Task.sleep(for: .milliseconds(1500))
                        return .graceOver
                    }
                case .failed(let remote, let error):
                    pending -= 1
                    lastError = error
                    if !remote {
                        homeFailed = true
                        if let remoteHit { group.cancelAll(); return remoteHit }
                    }
                    if pending == 0 && remoteHit == nil { group.cancelAll(); return nil }
                case .graceOver:
                    if let remoteHit { group.cancelAll(); return remoteHit }
                }
            }
            return remoteHit
        }
        if Task.isCancelled { return }
        guard let a = picked else {
            status = .offline(lastError.localizedDescription)
            return
        }
        // Another address than before: the event feed must follow it.
        if let old = client, old.baseURL != a.client.baseURL { stopActivityFeed() }
        client = a.client
        usingRemote = a.remote
        version = a.version
        config = a.config
        configLoaded = Date()
        go2rtcStreams = try? await a.client.go2rtcStreams()
        status = .online
        lastSeen = Date()
        await refresh()
    }

    private nonisolated static func attempt(_ url: URL, remote: Bool, server: ServerConfig) async throws -> Attempt {
        let c = FrigateClient(baseURL: url)
        let v = try await authenticate(client: c, server: server, password: server.password)
        c.version = v
        let config = try await c.config()
        return Attempt(client: c, remote: remote, version: v, config: config)
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

    // MARK: Activity feed

    /// Opens Frigate's websocket for motion and tracked objects, unless it is already open.
    /// The web UI uses the same feed for its red outline and motion dot.
    func startActivityFeed() {
        guard let client else { return }
        if let task = activitySocket, task.state == .running { return }
        let task = client.session.webSocketTask(with: client.socketURL("ws"))
        activitySocket = task
        task.resume()
        Task {
            try? await task.send(.string(#"{"topic":"onConnect","message":""}"#))
            while true {
                guard let message = try? await task.receive() else { break }
                if case .string(let text) = message { handleActivity(text) }
            }
            if activitySocket === task {
                activitySocket = nil
                activity = [:]
            }
        }
    }

    func stopActivityFeed() {
        activitySocket?.cancel(with: .goingAway, reason: nil)
        activitySocket = nil
        activity = [:]
    }

    private func handleActivity(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let topic = msg["topic"] as? String else { return }
        if topic == "camera_activity" {
            guard let payload = (msg["payload"] as? String)?.data(using: .utf8),
                  let cams = try? JSONSerialization.jsonObject(with: payload) as? [String: [String: Any]] else { return }
            var next: [String: CameraActivity] = [:]
            for (cam, info) in cams {
                let objects = info["objects"] as? [[String: Any]] ?? []
                // Moving objects only: a parked car is tracked but not "active".
                let moving = objects.filter { ($0["stationary"] as? Bool) != true }.compactMap { $0["label"] as? String }
                next[cam] = CameraActivity(motion: info["motion"] as? Bool ?? false, tracking: moving)
            }
            activity = next
        } else if topic.hasSuffix("/motion"), let state = msg["payload"] as? String {
            let cam = String(topic.dropLast("/motion".count))
            guard !cam.contains("/") else { return }
            activity[cam, default: CameraActivity()].motion = state == "ON"
        }
    }

    /// Refreshes the frequently changing state. `reloadConfig` also fetches the config again
    /// (new or renamed cameras); it is fetched anyway when older than five minutes.
    /// Live streams of a camera that go2rtc can play; see `CameraConfig.streams(available:)`.
    func liveStreams(_ camera: CameraConfig) -> [(title: String, name: String)] {
        camera.streams(available: go2rtcStreams)
    }

    func refresh(reloadConfig: Bool = false) async {
        guard let client else { return }
        if reloadConfig || Date().timeIntervalSince(configLoaded) > 300 {
            if let fresh = try? await client.config() {
                config = fresh
                configLoaded = Date()
                if let streams = try? await client.go2rtcStreams() { go2rtcStreams = streams }
            }
        }
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
        startActivityFeed()
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
    /// `exports` is a section of its own only on iPad and Mac; on the phone it is a row in Explore.
    enum Tab: Hashable { case live, review, explore, exports, chat, settings, more }
    enum Scope: Hashable, Codable {
        case all
        case server(UUID)
    }

    var servers: [ServerConfig] = [] { didSet { saveServers() } }
    var connections: [UUID: ServerConnection] = [:]
    var scope: Scope = .all { didSet { saveScope() } }
    var tab: Tab = .live
    var livePath = NavigationPath() { didSet { if livePath.isEmpty { openCamera = nil } } }
    /// The camera picked in the sidebar (wide layout), so the sidebar can mark it.
    var openCamera: CameraRoute?
    /// A video fills the window (iPad and Mac): the section rail steps aside.
    var immersive = false
    var reviewPath = NavigationPath()
    var explorePath = NavigationPath()
    var exportsPath = NavigationPath()
    /// Exports deleted in this session (`ExportEntry.id`); lists leave them out, even when a
    /// load that was already under way still returns them.
    var deletedExports: Set<String> = []
    /// The phone's More tab (exports, chat, settings).
    var morePath = NavigationPath()
    /// Set by deep links to switch the Review segment (alert, detection, motion).
    var reviewKindRequest: String?
    /// Play the low-resolution live stream in the camera overview instead of snapshots.
    var liveGrid: Bool = UserDefaults.standard.bool(forKey: "liveGrid") {
        didSet { UserDefaults.standard.set(liveGrid, forKey: "liveGrid") }
    }
    /// Also play live tiles on mobile data.
    var liveGridOnCellular: Bool = UserDefaults.standard.bool(forKey: "liveGridOnCellular") {
        didSet { UserDefaults.standard.set(liveGridOnCellular, forKey: "liveGridOnCellular") }
    }
    /// Switch a tile to live video while its camera sees motion or a moving object, like
    /// Frigate's "Automatic live view". On by default.
    var autoLive: Bool = UserDefaults.standard.object(forKey: "autoLive") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoLive, forKey: "autoLive") }
    }
    /// Play recent alerts on Live as short looping clips instead of still images.
    var playAlertPreviews: Bool = UserDefaults.standard.object(forKey: "playAlertPreviews") as? Bool ?? true {
        didSet { UserDefaults.standard.set(playAlertPreviews, forKey: "playAlertPreviews") }
    }
    /// Show the row of recent alerts at the top of Live.
    var showRecentAlerts: Bool = UserDefaults.standard.object(forKey: "showRecentAlerts") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showRecentAlerts, forKey: "showRecentAlerts") }
    }
    /// Whether the overview should show live video right now.
    var showsLiveGrid: Bool { liveGrid && (liveGridOnCellular || !NetworkStatus.shared.isExpensive) }

    /// Which stream live tiles play.
    enum TileStream: String, CaseIterable { case automatic, main, sub }
    var tileStream: TileStream = TileStream(rawValue: UserDefaults.standard.string(forKey: "tileStream") ?? "") ?? .automatic {
        didSet { UserDefaults.standard.set(tileStream.rawValue, forKey: "tileStream") }
    }

    /// Live video in the overview tiles, as one choice (stored in `liveGrid` and `autoLive`).
    enum TileLive: Hashable, CaseIterable { case always, onActivity, off }
    var tileLive: TileLive {
        get { liveGrid ? .always : (autoLive ? .onActivity : .off) }
        set {
            liveGrid = newValue == .always
            autoLive = newValue != .off
        }
    }
    /// Set to open the add-server sheet.
    var showAddServer = false
    /// Review items marked reviewed in this session. Frigate can take a moment before its
    /// review list reflects a change, so screens check this too.
    var reviewedIDs: Set<String> = []

    init() {
        if let data = UserDefaults.standard.data(forKey: "servers"),
           let saved = try? JSONDecoder().decode([ServerConfig].self, from: data) {
            servers = saved
        }
        if let data = UserDefaults.standard.data(forKey: "scope"),
           let s = try? JSONDecoder().decode(Scope.self, from: data) {
            scope = s
        }
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
        scopedConnections
    }

    var scopeTitle: String {
        switch scope {
        case .all: return L("All servers")
        case .server(let id): return connections[id]?.server.name ?? L("Server")
        }
    }

    var unreviewedAlerts: Int { reviewConnections.reduce(0) { $0 + $1.unreviewedAlerts } }

    func connection(for id: UUID) -> ServerConnection? { connections[id] }

    /// Online servers with Frigate's GenAI chat.
    var chatConnections: [ServerConnection] {
        scopedConnections.filter { $0.isOnline && $0.config?.supportsChat == true }
    }

    private var chatSessions: [UUID: ChatSession] = [:]
    /// Server picked in the Chat tab while showing all servers.
    var chatServerID: UUID?

    /// The conversation for a server, kept while switching tabs.
    func chatSession(for id: UUID) -> ChatSession {
        if let s = chatSessions[id] { return s }
        let s = ChatSession()
        chatSessions[id] = s
        return s
    }

    func connectAll() async {
        await withTaskGroup(of: Void.self) { group in
            for c in orderedConnections { group.addTask { await c.connect() } }
        }
    }

    private var networkTask: Task<Void, Never>?

    /// The network changed (Wi-Fi to mobile data, another Wi-Fi network): servers with a
    /// remote address pick the home or the remote one again, offline servers retry.
    func networkChanged() {
        networkTask?.cancel()
        networkTask = Task {
            // A change arrives in several steps; act once it has settled.
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await withTaskGroup(of: Void.self) { group in
                for c in orderedConnections where !(c.server.remoteURL ?? "").isEmpty || !c.isOnline {
                    group.addTask { @MainActor in await c.connect() }
                }
            }
        }
    }

    /// `reloadConfig` for user-started refreshes (pull to refresh, returning to the app).
    func refreshAll(reloadConfig: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for c in orderedConnections {
                group.addTask { @MainActor in
                    if c.client == nil || !c.isOnline { await c.connect() } else { await c.refresh(reloadConfig: reloadConfig) }
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

    /// Reorders servers; the order is used in every tab.
    func moveServers(from source: IndexSet, to destination: Int) {
        servers.move(fromOffsets: source, toOffset: destination)
    }

    func delete(_ server: ServerConfig) {
        server.password = nil
        servers.removeAll { $0.id == server.id }
        connections[server.id] = nil
        if scope == .server(server.id) { scope = .all }
    }
}
