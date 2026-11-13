import AVFoundation
import SwiftUI

struct CameraView: View {
    let route: CameraRoute
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var overlayVisible = true
    @State private var overlayToken = 0
    /// A menu in the overlay is open; the overlay must not hide underneath it.
    @State private var menuOpen = false
    @State private var player = LivePlayerState()
    /// The camera has a speaker go2rtc can send audio to.
    @State private var canTalk = false
    @State private var micDenied = false
    @State private var reviews: [ReviewItem] = []
    @State private var loadingReviews = true
    @State private var share: ShareItem?
    @State private var fullscreen = false
    /// iPad and Mac: the video fills the window. The same player keeps playing (the stream
    /// is not opened again); only the things around it step aside.
    @State private var filling = false
    @State private var showPTZ = false
    /// PTZ pads drawn on the video in landscape (a sheet would cover the picture).
    @State private var landscapePTZ = false
    @State private var snapshotBusy = false
    /// nil until checked; true when a recording segment was written recently.
    @State private var recordingNow: Bool?
    @State private var errorMessage: String?

    private var conn: ServerConnection? { model.connection(for: route.serverID) }
    private var camera: CameraConfig? { conn?.config?.cameras[route.camera] }
    /// Streams to choose from; empty when the camera has no go2rtc restream.
    private var streams: [(title: String, name: String)] {
        guard let conn, let camera else { return [] }
        return conn.liveStreams(camera)
    }
    private var streamKey: String { "liveStream.\(route.serverID.uuidString).\(route.camera)" }
    /// The stream picked in a menu, remembered per camera.
    private var streamChoice: Binding<String> {
        Binding(get: { player.stream }, set: {
            player.stream = $0
            UserDefaults.standard.set($0, forKey: streamKey)
        })
    }

