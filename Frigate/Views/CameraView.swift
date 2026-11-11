import SwiftUI

struct CameraView: View {
    let route: CameraRoute
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var overlayVisible = true
    @State private var overlayToken = 0
    /// A menu in the overlay is open; the overlay must not hide underneath it.
    @State private var menuOpen = false
    @State private var player = LivePlayerState()
    @State private var reviews: [ReviewItem] = []
    @State private var loadingReviews = true
    @State private var share: ShareItem?
    @State private var fullscreen = false
    @State private var showPTZ = false
    @State private var snapshotBusy = false
    /// nil until checked; true when a recording segment was written recently.
    @State private var recordingNow: Bool?
    @State private var errorMessage: String?

    private var conn: ServerConnection? { model.connection(for: route.serverID) }
    private var camera: CameraConfig? { conn?.config?.cameras[route.camera] }

    /// iPhone held sideways: full-screen live video with an overlay that hides itself.
    private var isLandscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        Group {
            if isLandscape, let conn, let client = conn.client, let camera {
                landscapeBody(conn: conn, client: client, camera: camera)
            } else {
                portraitBody
            }
        }
        .sheet(item: $share) { ShareSheet(items: $0.items) }
        .sheet(isPresented: $showPTZ) {
            if let client = conn?.client { PTZSheet(client: client, camera: route.camera).presentationDetents([.height(320)]) }
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .task { await loadReviews() }
        .task { await watchRecording() }
        .onDisappear { player.suspended = true }
        .onChange(of: scenePhase) { _, phase in
            // Stop in the background, start fresh when the app is back.
            player.suspended = phase != .active
        }
        .onAppear {
            player.suspended = false
            if player.stream.isEmpty {
                // On mobile data start with the lighter sub stream when the camera has one.
                let streams = camera?.streams ?? []
                let preferred = NetworkStatus.shared.isExpensive && streams.count > 1 ? streams.last : streams.first
                player.stream = preferred?.name ?? route.camera
            }
        }
    }

