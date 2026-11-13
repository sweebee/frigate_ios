import SwiftUI

struct LiveView: View {
    @Environment(AppModel.self) private var model
    @State private var group: String? = nil

    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Bigger tiles: one column on iPhone, fewer and wider tiles on iPad.
    @AppStorage("liveLargeTiles") private var largeTiles = false
    /// Columns on wide screens; the choices fit the device (a Mac window has room for more).
    @AppStorage("liveWideColumns") private var storedColumns = 0
    private static let columnChoices: [Int] = ProcessInfo.processInfo.isMacCatalystApp ? [3, 4, 5, 6] : [2, 3, 4]
    private var wideColumns: Int {
        Self.columnChoices.contains(storedColumns) ? storedColumns : Self.columnChoices[1]
    }

    /// Two columns on iPhone (or one with large tiles); on iPad and Mac as many as fit.
    private var columns: [GridItem] {
        if sizeClass == .regular {
            return Array(repeating: GridItem(.flexible(), spacing: 12), count: wideColumns)
        }
        return largeTiles
            ? [GridItem(.flexible(), spacing: 10)]
            : [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.livePath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if model.showRecentAlerts { RecentAlertsStrip() }
                    if !groupNames.isEmpty { groupChips }
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .refreshable { await model.refreshAll(reloadConfig: true) }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .appDestinations()
            .task {
                // Keep object badges, status and counts fresh while the tab is visible.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    await model.refreshAll()
                }
            }
        }
    }

    private var header: some View {
        HStack {
            LargeTitle(text: L("Live"))
            Spacer()
            if sizeClass == .regular {
                // Wide screens: how many cameras side by side, as plain numbers so it says
                // exactly what you get.
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                    Picker("Columns", selection: Binding(get: { wideColumns }, set: { c in
                        withAnimation(.easeOut(duration: 0.2)) { storedColumns = c }
                    })) {
                        ForEach(Self.columnChoices, id: \.self) { n in Text("\(n)").tag(n) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: CGFloat(Self.columnChoices.count) * 40)
                }
            } else {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { largeTiles.toggle() }
                } label: {
                    Image(systemName: largeTiles ? "square.grid.2x2" : "rectangle.grid.1x2")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel(largeTiles ? "Small tiles" : "Large tiles")
            }
        }
        .padding(.top, 8)
    }

    /// Camera groups across the servers in scope, by name.
    private var groupNames: [String] {
        var names: [String] = []
        for conn in model.scopedConnections {
            for g in conn.config?.orderedGroups ?? [] where !names.contains(g.name) { names.append(g.name) }
        }
        return names
    }

    private var groupChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { group = nil } label: { Chip(title: L("All"), selected: group == nil) }
                ForEach(groupNames, id: \.self) { name in
                    Button { group = name } label: { Chip(title: FrigateFormat.prettyName(name), selected: group == name) }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
        .buttonStyle(.plain)
    }

    private func cameras(for conn: ServerConnection) -> [CameraConfig] {
        guard let group, let members = conn.config?.cameraGroups?[group]?.cameras else {
            return group == nil ? conn.cameras : []
        }
        return conn.cameras.filter { members.contains($0.name) }
    }

    @ViewBuilder
    private var content: some View {
        let conns = model.scopedConnections
        if conns.count == 1, let conn = conns.first {
            serverGrid(conn)
        } else {
            ForEach(conns) { conn in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ServerBadge(initial: conn.server.initial, tint: conn.server.tint, size: 20)
                        Text(conn.server.name.uppercased())
                            .font(.system(size: 13, weight: .bold)).kerning(0.4)
                            .foregroundStyle(Theme.textTertiary)
                        Text(conn.metaLine).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    .padding(.horizontal, 4)
                    serverGrid(conn)
                }
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private func serverGrid(_ conn: ServerConnection) -> some View {
        switch conn.status {
        case .connecting where conn.config == nil:
            HStack { Spacer(); ProgressView().padding(40); Spacer() }
        case .offline(let message) where conn.config == nil:
            VStack(alignment: .leading, spacing: 10) {
                Text("\(conn.server.name) is offline").font(.system(size: 15, weight: .semibold))
                Text(message).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                Button("Try again") { Task { await conn.connect() } }
                    .font(.system(size: 14, weight: .semibold))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.controlBorder, style: StrokeStyle(lineWidth: 1, dash: [4])))
        default:
            let cams = cameras(for: conn)
            if cams.isEmpty {
                EmptyStateView(systemImage: "video.slash", title: L("No cameras"), message: group == nil ? nil : L("This group has no cameras on \(conn.server.name)."))
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(cams, id: \.name) { cam in
                        NavigationLink(value: CameraRoute(serverID: conn.server.id, camera: cam.name)) {
                            CameraTile(conn: conn, camera: cam)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct CameraTile: View {
    let conn: ServerConnection
    let camera: CameraConfig
    @Environment(AppModel.self) private var model
    @State private var autoLiveOn = false

    var body: some View {
        let online = conn.isCameraOnline(camera.name)
        let objects = conn.activeObjects[camera.name] ?? []
        let activity = online ? conn.activity[camera.name] : nil
        let tracking = !(activity?.tracking.isEmpty ?? true)
        let active = activity?.motion == true || tracking
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay {
                        ZStack {
                            RemoteImage(url: conn.client?.latestImageURL(camera: camera.name, height: 270),
                                        session: conn.client?.session ?? .shared,
                                        refresh: online ? (objects.isEmpty ? 6 : 2) * (NetworkStatus.shared.isExpensive ? 2.5 : 1) : nil)
                            if online && (model.showsLiveGrid || (model.autoLive && autoLiveOn)), let client = conn.client,
                               let sub = conn.liveStreams(camera).last {
                                TileLivePlayer(client: client, camera: camera, stream: sub.name)
                            }
                        }
                    }
                    .clipped()
                    .opacity(online ? 1 : 0.4)

                // Only flag cameras that are down; online is the normal state.
                if !online {
                    HStack(spacing: 5) {
                        StatusDot(color: Theme.offline, size: 6)
                        Text("OFFLINE")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !objects.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(objects.prefix(3), id: \.self) { LabelIcon(label: $0) }
                    }
                    .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if activity?.motion == true { MotionDot().padding(8) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(tracking ? Theme.recording : Theme.cardBorder, lineWidth: tracking ? 1.5 : 1))
            .animation(.easeOut(duration: 0.2), value: tracking)

            HStack(alignment: .firstTextBaseline) {
                Text(camera.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(meta(online: online))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        // Automatic live view: go live on activity and stay live a little after it ends.
        .task(id: active) {
            if active {
                autoLiveOn = true
            } else if autoLiveOn {
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled { autoLiveOn = false }
            }
        }
    }

    private func meta(online: Bool) -> String {
        if !online { return L("Offline") }
        if !conn.isDetectEnabled(camera) { return L("Detect off") }
        if !(conn.activeObjects[camera.name] ?? []).isEmpty { return L("Now") }
        if let last = conn.lastActivity[camera.name] { return FrigateFormat.relative(last) }
        return ""
    }
}

/// Muted live video of a camera's lowest-resolution stream for the overview grid.
/// The snapshot underneath stays visible until the video plays.
struct TileLivePlayer: View {
    let client: FrigateClient
    let camera: CameraConfig
    /// The lightest stream the camera has.
    let stream: String
    @State private var state = LivePlayerState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        LivePlayerView(client: client, camera: camera.name, state: state, fill: true)
            .opacity(state.playing ? 1 : 0)
            .allowsHitTesting(false)
            .onAppear {
                // Without the snapshot fallback: the snapshot underneath already shows.
                state.stream = stream
                state.preferred = .mse
                state.suspended = false
            }
            .onDisappear { state.suspended = true }
            .onChange(of: scenePhase) { _, phase in state.suspended = phase != .active }
    }
}

/// Pulsing red dot shown while Frigate sees motion, like the web UI.
struct MotionDot: View {
    @State private var dim = false
    var body: some View {
        Circle()
            .fill(Theme.recording)
            .frame(width: 6, height: 6)
            .shadow(color: Theme.recording.opacity(0.8), radius: 2)
            .opacity(dim ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
            .accessibilityLabel("Motion")
    }
}