    /// iPhone held sideways: full-screen live video with an overlay that hides itself.
    /// The full-screen landscape layout is for phones; wide screens get `wideBody`.
    private var isLandscape: Bool { verticalSizeClass == .compact && horizontalSizeClass != .regular }
    /// iPad full screen and the Mac: video and today's events side by side.
    private var isWide: Bool { horizontalSizeClass == .regular }

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
            if let client = conn?.client { PTZSheet(client: client, camera: route.camera)
                .presentationDetents([.height(320)])
                // Keep the video undimmed and usable while steering the camera.
                .presentationBackgroundInteraction(.enabled)
                .presentationDragIndicator(.visible) }
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        // Again once the server is connected: opened from a link at launch, it is not yet.
        .task(id: conn?.client == nil) { await loadReviews() }
        .task { await watchRecording() }
        .onDisappear {
            player.suspended = true; player.talking = false
            if filling { filling = false; model.immersive = false }
        }
        .task(id: player.stream) {
            guard let client = conn?.client else { return }
            let stream = player.stream.isEmpty ? route.camera : player.stream
            canTalk = await client.supportsTwoWayAudio(stream: stream)
            if !canTalk { player.talking = false }
        }
        .alert("Microphone not available", isPresented: $micDenied) {
            Button("Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Allow Tender to use the microphone in Settings to talk through the camera.")
        }
        .onChange(of: player.micError) { _, err in
            if err != nil { player.talking = false; player.micError = nil; micDenied = true }
        }
        .onChange(of: scenePhase) { _, phase in
            // Stop in the background, start fresh when the app is back.
            player.suspended = phase != .active
        }
        .onAppear {
            player.suspended = false
            // Sound as the user last left it on a camera (the overview always stays silent).
            if UserDefaults.standard.bool(forKey: LivePlayerState.soundKey) && player.muted { player.setMuted(false) }
            if player.stream.isEmpty {
                let streams = self.streams
                if streams.isEmpty && conn?.go2rtcStreams != nil {
                    // No restream to play: go straight to snapshots instead of waiting for
                    // MSE and WebRTC to time out.
                    player.preferred = .mjpeg
                }
                if let saved = UserDefaults.standard.string(forKey: streamKey), streams.contains(where: { $0.name == saved }) {
                    player.stream = saved
                } else {
                    // On mobile data start with the lighter sub stream when the camera has one.
                    let preferred = NetworkStatus.shared.isExpensive && streams.count > 1 ? streams.last : streams.first
                    player.stream = preferred?.name ?? route.camera
                }
            }
        }
    }

    private var portraitBody: some View {
        VStack(spacing: 0) {
            if !filling { header }
            if let conn, let client = conn.client, let camera {
                Group {
                    if isWide {
                        // Video as large as the window allows with today's events in a row
                        // under it; the controls float over the video.
                        GeometryReader { geo in
                            VStack(spacing: 0) {
                                playerView(client: client, camera: camera)
                                    .clipShape(RoundedRectangle(cornerRadius: filling ? 0 : 12))
                                    .overlay(alignment: .bottom) {
                                        if showOverlayControls {
                                            overlayControls(client: client, camera: camera)
                                                .transition(.opacity)
                                        }
                                    }
                                    // With a mouse the controls show while the pointer moves over the video.
                                    .onContinuousHover { phase in
                                        guard case .active = phase else { return }
                                        if !overlayVisible { withAnimation(.easeOut(duration: 0.15)) { overlayVisible = true } }
                                        keepOverlay()
                                    }
                                    .animation(.easeOut(duration: 0.2), value: showOverlayControls)
                                    // Exactly the picture's size: as wide as fits, never so tall
                                    // that today's row drops out of the window.
                                    .frame(width: videoHeight(geo.size, camera) * videoAspect(camera),
                                           height: videoHeight(geo.size, camera))
                                    .frame(maxWidth: .infinity)
                                if !filling { today(conn: conn) }
                                Spacer(minLength: 0)
                            }
                            .padding(.top, filling ? 0 : 4)
                            .frame(maxHeight: .infinity, alignment: filling ? .center : .top)
                        }
                        .background(filling ? Color.black.ignoresSafeArea() : nil)
                        .background {
                            if filling {
                                Button("") { setFilling(false) }.keyboardShortcut(.cancelAction).opacity(0)
                            }
                        }
                        // The controls hide after 4 seconds without use, as in playback.
                        .task(id: overlayToken) {
                            try? await Task.sleep(for: .seconds(4))
                            guard !Task.isCancelled, !player.talking, !showPTZ else { return }
                            if MenuPresence.isShowing { overlayToken += 1; return }
                            withAnimation(.easeOut(duration: 0.25)) { overlayVisible = false }
                        }
                    } else {
                        ScrollView {
                            VStack(spacing: 0) {
                                playerView(client: client, camera: camera)
                                controls(client: client, camera: camera)
                                today(conn: conn)
                            }
                            .padding(.bottom, 24)
                        }
                    }
                }
                .fullScreenCover(isPresented: $fullscreen) {
                    FullscreenLiveView(client: client, camera: camera, stream: player.stream, muted: player.muted)
                }
                // Sound changed in full screen: follow it here too.
                .onChange(of: fullscreen) { _, open in
                    guard !open else { return }
                    let sound = UserDefaults.standard.bool(forKey: LivePlayerState.soundKey)
                    if sound == player.muted { player.setMuted(!sound) }
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
                BackButtonLabel()
            }
            .accessibilityLabel("Back")
            Spacer()
            VStack(spacing: 2) {
                Text(camera?.displayName ?? FrigateFormat.prettyName(route.camera))
                    .font(.system(size: 17, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            moreMenu
        }
        .headerBarPadding()
        .padding(.bottom, 8)
    }

    private var moreMenu: some View {
            Menu {
                // The stream is picked on the video itself (streamChip).
                Picker("Playback", selection: $player.preferred) {
                    Text("Automatic").tag(LivePlayerState.Mode.auto)
                    Text("MSE").tag(LivePlayerState.Mode.mse)
                    Text("WebRTC").tag(LivePlayerState.Mode.webrtc)
                    Text("MJPEG").tag(LivePlayerState.Mode.mjpeg)
                }
                Button { player.reloadToken += 1 } label: { Label("Reload stream", systemImage: "arrow.clockwise") }
            } label: {
                HeaderIconLabel(systemName: "ellipsis")
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
                // Wide screens: a tap shows or hides the controls over the video, as in playback.
                .onTapGesture { if isWide { toggleOverlay() } }
            if !player.playing { LivePoster(client: client, camera: camera.name).allowsHitTesting(false) }
            streamStatus
        }
        .aspectRatio(player.videoSize.width > 0 ? player.videoSize.width / player.videoSize.height : camera.aspectRatio, contentMode: .fit)
        // Wide: the video fits the height too, so its overlays must hug the picture.
        .frame(maxWidth: isWide ? nil : .infinity)
        // Time top left, like the playback screens.
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                clock(size: 12)
                recBadge
                // Objects being tracked, like the label beside the time in playback.
                ForEach(conn?.activeObjects[camera.name] ?? [], id: \.self) { LabelIcon(label: $0, size: VideoChip.height) }
            }
            .padding(10)
        }
        .overlay(alignment: .bottomTrailing) { streamChip.padding(8) }

    }

    @ViewBuilder
    private var streamStatus: some View {
            if !player.playing {
                if player.status.hasPrefix("Stream unavailable") {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.title2)
                        Text(player.statusText).font(.system(size: 13)).multilineTextAlignment(.center)
                        Button("Retry") { player.reloadToken += 1 }.font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    .padding()
                } else {
                    // Small, so the refreshing picture underneath stays in view: at the bottom on
                    // the phone; top right on wide screens, where the controls take the bottom.
                    HStack(spacing: 6) {
                        ProgressView().tint(.white).controlSize(.mini)
                        Text(player.statusText).font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).frame(height: VideoChip.height)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isWide ? .topTrailing : .bottom)
                    .padding(isWide ? 10 : 0)
                    .padding(.bottom, isWide ? 0 : 10)
                    .allowsHitTesting(false)
                }
            }
    }

    /// Which stream plays, as a menu on the video; only when there is a choice.
    @ViewBuilder
    private var streamChip: some View {
        if streams.count > 1 {
            Menu {
                // Plain buttons: a Picker in a Menu becomes a "Stream ›" submenu on the Mac.
                ForEach(streams, id: \.name) { s in
                    Button { streamChoice.wrappedValue = s.name } label: {
                        if s.name == player.stream { Label(s.title, systemImage: "checkmark") } else { Text(s.title) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 11, weight: .semibold))
                    Text(streams.first { $0.name == player.stream }?.title ?? player.stream)
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(.black.opacity(0.6), in: Capsule())
            }
            .accessibilityLabel("Stream")
        }
    }

    @ViewBuilder
    private var recBadge: some View {
            // Recording shows as a red dot in the clock; only a stopped recording gets a badge.
            if recordingNow == false {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                    Text("Not recording")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.onLabel)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.warning, in: RoundedRectangle(cornerRadius: 6))
            }
    }

    /// The running clock, with a red dot while the camera is recording.
    private func clock(size: CGFloat) -> some View {
        HStack(spacing: 5) {
            if recordingNow == true {
                StatusDot(color: Theme.recording, size: size * 0.55).accessibilityLabel("Recording")
            }
            ClockLabel()
        }
        .font(.system(size: size, weight: .semibold).monospacedDigit())
        // Same look as the time label in playback.
        .padding(.horizontal, 8).frame(height: VideoChip.height)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Landscape

    private func landscapeBody(conn: ServerConnection, client: FrigateClient, camera: CameraConfig) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LivePlayerView(client: client, camera: camera.name, state: player)
                .zoomable()
                .ignoresSafeArea()
                .onTapGesture { toggleOverlay() }
            if !player.playing { LivePoster(client: client, camera: camera.name).ignoresSafeArea().allowsHitTesting(false) }
            streamStatus
            if landscapePTZ {
                PTZControls(client: client, camera: camera.name, overlay: true)
                    .padding(.leading, 24)
                    .padding(.bottom, 64)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .transition(.opacity)
                    .simultaneousGesture(TapGesture().onEnded { keepOverlay() })
            }
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
                        streamChip.simultaneousGesture(TapGesture().onEnded { menuOpen = true; keepOverlay() })
                        clock(size: 13)
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
                                toggleSound(); keepOverlay()
                            }
                            OverlayButton(systemImage: "camera.fill", label: "Snapshot") {
                                Task { await snapshot(client: client, camera: camera) }; keepOverlay()
                            }
                            if canTalk {
                                OverlayButton(systemImage: player.talking ? "mic.fill" : "mic", label: "Talk") {
                                    Task { await toggleTalk() }; keepOverlay()
                                }
                                .overlay(Circle().stroke(player.talking ? Theme.accent : .clear, lineWidth: 2))
                            }
                            if camera.hasOnvif {
                                OverlayButton(systemImage: landscapePTZ ? "xmark" : "arrow.up.and.down.and.arrow.left.and.right",
                                              label: "PTZ") {
                                    withAnimation(.easeOut(duration: 0.2)) { landscapePTZ.toggle() }; keepOverlay()
                                }
                            }
                        }
                        .padding(.trailing, 12)
                    }
                    .frame(maxHeight: .infinity)

                    HStack(spacing: 8) {
                        let objects = conn.activeObjects[camera.name] ?? []
                        ForEach(objects, id: \.self) { LabelIcon(label: $0, size: 22) }
                        Spacer()
                        Button {
                            model.tab = .explore
                            model.explorePath = NavigationPath()
                            model.explorePath.append(PlaybackRoute(serverID: route.serverID, camera: route.camera,
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
            guard !Task.isCancelled, !showPTZ, !landscapePTZ else { return }
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
                toggleSound()
            }
            controlButton(player.talking ? "mic.fill" : "mic", "Talk", active: player.talking, enabled: canTalk) {
                Task { await toggleTalk() }
            }
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

    private func videoAspect(_ camera: CameraConfig) -> CGFloat {
        player.videoSize.width > 0 ? player.videoSize.width / player.videoSize.height : camera.aspectRatio
    }

    private func videoHeight(_ size: CGSize, _ camera: CameraConfig) -> CGFloat {
        if filling { return min(size.width / videoAspect(camera), size.height) }
        return max(160, min((size.width - 32) / videoAspect(camera), size.height - Self.wideStripHeight))
    }

    private func setFilling(_ on: Bool) {
        withAnimation(.easeOut(duration: 0.2)) { filling = on; model.immersive = on }
        keepOverlay()
    }

    /// Height under the video on wide screens: today's row of events.
    static let wideStripHeight: CGFloat = 196

    /// Over the video on wide screens; shown and hidden like the playback controls.
    private var showOverlayControls: Bool { overlayVisible || player.talking }

    private func overlayControls(client: FrigateClient, camera: CameraConfig) -> some View {
        HStack(spacing: 16) {
            overlayButton(player.muted ? "speaker.slash" : "speaker.wave.2", "Audio", active: !player.muted,
                          enabled: player.hasAudio || player.activeMode != "mjpeg") { toggleSound() }
            if canTalk {
                overlayButton(player.talking ? "mic.fill" : "mic", "Talk", active: player.talking) { Task { await toggleTalk() } }
            }
            overlayButton("camera", "Snapshot", busy: snapshotBusy) { Task { await snapshot(client: client, camera: camera) } }
            if camera.hasOnvif {
                overlayButton("arrow.up.and.down.and.arrow.left.and.right", "PTZ") { showPTZ = true }
            }
            overlayButton(filling ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                          filling ? "Exit full screen" : "Fullscreen") { setFilling(!filling) }
        }
        .padding(16)
    }

    private func overlayButton(_ icon: String, _ label: LocalizedStringKey, active: Bool = false, enabled: Bool = true,
                               busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // The same round buttons as OverlayButton in playback, with an on state.
            ZStack {
                Circle().fill(active ? Theme.accent : .black.opacity(0.6))
                if busy { ProgressView().tint(.white) } else {
                    Image(systemName: icon).font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(active ? Theme.onColor : .white)
                }
            }
            .frame(width: 56, height: 56)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
        .help(Text(label))
        .accessibilityLabel(label)
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

    /// Turns the sound on or off and remembers it for the next camera opened.
    private func toggleSound() {
        player.setMuted(!player.muted)
        UserDefaults.standard.set(!player.muted, forKey: LivePlayerState.soundKey)
    }

    /// Starts or stops talking through the camera's speaker.
    private func toggleTalk() async {
        if player.talking {
            player.talking = false
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            micDenied = true
            return
        }
        player.talking = true
        // Hear the other side while talking.
        if player.muted { player.setMuted(false) }
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

    /// `vertical`: a list beside the video (wide layout) instead of a row under it.
    private func today(conn: ServerConnection, vertical: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Today").font(.system(size: 20, weight: .bold))
                Spacer()
                NavigationLink(value: PlaybackRoute(serverID: route.serverID, camera: route.camera, day: Calendar.current.startOfDay(for: Date()))) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 14, weight: .semibold))
                        Text("Playback").font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(Theme.onColor)
                    .padding(.horizontal, 14).frame(height: 36)
                    .background(Theme.accent, in: Capsule())
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            if loadingReviews && reviews.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            } else if reviews.isEmpty {
                Text("No activity today").font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else if vertical {
                LazyVStack(spacing: 8) {
                    ForEach(reviews) { r in
                        NavigationLink(value: EventRoute(serverID: route.serverID, review: r)) {
                            HStack(spacing: 10) {
                                RemoteImage(url: conn.client?.thumbnailURL(for: r), session: conn.client?.session ?? .shared)
                                    .frame(width: 96, height: 58)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 4) { ForEach(r.labels, id: \.self) { LabelIcon(label: $0, size: 18) } }
                                    Text(FrigateFormat.time(r.start, seconds: true)).font(.system(size: 14, weight: .semibold))
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(8)
                            .card(radius: 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(reviews) { r in
                            NavigationLink(value: EventRoute(serverID: route.serverID, review: r)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    RemoteImage(url: conn.client?.thumbnailURL(for: r), session: conn.client?.session ?? .shared)
                                        .frame(width: isWide ? 168 : 132, height: isWide ? 95 : 80)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cardBorder, lineWidth: 1))
                                        .overlay(alignment: .bottomLeading) {
                                            HStack(spacing: 3) { ForEach(r.labels.prefix(3), id: \.self) { LabelIcon(label: $0, size: 16) } }.padding(6)
                                        }
                                    Text(FrigateFormat.time(r.start)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                // Only as tall as the thumbnails: under the big video on wide screens the
                // row would otherwise take all the height that is left.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Beside the video (vertical) the column already has its margins; its top lines up
        // with the video.
        .padding(.horizontal, vertical ? 0 : 16)
        .padding(.top, vertical ? 0 : 14)
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
                LivePoster(client: client, camera: camera.name).ignoresSafeArea().allowsHitTesting(false)
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
                              label: state.muted ? "Unmute" : "Mute") {
                state.setMuted(!state.muted)
                UserDefaults.standard.set(!state.muted, forKey: LivePlayerState.soundKey)
            }
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

    var body: some View {
        PTZControls(client: client, camera: camera, overlay: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.card)
    }
}

/// Pan, tilt and zoom pads for a camera. Shows only what the camera supports (from
/// /api/<camera>/ptz/info) plus its presets. `overlay` is the compact style drawn on top of
/// the video in landscape.
struct PTZControls: View {
    let client: FrigateClient
    let camera: String
    var overlay: Bool
    @State private var socket: URLSessionWebSocketTask?
    @State private var info: PTZInfo?

    struct PTZInfo: Decodable {
        var features: [String]?
        var presets: [String]?
    }

    // Unknown capabilities: show everything.
    private var canMove: Bool { info?.features.map { $0.contains("pt") } ?? true }
    private var canZoom: Bool { info?.features.map { $0.contains("zoom") } ?? true }
    private var presets: [String] { info?.presets ?? [] }
    private var size: CGFloat { overlay ? 46 : 56 }

    var body: some View {
        VStack(spacing: overlay ? 10 : 16) {
            if !overlay {
                Text(canMove ? "Pan, tilt and zoom" : "Zoom").font(.headline).padding(.top, 20)
            }
            HStack(alignment: .center, spacing: overlay ? 20 : 36) {
                if canMove {
                    VStack(spacing: overlay ? 4 : 8) {
                        pad("chevron.up", "MOVE_UP")
                        HStack(spacing: overlay ? 4 : 8) {
                            pad("chevron.left", "MOVE_LEFT")
                            Color.clear.frame(width: size, height: size)
                            pad("chevron.right", "MOVE_RIGHT")
                        }
                        pad("chevron.down", "MOVE_DOWN")
                    }
                }
                if canZoom {
                    VStack(spacing: 8) {
                        pad("plus.magnifyingglass", "ZOOM_IN")
                        pad("minus.magnifyingglass", "ZOOM_OUT")
                    }
                }
            }
            if !presets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(presets, id: \.self) { preset in
                            Button { send("preset_\(preset)") } label: {
                                Chip(title: preset.capitalizedFirst, systemImage: "scope")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, overlay ? 0 : 16)
                }
                .frame(maxWidth: overlay ? 320 : .infinity)
            }
        }
        .task {
            if let i = try? await client.get(PTZInfo.self, "api/\(camera)/ptz/info"), i.features != nil { info = i }
        }
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
            .font(.system(size: overlay ? 18 : 20, weight: .semibold))
            .foregroundStyle(overlay ? .white : Theme.text)
            .frame(width: size, height: size)
            .background(overlay ? AnyShapeStyle(.black.opacity(0.55)) : AnyShapeStyle(Theme.control), in: Circle())
            .overlay(Circle().stroke(overlay ? Color.white.opacity(0.15) : Theme.controlBorder, lineWidth: 1))
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 40, pressing: { down in
                send(down ? command : "STOP")
            }, perform: {})
            .accessibilityLabel(command.replacingOccurrences(of: "_", with: " ").lowercased())
    }
}
