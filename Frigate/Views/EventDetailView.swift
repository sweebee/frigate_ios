import SwiftUI

struct EventDetailView: View {
    let route: EventRoute
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var item: ReviewItem
    @State private var player = RecordingPlayer()
    @State private var events: [FrigateEvent] = []
    @State private var timeline: [TimelineEntry] = []
    @State private var share: ShareItem?
    @State private var downloading = false
    @State private var confirmDelete = false
    @State private var exporter = ClipExporter()
    @State private var errorMessage: String?
    /// Frigate kept no recording for this item (e.g. retention expired or the camera was down).
    @State private var noRecording = false
    /// Landscape: the controls drawn over the video; they hide by themselves during playback.
    @State private var overlayVisible = true
    @State private var overlayToken = 0
    /// The pointer rests on the controls over the video: keep them.
    @State private var pointerOnControls = false
    /// iPad and Mac: the video fills the window with the landscape controls; same player.
    @State private var fullscreen = false
    /// The tracked object whose snapshot is shown large.
    @State private var snapshotEvent: FrigateEvent?

    /// Seconds of recording shown before and after the review item.
    private let padding: Double = 5

    init(route: EventRoute) {
        self.route = route
        _item = State(initialValue: route.review)
    }

    private var conn: ServerConnection? { model.connection(for: route.serverID) }
    private var isReviewed: Bool { item.hasBeenReviewed || model.reviewedIDs.contains(item.id) }
    private var client: FrigateClient? { conn?.client }
    /// When something was actually happening: the review item widened to how long its objects
    /// were tracked (Frigate often closes the review item sooner). Odd event times are capped.
    /// Frigate's annotation offset for this camera, so detections line up with the recording.
    private var offset: Double { conn?.config?.cameras[item.camera]?.annotationOffset ?? 0 }

    private var activityStart: Double {
        let eventStart = events.map(\.startTime).min() ?? item.startTime
        return max(min(item.startTime, eventStart), item.startTime - 30) + offset
    }
    private var activityEnd: Double {
        let now = Date().timeIntervalSince1970
        let itemEnd = item.endTime ?? now
        let eventEnd = events.map { $0.endTime ?? now }.filter { $0 > item.startTime }.max() ?? itemEnd
        // Cap at 10 minutes: a review item left open by Frigate can span days.
        return min(max(itemEnd, eventEnd), itemEnd + 60, now, item.startTime + 600) + offset
    }
    /// Whole seconds, as the /vod endpoint uses, so the event range lines up with the video.
    private var clipStart: Double { (activityStart - padding).rounded(.down) }
    private var clipEnd: Double { min(activityEnd + padding, Date().timeIntervalSince1970) }

    private var isLandscape: Bool { verticalSizeClass == .compact && horizontalSizeClass != .regular }

    var body: some View {
        Group {
            if isLandscape || fullscreen { landscapeBody.transition(.opacity) } else { portraitBody.transition(.opacity) }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .sheet(item: $share) { ShareSheet(items: $0.items) }
        .overlay(alignment: .top) { ExportToast(exporter: exporter) }
        .alert("Delete this review item and its recordings?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("\(item.labels.first.map(FrigateFormat.labelName)?.capitalizedFirst ?? L("Event")) at \(FrigateFormat.time(item.start, seconds: true))")
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .task { await load() }
        // The controls over the video hide after 4 seconds of playback without use.
        .task(id: overlayToken) {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, player.wantsToPlay, !player.isScrubbing else { return }
            if MenuPresence.isShowing { overlayToken += 1; return }
            if pointerOnControls { overlayToken += 1; return }
            withAnimation(.easeOut(duration: 0.25)) { overlayVisible = false }
        }
        // Paused (also at the end): bring the controls back.
        .onChange(of: player.wantsToPlay) { _, playing in
            if !playing { withAnimation(.easeOut(duration: 0.2)) { overlayVisible = true } }
        }
        .onDisappear { player.stop(); if fullscreen { model.immersive = false } }
    }

    private var portraitBody: some View {
        VStack(spacing: 0) {
            header
            if horizontalSizeClass == .regular {
                // iPad and Mac: video and scrubber beside the details.
                WideDetailLayout(aspect: conn?.config?.cameras[item.camera]?.aspectRatio ?? 16 / 9, reserve: 64) {
                    VStack(spacing: 0) {
                        videoPlayer.clipShape(RoundedRectangle(cornerRadius: 12))
                        scrubber
                    }
                } details: {
                    info
                    tiles
                    objects
                } extra: {
                    lifecycle
                } actions: {
                    actions
                }
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    videoPlayer
                    scrubber
                    info
                    tiles
                    objects
                    lifecycle
                }
                .padding(.bottom, 16)
            }
            actions
            }
        }
        .screenBackground()
    }