    private var portraitBody: some View {
        VStack(spacing: 0) {
            header
            if let conn, let client = conn.client, let camera {
                ScrollView {
                    VStack(spacing: 0) {
                        playerView(client: client, camera: camera)
                        controls(client: client, camera: camera)
                        today(conn: conn)
                    }
                    .padding(.bottom, 24)
                }
                .fullScreenCover(isPresented: $fullscreen) {
                    FullscreenLiveView(client: client, camera: camera, stream: player.stream, muted: player.muted)
                }
            } else {
                Spacer()
                EmptyStateView(systemImage: "video.slash", title: L("Camera unavailable"), message: L("The server is offline or the camera was removed."))
                Spacer()
            }
        }
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Back")
            Spacer()
            VStack(spacing: 2) {
                Text(camera?.displayName ?? FrigateFormat.prettyName(route.camera))
                    .font(.system(size: 17, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            moreMenu
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private var moreMenu: some View {
            Menu {
                if let camera, camera.streams.count > 1 {
                    Picker("Stream", selection: $player.stream) {
                        ForEach(camera.streams, id: \.name) { s in Text(s.title).tag(s.name) }
                    }
                }
                Picker("Playback", selection: $player.preferred) {
                    Text("Automatic").tag(LivePlayerState.Mode.auto)
                    Text("MSE").tag(LivePlayerState.Mode.mse)
                    Text("WebRTC").tag(LivePlayerState.Mode.webrtc)
                    Text("MJPEG").tag(LivePlayerState.Mode.mjpeg)
                }
                Button { player.reloadToken += 1 } label: { Label("Reload stream", systemImage: "arrow.clockwise") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("More options")
    }

    private var subtitle: String {
        var parts = [conn?.server.name ?? ""]
        if player.videoSize.width > 0 {
            parts.append("\(Int(player.videoSize.width)) × \(Int(player.videoSize.height))")
        }
        if !player.activeMode.isEmpty { parts.append(player.activeMode == "webrtc" ? "WebRTC" : player.activeMode.uppercased()) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Player

    private func playerView(client: FrigateClient, camera: CameraConfig) -> some View {
        ZStack {
            Color.black
            LivePlayerView(client: client, camera: camera.name, state: player)
                .zoomable()
            streamStatus
        }
        .aspectRatio(player.videoSize.width > 0 ? player.videoSize.width / player.videoSize.height : camera.aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topLeading) { recBadge.padding(10) }
        .overlay(alignment: .topTrailing) {
            ClockLabel()
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .padding(10)
        }
        .overlay(alignment: .bottomLeading) {
            let objects = conn?.activeObjects[camera.name] ?? []
            if !objects.isEmpty {
                HStack(spacing: 4) { ForEach(objects, id: \.self) { LabelTag(label: $0) } }.padding(10)
            }
        }
    }

    @ViewBuilder
    private var streamStatus: some View {
            if !player.playing {
                VStack(spacing: 8) {
                    if player.status.hasPrefix("Stream unavailable") {
                        Image(systemName: "exclamationmark.triangle").font(.title2)
                    } else {
                        ProgressView().tint(.white)
                    }
                    Text(player.statusText).font(.system(size: 13)).multilineTextAlignment(.center)
                    if player.status.hasPrefix("Stream unavailable") {
                        Button("Retry") { player.reloadToken += 1 }.font(.system(size: 14, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .padding()
            }
    }

    @ViewBuilder
    private var recBadge: some View {
            if let recordingNow {
                HStack(spacing: 5) {
                    if recordingNow {
                        StatusDot(color: Theme.recording, size: 6)
                        Text("REC")
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                        Text("Not recording")
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(recordingNow ? Theme.text : Theme.onLabel)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(recordingNow ? Color.black.opacity(0.6) : Theme.warning, in: RoundedRectangle(cornerRadius: 6))
            }
    }

    // MARK: Landscape

    private func landscapeBody(conn: ServerConnection, client: FrigateClient, camera: CameraConfig) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LivePlayerView(client: client, camera: camera.name, state: player)
                .zoomable()
                .ignoresSafeArea()
                .onTapGesture { toggleOverlay() }
            streamStatus
            if overlayVisible {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Back")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(camera.displayName).font(.system(size: 17, weight: .semibold))
                            Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        recBadge
                        ClockLabel()
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.black.opacity(0.55), in: Capsule())
                        moreMenu.simultaneousGesture(TapGesture().onEnded { menuOpen = true; keepOverlay() })
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 8)
                    .background(Color.black.opacity(0.55).ignoresSafeArea(edges: [.top, .horizontal]))

                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            OverlayButton(systemImage: player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                          label: player.muted ? "Unmute" : "Mute") {
                                player.setMuted(!player.muted); keepOverlay()
                            }
                            OverlayButton(systemImage: "camera.fill", label: "Snapshot") {
                                Task { await snapshot(client: client, camera: camera) }; keepOverlay()
                            }
                            if camera.hasOnvif {
                                OverlayButton(systemImage: "arrow.up.and.down.and.arrow.left.and.right", label: "PTZ") { showPTZ = true }
                            }
                        }
                        .padding(.trailing, 12)
                    }
                    .frame(maxHeight: .infinity)

                    HStack(spacing: 8) {
                        let objects = conn.activeObjects[camera.name] ?? []
                        ForEach(objects, id: \.self) { LabelTag(label: $0) }
                        Spacer()
                        Button {
                            model.tab = .history
                            model.historyPath = NavigationPath()
                            model.historyPath.append(PlaybackRoute(serverID: route.serverID, camera: route.camera,
                                                                   day: Calendar.current.startOfDay(for: Date())))
                        } label: {
                            Label("Playback", systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(.black.opacity(0.55), in: Capsule())
                                .overlay(Capsule().stroke(Theme.accent, lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
                .transition(.opacity)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onChange(of: player.stream) { _, _ in menuOpen = false; keepOverlay() }
        .onChange(of: player.preferred) { _, _ in menuOpen = false; keepOverlay() }
        .onChange(of: player.reloadToken) { _, _ in menuOpen = false; keepOverlay() }
        .task(id: overlayToken) {
            // Hide the overlay after 4 seconds without touches.
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !showPTZ else { return }
            // Keep the overlay while one of its menus is open; check again later.
            if menuOpen || MenuPresence.isShowing { menuOpen = false; overlayToken += 1; return }
            withAnimation(.easeOut(duration: 0.25)) { overlayVisible = false }
        }
    }

    private func toggleOverlay() {
        menuOpen = false
        withAnimation(.easeOut(duration: 0.2)) { overlayVisible.toggle() }
        overlayToken += 1
    }

    private func keepOverlay() { overlayToken += 1 }

    // MARK: Controls

    private func controls(client: FrigateClient, camera: CameraConfig) -> some View {
        HStack(spacing: 0) {
            controlButton(player.muted ? "speaker.slash" : "speaker.wave.2", "Audio", active: !player.muted,
                          enabled: player.hasAudio || player.activeMode != "mjpeg") {
                player.setMuted(!player.muted)
            }
            controlButton("mic", "Talk", enabled: false) {}
            controlButton("camera", "Snapshot", busy: snapshotBusy) {
                Task { await snapshot(client: client, camera: camera) }
            }
            controlButton("arrow.up.and.down.and.arrow.left.and.right", "PTZ", enabled: camera.hasOnvif) {
                showPTZ = true
            }
            controlButton("arrow.up.left.and.arrow.down.right", "Fullscreen") { fullscreen = true }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func controlButton(_ icon: String, _ label: LocalizedStringKey, active: Bool = false, enabled: Bool = true,
                               busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(active ? Theme.accent : Theme.control)
                    Circle().stroke(Theme.controlBorder, lineWidth: 1)
                    if busy { ProgressView() } else {
                        Image(systemName: icon).font(.system(size: 19))
                            .foregroundStyle(active ? Theme.onColor : Theme.text)
                    }
                }
                .frame(width: 48, height: 48)
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
        .accessibilityLabel(label)
    }

    private func snapshot(client: FrigateClient, camera: CameraConfig) async {
        snapshotBusy = true
        defer { snapshotBusy = false }
        do {
            let data = try await client.data("api/\(camera.name)/latest.jpg")
            guard let img = UIImage(data: data) else { throw FrigateError.notFrigate }
            share = ShareItem(items: [img])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Today

    private func today(conn: ServerConnection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today").font(.system(size: 20, weight: .bold))
                Spacer()
                NavigationLink(value: PlaybackRoute(serverID: route.serverID, camera: route.camera, day: Calendar.current.startOfDay(for: Date()))) {
                    Text("Playback").font(.system(size: 15, weight: .medium)).frame(minHeight: 44)
                }
            }
            if loadingReviews && reviews.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            } else if reviews.isEmpty {
                Text("No activity today").font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(reviews) { r in
                            NavigationLink(value: EventRoute(serverID: route.serverID, review: r)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    RemoteImage(url: conn.client?.thumbnailURL(for: r), session: conn.client?.session ?? .shared)
                                        .frame(width: 132, height: 80)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cardBorder, lineWidth: 1))
                                        .overlay(alignment: .bottomLeading) {
                                            if let l = r.labels.first { LabelTag(label: l, size: 10).padding(6) }
                                        }
                                    Text(FrigateFormat.time(r.start)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    /// Shows REC only while Frigate is actually writing recordings for this camera.
    /// Segments land 5 to 20 seconds after the fact, so allow 45 seconds before warning,
    /// and need two misses in a row so a single slow write does not flip the badge.
    private func watchRecording() async {
        var misses = 0
        while !Task.isCancelled {
            if let client = conn?.client {
                let now = Date()
                if let segs = try? await client.recordings(camera: route.camera, after: now.addingTimeInterval(-120), before: now) {
                    let latest = segs.map(\.endTime).max() ?? 0
                    let fresh = now.timeIntervalSince1970 - latest < 45
                    misses = fresh ? 0 : misses + 1
                    if fresh { recordingNow = true }
                    else if misses >= 2 || recordingNow == nil {
                        // Recording switched off in Frigate: no badge rather than a warning.
                        recordingNow = camera?.record?.enabled == true ? false : nil
                    }
                }
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }

    private func loadReviews() async {
        guard let client = conn?.client else { loadingReviews = false; return }
        loadingReviews = true
        let start = Calendar.current.startOfDay(for: Date())
        reviews = (try? await client.reviews(cameras: [route.camera], after: start, limit: 50)) ?? []
        loadingReviews = false
    }
}

// MARK: - Fullscreen

struct FullscreenLiveView: View {
    let client: FrigateClient
    let camera: CameraConfig
    @State private var state = LivePlayerState()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    init(client: FrigateClient, camera: CameraConfig, stream: String, muted: Bool) {
        self.client = client
        self.camera = camera
        let s = LivePlayerState()
        s.stream = stream
        s.muted = muted
        _state = State(initialValue: s)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            LivePlayerView(client: client, camera: camera.name, state: state)
                .zoomable()
                .ignoresSafeArea()
                .onChange(of: scenePhase) { _, phase in state.suspended = phase != .active }
            if !state.playing {
                VStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text(state.statusText).font(.system(size: 13)).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                OverlayButton(systemImage: "xmark", size: 40, label: "Close") { dismiss() }
                Spacer()
                OverlayButton(systemImage: state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 40,
                              label: state.muted ? "Unmute" : "Mute") { state.setMuted(!state.muted) }
            }
            .padding(16)
        }
        .statusBarHidden()
    }
}

// MARK: - PTZ

struct PTZSheet: View {
    let client: FrigateClient
    let camera: String
    @State private var socket: URLSessionWebSocketTask?

    var body: some View {
        VStack(spacing: 16) {
            Text("Pan, tilt and zoom").font(.headline).padding(.top, 20)
            HStack(spacing: 36) {
                VStack(spacing: 8) {
                    pad("chevron.up", "MOVE_UP")
                    HStack(spacing: 8) {
                        pad("chevron.left", "MOVE_LEFT")
                        Color.clear.frame(width: 56, height: 56)
                        pad("chevron.right", "MOVE_RIGHT")
                    }
                    pad("chevron.down", "MOVE_DOWN")
                }
                VStack(spacing: 8) {
                    pad("plus.magnifyingglass", "ZOOM_IN")
                    pad("minus.magnifyingglass", "ZOOM_OUT")
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Theme.card)
        .onAppear {
            var comps = URLComponents(url: client.url("ws"), resolvingAgainstBaseURL: false)!
            comps.scheme = client.baseURL.scheme == "https" ? "wss" : "ws"
            let task = client.session.webSocketTask(with: comps.url!)
            task.resume()
            socket = task
        }
        .onDisappear { socket?.cancel(with: .goingAway, reason: nil) }
    }

    private func send(_ command: String) {
        let msg = #"{"topic":"\#(camera)/ptz","payload":"\#(command)","retain":false}"#
        socket?.send(.string(msg)) { _ in }
    }

    private func pad(_ icon: String, _ command: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 20, weight: .semibold))
            .frame(width: 56, height: 56)
            .background(Theme.control, in: Circle())
            .overlay(Circle().stroke(Theme.controlBorder, lineWidth: 1))
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 40, pressing: { down in
                send(down ? command : (command.hasPrefix("ZOOM") ? "STOP" : "STOP"))
            }, perform: {})
            .accessibilityLabel(command.replacingOccurrences(of: "_", with: " ").lowercased())
    }
}
