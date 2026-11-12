import SwiftUI

struct LiveView: View {
    @Environment(AppModel.self) private var model
    @State private var group: String? = nil

    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Two columns on iPhone; on iPad and Mac as many as fit at a comfortable size.
    private var columns: [GridItem] {
        sizeClass == .regular
            ? [GridItem(.adaptive(minimum: 250, maximum: 480), spacing: 12)]
            : [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.livePath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if !groupNames.isEmpty { groupChips }
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .refreshable { await model.refreshAll() }
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
        LargeTitle(text: L("Live"))
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
        }
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

    var body: some View {
        let online = conn.isCameraOnline(camera.name)
        let objects = conn.activeObjects[camera.name] ?? []
        let activity = online ? conn.activity[camera.name] : nil
        let tracking = !(activity?.tracking.isEmpty ?? true)
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay {
                        ZStack {
                            RemoteImage(url: conn.client?.latestImageURL(camera: camera.name, height: 270),
                                        session: conn.client?.session ?? .shared,
                                        refresh: online ? (objects.isEmpty ? 6 : 2) * (NetworkStatus.shared.isExpensive ? 2.5 : 1) : nil)
                            if online && model.showsLiveGrid, let client = conn.client {
                                TileLivePlayer(client: client, camera: camera)
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
    @State private var state = LivePlayerState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        LivePlayerView(client: client, camera: camera.name, state: state, fill: true)
            .opacity(state.playing ? 1 : 0)
            .allowsHitTesting(false)
            .onAppear {
                // Sub stream when the camera has one, without the snapshot fallback.
                state.stream = camera.streams.count > 1 ? (camera.streams.last?.name ?? camera.name) : camera.name
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