    // MARK: Landscape

    /// Full-screen video. A tap shows or hides the controls; they hide by themselves after
    /// 4 seconds of playback without touches.
    private var landscapeBody: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerLayerView(player: player.player)
                .zoomable()
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) { overlayVisible.toggle() }
                    keepOverlay()
                }
                // With a mouse (Mac, iPad with trackpad) the controls come back when the pointer
                // moves over the video; a click or tap toggles them as on a touch screen.
                .onContinuousHover { phase in
                    guard case .active = phase else { return }
                    if !overlayVisible { withAnimation(.easeOut(duration: 0.25)) { overlayVisible = true } }
                    keepOverlay()
                }
            playerStatus(showPlay: !overlayVisible)
            landscapeOverlay.fadingControls(overlayVisible)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    private func keepOverlay() { overlayToken += 1 }

    private func setFullscreen(_ on: Bool) {
        withAnimation(.easeInOut(duration: 0.3)) { fullscreen = on; model.immersive = on }
        keepOverlay()
    }

    private var landscapeOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if fullscreen {
                    FullscreenButton(isOn: true, size: 40) { setFullscreen(false) }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Back")
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(conn?.config?.cameras[item.camera]?.displayName ?? FrigateFormat.prettyName(item.camera))
                        .font(.system(size: 15, weight: .semibold))
                    Text(timeRange).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                .lineLimit(1)
                ForEach(item.labels, id: \.self) { LabelTag(label: $0, size: 12) }
                Spacer()
                Button { Task { await markReviewed() }; keepOverlay() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isReviewed ? "checkmark.circle.fill" : "checkmark.circle")
                        Text("Reviewed")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isReviewed ? Theme.textSecondary : Theme.onColor)
                    .padding(.horizontal, 12).frame(height: 34)
                    .background(isReviewed ? Color.white.opacity(0.12) : Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isReviewed)
                Button { Task { await download() }; keepOverlay() } label: {
                    Group {
                        if downloading { ProgressView().tint(.white) } else { Image(systemName: "square.and.arrow.up") }
                    }
                    .font(.system(size: 19, weight: .medium)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Share clip")
                Button { confirmDelete = true; keepOverlay() } label: {
                    Image(systemName: "trash").font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Theme.destructive).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Delete")
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8)
            // Mac full screen: below the window buttons, which sit in the top-left corner.
            .padding(.top, fullscreen && ProcessInfo.processInfo.isMacCatalystApp ? 26 : 0)
            .background(Color.black.opacity(0.75).ignoresSafeArea(edges: [.top, .horizontal]))
            .pointerOver($pointerOnControls)

            HStack(spacing: 18) {
                OverlayButton(systemImage: "gobackward.10", size: 50, label: "Back 10 seconds") { player.skip(-10); keepOverlay() }
                OverlayButton(systemImage: player.wantsToPlay ? "pause.fill" : "play.fill", size: 60,
                              label: player.wantsToPlay ? "Pause" : "Play") { player.toggle(); keepOverlay() }
                OverlayButton(systemImage: "goforward.10", size: 50, label: "Forward 10 seconds") { player.skip(10); keepOverlay() }
            }
            .pointerOver($pointerOnControls)
            .opacity(noRecording || player.error != nil || player.isBuffering || player.duration == 0 ? 0 : 1)
            .frame(maxHeight: .infinity)

            scrubber
                .padding(.bottom, 10)
                .background(Color.black.opacity(0.7).ignoresSafeArea(edges: [.bottom, .horizontal]))
                .pointerOver($pointerOnControls)
                .simultaneousGesture(TapGesture().onEnded { keepOverlay() })
                .onChange(of: player.isScrubbing) { _, _ in keepOverlay() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            // Only the arrow, like every other screen.
            Button { dismiss() } label: {
                BackButtonLabel()
            }
            .accessibilityLabel("Back")
            Spacer()
            // Not disabled while loading: that would dim the spinner. `download()` ignores a second tap.
            Button { Task { await download() } } label: {
                HeaderIconLabel(systemName: "square.and.arrow.up", loading: downloading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share clip")
        }
        .headerBarPadding()
        .padding(.bottom, 8)
    }

    // MARK: Player

    /// Like the playback screen: a tap shows or hides the controls over the video, the
    /// pointer shows them on the Mac, and they hide by themselves during playback.
    private var videoPlayer: some View {
        ZStack {
            PlayerLayerView(player: player.player)
                .zoomable()
                // On the video itself, as in playback: on the stack around it the zoom's
                // double-tap swallowed single taps.
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) { overlayVisible.toggle() }
                    keepOverlay()
                }
            playerStatus(showPlay: !overlayVisible)
        }
        .aspectRatio(conn?.config?.cameras[item.camera]?.aspectRatio ?? 16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .overlay(alignment: .bottom) {
            if canPlay {
                PlaybackOverlayControls(player: player, large: horizontalSizeClass == .regular, onUse: keepOverlay)
                    .fadingControls(overlayVisible, pointerOver: $pointerOnControls)
            }
        }
        .overlay(alignment: .topTrailing) {
            if horizontalSizeClass == .regular && !noRecording {
                FullscreenButton(isOn: false) { setFullscreen(true) }.padding(10).fadingControls(overlayVisible, pointerOver: $pointerOnControls)
            }
        }
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            if !overlayVisible { withAnimation(.easeOut(duration: 0.25)) { overlayVisible = true } }
            keepOverlay()
        }
    }

    /// Whether there is something to control: a loaded recording, not an error or a spinner.
    private var canPlay: Bool {
        !(noRecording || player.error != nil || player.isBuffering || player.duration == 0)
    }

    /// No recording, an error, buffering or the play button, drawn over the video.
    @ViewBuilder
    private func playerStatus(showPlay: Bool = true) -> some View {
            if noRecording {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash").font(.system(size: 26))
                    Text("No recording for this event").font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.85)).padding()
            } else if let error = player.error {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.title2)
                    Text(error).font(.system(size: 13)).multilineTextAlignment(.center)
                }
                .foregroundStyle(.white).padding()
            } else if player.isBuffering || player.duration == 0 {
                ProgressView().tint(.white)
            } else if showPlay && !player.wantsToPlay {
                OverlayButton(systemImage: "play.fill", size: 56, label: "Play") { player.play() }
            }
    }

    private var scrubber: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                let total = max(player.duration, 0.1)
                let evStart = max(0, min(1, (activityStart - clipStart) / total))
                let evEnd = max(evStart, min(1, (activityEnd - clipStart) / total))
                // Redrawn every frame while playing, so the dot glides instead of stepping.
                TimelineView(.animation(paused: !player.isPlaying || player.isScrubbing)) { _ in
                    let progress = min(1, player.liveTime / total)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.controlBorder).frame(height: 4)
                        RoundedRectangle(cornerRadius: 3).fill(Theme.warning.opacity(0.28))
                            .frame(width: max(0, (evEnd - evStart) * w), height: 14)
                            .offset(x: evStart * w)
                        Capsule().fill(Theme.accent).frame(width: progress * w, height: 4)
                        Circle().fill(.white).frame(width: 16, height: 16)
                            .offset(x: progress * w - 8)
                    }
                }
                .frame(height: 28)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in player.scrub(to: max(0, min(1, v.location.x / w)) * total) }
                    .onEnded { v in player.endScrub(at: max(0, min(1, v.location.x / w)) * total) })
            }
            .frame(height: 28)
            // The buttons sit over the video (PlaybackOverlayControls), as on the playback screen.
            HStack {
                Text(FrigateFormat.duration(player.currentTime)).monospacedDigit()
                Spacer()
                Text(FrigateFormat.duration(player.duration)).monospacedDigit()
            }
            .font(.system(size: horizontalSizeClass == .regular ? 14 : 12))
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    // MARK: Info

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(item.labels, id: \.self) { LabelTag(label: $0, size: 12) }
                Text(item.severity == .alert ? L("Alert") : L("Detection"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.control, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.controlBorder, lineWidth: 1))
            }
            Text(conn?.config?.cameras[item.camera]?.displayName ?? FrigateFormat.prettyName(item.camera))
                .font(.system(size: 24, weight: .bold))
            Text(timeRange).font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var timeRange: String {
        let day = FrigateFormat.dayTitle(item.start)
        let s = FrigateFormat.time(item.start, seconds: true)
        guard let end = item.end else { return L("\(day), \(s), in progress") }
        // Frigate sometimes closes an item days later; then show the end date too.
        if !Calendar.current.isDate(end, inSameDayAs: item.start) {
            return L("\(day), \(s) to \(FrigateFormat.dayTitle(end)) \(FrigateFormat.time(end, seconds: true))")
        }
        return L("\(day), \(s) to \(FrigateFormat.time(end, seconds: true))")
    }

    private var tiles: some View {
        let score = events.compactMap(\.bestScore).max()
        let zones = (item.data.zones ?? []).map(FrigateFormat.prettyName)
        let subLabels = (item.data.subLabels ?? []) + events.compactMap { $0.subLabel?.name }.filter { !$0.isEmpty }
        let plates = events.compactMap(\.recognizedPlate)
        let third: (String, String) = {
            if !plates.isEmpty {
                var seen = Set<String>()
                return (L("PLATE"), plates.filter { seen.insert($0).inserted }.joined(separator: ", "))
            }
            if !subLabels.isEmpty {
                var seen = Set<String>()
                return (L("SUB LABEL"), subLabels.filter { seen.insert($0).inserted }.joined(separator: ", "))
            }
            return (L("DURATION"), item.duration > 3600 ? L("> 1 h") : FrigateFormat.shortDuration(trackedDuration))
        }()
        return HStack(spacing: 8) {
            tile(L("SCORE"), score.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
            tile(L("ZONES"), zones.isEmpty ? L("None") : zones.joined(separator: ", "))
            tile(third.0, third.1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    // MARK: Objects

    /// The tracked objects in this event with their snapshots; the one opened from Explore first.
    private var objectEvents: [FrigateEvent] {
        let list = events.sorted { $0.startTime < $1.startTime }
        guard let id = route.focusEventID, let i = list.firstIndex(where: { $0.id == id }) else { return list }
        var out = list
        out.insert(out.remove(at: i), at: 0)
        return out
    }

    @ViewBuilder
    private var objects: some View {
        let list = objectEvents
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: L("Objects"))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(list) { e in
                            Button { snapshotEvent = e } label: { objectCard(e) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .sheet(item: $snapshotEvent) { e in
                SnapshotViewer(event: e, client: client, cameraName: conn?.config?.cameras[e.camera]?.displayName)
            }
        }
    }

    private func objectCard(_ e: FrigateEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(url: e.hasSnapshot == true ? client?.snapshotURL(for: e) : client?.thumbnailURL(for: e),
                        session: client?.session ?? .shared)
                .frame(width: 180, height: 101)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                LabelTag(label: e.label, size: 12)
                Spacer()
                if let score = e.bestScore {
                    Text("\(Int((score * 100).rounded()))%").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                }
            }
        }
        .padding(8)
        .frame(width: 196)
        .card(border: e.id == route.focusEventID ? Theme.accent : Theme.cardBorder, radius: 12)
    }

    /// How long the objects were tracked; Frigate often closes the review item itself much sooner.
    private var trackedDuration: TimeInterval { max(0, activityEnd - activityStart) }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            Text(value).font(.system(size: 17, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .card(radius: 12)
    }

    @ViewBuilder
    private var lifecycle: some View {
        if !timeline.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("OBJECT LIFECYCLE")
                    .font(.system(size: 12, weight: .semibold)).kerning(0.4)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
                ForEach(Array(timeline.enumerated()), id: \.offset) { _, entry in
                    Button {
                        player.seek(to: entry.timestamp + offset - clipStart, precise: true)
                    } label: {
                        HStack(spacing: 12) {
                            Circle().fill(dotColor(entry)).frame(width: 8, height: 8)
                            Text(entry.description).font(.system(size: 14)).foregroundStyle(Theme.text)
                            Spacer()
                            Text(FrigateFormat.time(Date(timeIntervalSince1970: entry.timestamp), seconds: true))
                                .font(.system(size: 13).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.cardBorder).frame(height: 1) }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .card()
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
    }

    private func dotColor(_ e: TimelineEntry) -> Color {
        switch e.classType {
        case "visible", "heard": return Theme.labelColor(e.data?.label ?? "")
        case "entered_zone": return Theme.accent
        case "gone": return Theme.offline
        default: return Theme.textTertiary
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 8) {
            Button { Task { await markReviewed() } } label: {
                HStack(spacing: 6) {
                    if isReviewed { Image(systemName: "checkmark") }
                    Text("Reviewed")
                }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isReviewed ? Theme.textSecondary : Theme.onColor)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(isReviewed ? Theme.card : Theme.accent, in: RoundedRectangle(cornerRadius: 12))
            }
            .disabled(isReviewed)
            // Save: to Photos, or as an export kept in Frigate (sharing is the button at the top). Kept apart from
            // the playing video, which redraws this screen several times a second: a menu
            // rebuilt while open flickers.
            Stable(key: [downloading, exporter.isWorking]) {
            Menu {
                Button { saveToPhotos() } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                Button { saveToFrigate() } label: { Label("Save to Frigate", systemImage: "externaldrive") }
            } label: {
                // The spinner shows on the button that started the work: sharing has its own.
                Group { if exporter.isWorking && !downloading { ProgressView() } else { Text("Save") } }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .card(border: Theme.controlBorder, radius: 12)
            }
            .menuStyle(.button)
            // Also while the event is still going: it saves what has been recorded so far.
            .disabled(downloading || exporter.isWorking)
            }
            .stable()
            Button { confirmDelete = true } label: {
                Text("Delete")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.destructive)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .card(border: Theme.controlBorder, radius: 12)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: Loading

    private func load() async {
        guard let client else { return }
        // Read the reviewed flag fresh: the screen that opened this item may hold an old copy.
        Task {
            if let fresh = try? await client.review(id: item.id), fresh.hasBeenReviewed { item.hasBeenReviewed = true }
        }
        // The tracked objects (where to start) and whether there is a recording, both at once:
        // on a remote connection every round trip before the video shows is felt.
        let ids = item.data.detections ?? []
        let needsVideo = player.url == nil
        let (start, end) = (clipStart, clipEnd)
        async let loadedEvents = (try? await client.events(ids: ids)) ?? []
        async let loadedSegments = needsVideo
            ? ((try? await client.recordings(camera: item.camera, after: Date(timeIntervalSince1970: start),
                                             before: Date(timeIntervalSince1970: end))) ?? [])
            : []
        events = await loadedEvents
        if needsVideo {
            // Opened on one object: start a moment before it appeared.
            let focus = route.focusEventID.flatMap { id in events.first { $0.id == id } }
            let startAt = focus.map { max(0, $0.startTime + offset - 1 - clipStart) } ?? 0
            let segs = await loadedSegments
            if segs.isEmpty {
                noRecording = true
            } else {
                player.load(client.vodURL(camera: item.camera, start: clipStart, end: clipEnd), startAt: startAt)
            }
        }
        var entries: [TimelineEntry] = []
        await withTaskGroup(of: [TimelineEntry].self) { group in
            for id in ids.prefix(10) {
                group.addTask { (try? await client.timeline(sourceId: id)) ?? [] }
            }
            for await part in group { entries += part }
        }
        timeline = entries.sorted { $0.timestamp < $1.timestamp }
    }

    private func markReviewed() async {
        guard let client else { return }
        do {
            try await client.markViewed([item.id])
            item.hasBeenReviewed = true
            model.reviewedIDs.insert(item.id)
            await conn?.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func download() async {
        guard let client, !downloading else { return }
        downloading = true
        defer { downloading = false }
        exporter.state = .working(L("Preparing clip…"))
        do {
            let file = try await exporter.download(client: client, camera: item.camera, start: clipStart, end: clipEnd)
            exporter.state = .idle
            share = ShareItem(items: [file])
        } catch {
            exporter.state = .idle
            errorMessage = error.localizedDescription
        }
    }

    private func saveToPhotos() {
        guard let client else { return }
        Task { await exporter.saveToPhotos(client: client, camera: item.camera, start: clipStart, end: clipEnd) }
    }

    private func saveToFrigate() {
        guard let client else { return }
        let name = ClipExporter.exportName(camera: item.camera, displayName: conn?.config?.cameras[item.camera]?.displayName,
                                           start: activityStart, label: item.labels.first)
        Task { await exporter.saveToFrigate(client: client, camera: item.camera, start: clipStart, end: clipEnd, name: name) }
    }

    private func delete() async {
        guard let client else { return }
        do {
            try await client.deleteReviews([item.id])
            await conn?.refresh()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
