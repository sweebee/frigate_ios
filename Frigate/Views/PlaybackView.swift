import SwiftUI

/// Maps between wall-clock time and the position in a Frigate VOD playlist,
/// which concatenates recording segments and skips gaps.
struct RecordingMap {
    struct Span { var wallStart: Double; var wallEnd: Double; var offset: Double }
    var spans: [Span] = []

    init() {}

    init(segments: [RecordingSegment], from start: Double, to end: Double) {
        var offset = 0.0
        for s in segments.sorted(by: { $0.startTime < $1.startTime }) {
            let a = max(s.startTime, start), b = min(s.endTime, end)
            guard b > a else { continue }
            // Segments can overlap by a moment; the VOD still plays each in full.
            spans.append(Span(wallStart: a, wallEnd: b, offset: offset))
            offset += b - a
        }
    }

    var isEmpty: Bool { spans.isEmpty }
    var duration: Double { spans.last.map { $0.offset + ($0.wallEnd - $0.wallStart) } ?? 0 }

    func playerTime(for wall: Double) -> Double {
        guard let first = spans.first else { return 0 }
        if wall <= first.wallStart { return 0 }
        for s in spans {
            if wall < s.wallStart { return s.offset }
            if wall <= s.wallEnd { return s.offset + (wall - s.wallStart) }
        }
        return duration
    }

    func wallTime(for player: Double) -> Double {
        guard let first = spans.first else { return 0 }
        for s in spans where player < s.offset + (s.wallEnd - s.wallStart) {
            return s.wallStart + max(0, player - s.offset)
        }
        return spans.last?.wallEnd ?? first.wallStart
    }

    /// Index of the first span starting at or after `t`. Spans are sorted by start, so this is
    /// a binary search: the timelines ask this for every bar on every frame, and a day has
    /// thousands of segments, which made scrubbing unusably slow when scanned in full.
    private func firstSpan(startingAtOrAfter t: Double) -> Int {
        var lo = 0, hi = spans.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if spans[mid].wallStart < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Whether any recording overlaps `start..<end`.
    func hasRecording(from start: Double, to end: Double) -> Bool {
        // Spans that start before `end`; segments hardly overlap, so the few just before
        // that point are the only ones that can still reach into the range.
        var i = firstSpan(startingAtOrAfter: end) - 1
        var checked = 0
        while i >= 0, checked < 4 {
            if spans[i].wallEnd > start { return true }
            i -= 1
            checked += 1
        }
        return false
    }

    func hasRecording(at wall: Double) -> Bool {
        var i = firstSpan(startingAtOrAfter: wall.nextUp) - 1
        var checked = 0
        while i >= 0, checked < 4 {
            if wall >= spans[i].wallStart && wall <= spans[i].wallEnd { return true }
            i -= 1
            checked += 1
        }
        return false
    }
}

private struct FilterBarKey: Equatable {
    let filter: ReviewFilter
    let reviewIDs: [String]
    let camera: String
}

struct PlaybackView: View {
    enum Tab: Hashable { case events, timeline }

    let route: PlaybackRoute
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    // Landscape playback state.
    @State private var overlayVisible = true
    /// iPad and Mac: the video fills the window, with the landscape controls. The same player
    /// keeps playing; only its picture moves.
    @State private var fullscreen = false
    @State private var showEventsPanel = false
    @State private var overlayToken = 0
    /// The pointer rests on the controls over the video: keep them.
    @State private var pointerOnControls = false
    /// A menu in the overlay is open; the overlay must not hide underneath it.
    @State private var menuOpen = false
    /// Where the user scrubbed to, shown until the player has actually arrived there,
    /// so the timeline does not jump back while a seek or hour reload is in progress.
    @State private var heldTime: Double?
    /// The playhead is on a moment without recordings: the video shows a placeholder.
    @State private var gapTime: Double?
    @State private var timelineScale: Double = 2
    @State private var camera: String
    @State private var day: Date
    @State private var tab: Tab = .events
    @State private var player = RecordingPlayer()
    /// Recordings for the whole day, used by the timeline.
    @State private var map = RecordingMap()
    /// Recordings in the loaded hour; Frigate's VOD endpoint refuses long ranges.
    @State private var chunkMap = RecordingMap()
    @State private var chunkStart: Double?
    @State private var segments: [RecordingSegment] = []
    @State private var reviews: [ReviewItem] = []
    @State private var filter = ReviewFilter()
    @State private var motion: [MotionActivity] = []
    @State private var loading = true
    @State private var showDatePicker = false
    @State private var pendingReviewID: String?
    /// Wall-clock time shown on the timeline while dragging.
    @State private var scrubTime: Double?
    @State private var exporter = ClipExporter()
    /// Low-resolution preview shown while dragging a timeline.
    @State private var preview = PreviewScrubber()
    @State private var share: ShareItem?
    /// An event the user asked to delete; confirmed in an alert.
    @State private var deletingReview: ReviewItem?
    /// Long-press actions on events, the same everywhere in the app.
    @State private var reviewActions = ReviewActions()
    @State private var deleteError: String?
    /// Moment to start at once the recordings are loaded (only on the first load).
    @State private var pendingStartTime: Double?

    init(route: PlaybackRoute) {
        self.route = route
        _camera = State(initialValue: route.camera)
        _day = State(initialValue: route.day)
        _pendingReviewID = State(initialValue: route.reviewID)
        _pendingStartTime = State(initialValue: route.startTime)
        _tab = State(initialValue: route.showTimeline ? .timeline : .events)
    }

    private var conn: ServerConnection? { model.connection(for: route.serverID) }
    /// Frigate's detect.annotation_offset for this camera, in seconds.
    private var annotationOffset: Double { conn?.config?.cameras[camera]?.annotationOffset ?? 0 }
    private var client: FrigateClient? { conn?.client }
    private var dayStart: Double { day.timeIntervalSince1970 }
    private var dayEnd: Double { min(Calendar.current.date(byAdding: .day, value: 1, to: day)!.timeIntervalSince1970, Date().timeIntervalSince1970) }

    /// Wall-clock time at the playhead.
    private var wallTime: Double { scrubTime ?? gapTime ?? heldTime ?? playerWallTime }
    private var playerWallTime: Double { chunkMap.isEmpty ? dayStart : chunkMap.wallTime(for: player.currentTime) }

    /// Ends a scrub: keep showing `t` until the player reports a position near it.
    private func finishScrub(at raw: Double, snap: Double = 0) {
        scrubTime = nil
        jump(toWall: snapToRecording(raw, within: snap), autoplay: player.wantsToPlay, earlier: 1)
    }

    /// Jumps to `t` and shows that time (and the event there) at once, while the player may
    /// still be loading another hour of recording.
    private func jump(toWall t: Double, autoplay: Bool, earlier: Double = 0) {
        heldTime = t
        seek(toWall: t, autoplay: autoplay, earlier: earlier)
        Task {
            // Release only once the player is ready and has reported a nearby position
            // on two checks in a row, so a new hour loading cannot flash its start.
            var steady = 0
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(150))
                if heldTime != t { return }
                let ready = player.duration > 0 && player.pendingStart == nil
                let near = playerWallTime > t - earlier - 0.5 && playerWallTime < t + 1.5
                steady = ready && near ? steady + 1 : 0
                if steady >= 2 { break }
            }
            if heldTime == t { heldTime = nil }
            preview.hide()
        }
    }

    /// Review items that pass the type, label and zone filters.
    private var visibleReviews: [ReviewItem] { reviews.filter(filter.matches) }

    /// The event offered in the save menu: the last one that started before the playhead.
    /// Unlike `currentReview` it does not disappear when the event ends, so an open menu stays put.
    private var menuReview: ReviewItem? {
        // Event times are detection times; the recording runs `annotationOffset` from them.
        let t = wallTime - annotationOffset
        return visibleReviews.filter { $0.startTime - 5 <= t }.max { $0.startTime < $1.startTime }
    }

    private var currentReview: ReviewItem? {
        let t = wallTime - annotationOffset
        return reviews.first { t >= $0.startTime - 5 && t <= ($0.endTime ?? .infinity) + 5 }
    }

    /// iPhone held sideways: full-screen video with an overlay, like an NVR app.
    private var isLandscape: Bool { verticalSizeClass == .compact && horizontalSizeClass != .regular }
    /// iPad full screen and the Mac: video with a horizontal timeline under it, events beside.
    private var isWide: Bool { horizontalSizeClass == .regular }

    var body: some View {
        Group {
            // Into and out of full screen with a cross-fade.
            if isWide && fullscreen { landscapeBody.transition(.opacity) } else if isWide { wideBody.transition(.opacity) } else if isLandscape { landscapeBody } else { portraitBody }
        }
        .overlay(alignment: .top) { ExportToast(exporter: exporter) }
        .reviewActionsHost(reviewActions)
        .onChange(of: reviewActions.deletedIDs) { _, ids in
            withAnimation(.easeOut(duration: 0.2)) { reviews.removeAll { ids.contains($0.id) } }
        }
        .sheet(item: $share) { ShareSheet(items: $0.items) }
        .alert("Delete this review item and its recordings?",
               isPresented: Binding(get: { deletingReview != nil }, set: { if !$0 { deletingReview = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let r = deletingReview { Task { await deleteReview(r) } }
            }
        } message: {
            if let r = deletingReview {
                Text("\(r.labels.first.map(FrigateFormat.labelName)?.capitalizedFirst ?? L("Event")) at \(FrigateFormat.time(r.start, seconds: true))")
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(deleteError ?? "") }
        .sheet(isPresented: $showDatePicker) {
            RecordingCalendarSheet(day: $day, sources: client.map { [(client: $0, cameras: Optional([camera]))] } ?? [])
        }
        .task(id: "\(camera)|\(day.timeIntervalSince1970)") { await load() }
        .onChange(of: player.wantsToPlay) { _, playing in
            guard !playing else { return }
            // Paused: bring the controls back so it is clear the video is not stuck. Wait a
            // moment first: at the end of each hour playback stops briefly and resumes by itself.
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                guard !player.wantsToPlay else { return }
                withAnimation(.easeOut(duration: 0.2)) { overlayVisible = true }
                overlayToken += 1
            }
        }
        .onDisappear { player.stop(); if fullscreen { model.immersive = false } }
        .onChange(of: isLandscape) { _, landscape in if !landscape && !isWide { fullscreen = false } }
        .onChange(of: player.finishedCount) { _, _ in
            // Continue with the next hour that has recordings.
            guard let chunkStart else { return }
            let next = chunkStart + chunkLength
            if next < dayEnd { seek(toWall: next, autoplay: true, skipGap: true) }
        }
    }

    private var wideBody: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                // Explicit size: the video fills the column at 16:9 but leaves room for the timeline.
                let side = min(380, geo.size.width * 0.34)
                let videoWidth = max(200, geo.size.width - 32 - 16 - side)
                let videoHeight = min(videoWidth * 9 / 16, max(160, geo.size.height - 150))
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 10) {
                        videoPlayer
                            .frame(width: videoHeight * 16 / 9, height: videoHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .frame(maxWidth: .infinity)
                        horizontalTimeline
                            .frame(width: videoWidth)
                        Spacer(minLength: 0)
                    }
                    .frame(width: videoWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    VStack(alignment: .leading, spacing: 8) {
                        Stable(key: FilterBarKey(filter: filter, reviewIDs: reviews.map(\.id), camera: camera)) {
                            ReviewFilterBar(filter: $filter, reviews: reviews,
                                            zones: (conn?.config?.cameras[camera]?.zones?.keys).map(Array.init) ?? [])
                        }
                        .stable()
                        eventsList
                    }
                    // The filters and the list bring the phone's 16 pt margins; here the column
                    // itself is the margin, so their rows line up with the video and the window.
                    .padding(.horizontal, -16)
                    .frame(width: side)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            .clipped()
        }
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: overlayToken) {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, player.wantsToPlay, scrubTime == nil else { return }
            if menuOpen || MenuPresence.isShowing { menuOpen = false; overlayToken += 1; return }
            if pointerOnControls { overlayToken += 1; return }
            withAnimation(.easeOut(duration: 0.25)) { overlayVisible = false }
        }
    }

    /// The horizontal timeline from the landscape view, as a block under the video.
    private var horizontalTimeline: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .top) {
                HorizontalTimeline(dayStart: dayStart, dayEnd: dayEnd, wallTime: wallTime, motion: motion,
                                   reviews: visibleReviews, map: map,
                                   onScrub: { heldTime = nil; scrubTime = $0; preview.show($0 - annotationOffset) },
                                   onScrubEnd: { t, snap in finishScrub(at: t, snap: snap) },
                                   onInteract: {},
                                   onScrubCancel: { scrubTime = nil; preview.hide() },
                                   onSelect: { jump(toWall: $0.startTime - 1 + annotationOffset, autoplay: true, earlier: 2) },
                                   scale: $timelineScale)
                    .padding(.top, 6)
                Rectangle().fill(Theme.accent).frame(width: 2, height: 74).allowsHitTesting(false)
            }
            HStack(spacing: 16) {
                Button { timelineScale = min(timelineScale * 2, HorizontalTimeline.maxScale) } label: {
                    Image(systemName: "minus.magnifyingglass").font(.system(size: 16))
                }
                .accessibilityLabel("Zoom out")
                Button { timelineScale = max(timelineScale / 2, HorizontalTimeline.minScale) } label: {
                    Image(systemName: "plus.magnifyingglass").font(.system(size: 16))
                }
                .accessibilityLabel("Zoom in")
                Spacer()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .card(radius: 12)
    }

    private var portraitBody: some View {
        VStack(spacing: 0) {
            header
            videoPlayer
            SegmentedBar(options: [Tab.events, .timeline], selection: $tab) { $0 == .events ? L("Events") : L("Timeline") }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            Stable(key: FilterBarKey(filter: filter, reviewIDs: reviews.map(\.id), camera: camera)) {
                ReviewFilterBar(filter: $filter, reviews: reviews,
                                zones: (conn?.config?.cameras[camera]?.zones?.keys).map(Array.init) ?? [])
            }
            .stable()
            .padding(.bottom, 8)
            switch tab {
            case .events: eventsList
            case .timeline:
                PlaybackTimeline(dayStart: dayStart, dayEnd: dayEnd, wallTime: wallTime, motion: motion, reviews: visibleReviews,
                                 map: map, isFollowing: scrubTime == nil, annotationOffset: annotationOffset,
                                 onSelect: { jump(toWall: $0.startTime - 1 + annotationOffset, autoplay: true, earlier: 2) },
                                 segments: segments,
                                 onScrub: { heldTime = nil; scrubTime = $0; preview.show($0 - annotationOffset) },
                                 onScrubEnd: { t, snap in finishScrub(at: t, snap: snap) },
                                 onScrubCancel: { scrubTime = nil; preview.hide() })
            }
        }
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: overlayToken) {
            // Hide the video controls after 4 seconds of playback without touches.
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, player.wantsToPlay, scrubTime == nil else { return }
            if menuOpen || MenuPresence.isShowing { menuOpen = false; overlayToken += 1; return }
            if pointerOnControls { overlayToken += 1; return }
            withAnimation(.easeOut(duration: 0.25)) { overlayVisible = false }
        }
    }

    private let chunkLength: Double = 3600

    // MARK: Saving clips

    /// Save button on the video: the event that is playing, or a span around the playhead.
    private var saveMenu: some View {
        Stable(key: [menuReview?.id ?? "", exporter.isWorking ? "busy" : ""]) { saveMenuContent }.stable()
    }

    private var saveMenuContent: some View {
        Menu {
            if let r = menuReview {
                Section("\(r.labels.first.map(FrigateFormat.labelName)?.capitalizedFirst ?? L("Event")) at \(FrigateFormat.time(r.start, seconds: true))") {
                    Button { save(r.startTime - 3, (r.endTime ?? Date().timeIntervalSince1970) + 3) } label: {
                        Label("Save event to Photos", systemImage: "square.and.arrow.down")
                    }
                    Button { saveToFrigate(r.startTime - 3, (r.endTime ?? Date().timeIntervalSince1970) + 3, label: r.labels.first) } label: {
                        Label("Save event to Frigate", systemImage: "externaldrive")
                    }
                    Button { shareClip(r.startTime - 3, (r.endTime ?? Date().timeIntervalSince1970) + 3) } label: {
                        Label("Share event", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) { deletingReview = r } label: {
                        DestructiveMenuLabel(title: "Delete event")
                    }
                }
            }
            Section("From the playhead") {
                ForEach([30.0, 60, 300], id: \.self) { secs in
                    Menu {
                        Button { save(wallTime - secs / 2, wallTime + secs / 2) } label: {
                            Label("To Photos", systemImage: "square.and.arrow.down")
                        }
                        Button { saveToFrigate(wallTime - secs / 2, wallTime + secs / 2) } label: {
                            Label("To Frigate's exports", systemImage: "externaldrive")
                        }
                    } label: {
                        Label(secs < 60 ? L("Save \(Int(secs)) seconds") : L("Save \(Int(secs / 60)) minutes"),
                              systemImage: "film")
                    }
                }
            }
        } label: {
            Image(systemName: exporter.isWorking ? "hourglass" : "square.and.arrow.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                // This symbol's tray sits low in its frame (measured ~0.6 pt at this size,
                // and the heavy tray adds to it optically); lift it to look centred.
                .offset(y: exporter.isWorking ? 0 : -1)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.6), in: Circle())
        }
        .disabled(exporter.isWorking)
        .accessibilityLabel("Save video")
    }

    /// Clamps a range to the loaded day and to what has been recorded.
    private func clampRange(_ start: Double, _ end: Double) -> (Double, Double) {
        let s = max(start, dayStart), e = min(end, dayEnd, Date().timeIntervalSince1970)
        return (s, max(e, s + 1))
    }

    private func save(_ start: Double, _ end: Double) {
        guard let client else { return }
        let (s, e) = clampRange(start, end)
        Task { await exporter.saveToPhotos(client: client, camera: camera, start: s, end: e) }
    }

    /// Deletes a review item (and with it its recordings on the server) and drops it from the list.
    private func deleteReview(_ r: ReviewItem) async {
        guard let client else { return }
        do {
            try await client.deleteReviews([r.id])
            withAnimation(.easeOut(duration: 0.2)) { reviews.removeAll { $0.id == r.id } }
            Task { await conn?.refresh() }
        } catch {
            deleteError = error.localizedDescription
        }
    }

    /// Has Frigate keep the span as an export on the server.
    private func saveToFrigate(_ start: Double, _ end: Double, label: String? = nil) {
        guard let client else { return }
        let (s, e) = clampRange(start, end)
        let name = ClipExporter.exportName(camera: camera, displayName: conn?.config?.cameras[camera]?.displayName, start: s, label: label)
        Task { await exporter.saveToFrigate(client: client, camera: camera, start: s, end: e, name: name) }
    }

    private func shareClip(_ start: Double, _ end: Double) {
        guard let client else { return }
        let (s, e) = clampRange(start, end)
        Task {
            exporter.state = .working(L("Preparing video…"))
            do {
                let file = try await exporter.download(client: client, camera: camera, start: s, end: e)
                exporter.state = .idle
                share = ShareItem(items: [file])
            } catch {
                exporter.state = .failed(error.localizedDescription)
                try? await Task.sleep(for: .seconds(2.5))
                exporter.state = .idle
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                BackButtonLabel()
            }
            .accessibilityLabel("Back")
            Spacer()
            Stable(key: [camera, conn?.server.name ?? ""] + (conn?.cameras.map(\.name) ?? [])) { cameraMenu }.stable()
            Spacer()
            Button { showDatePicker = true } label: {
                HeaderIconLabel(systemName: "calendar")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pick date")
        }
        .headerBarPadding()
        .padding(.bottom, 6)
    }

    private var cameraMenu: some View {
            Menu {
                ForEach(conn?.cameras ?? [], id: \.name) { cam in
                    Button {
                        camera = cam.name
                    } label: {
                        if cam.name == camera { Label(cam.displayName, systemImage: "checkmark") } else { Text(cam.displayName) }
                    }
                }
            } label: {
                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        Text(conn?.config?.cameras[camera]?.displayName ?? FrigateFormat.prettyName(camera))
                            .font(.system(size: 17, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textSecondary)
                    }
                    Text(conn?.server.name ?? "").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                }
                .foregroundStyle(Theme.text)
                .frame(minHeight: 44)
            }
    }

    // MARK: Player

    private var videoPlayer: some View {
        ZStack {
            PlayerLayerView(player: player.player)
                .zoomable()
                .overlay { if gapTime != nil && !preview.showing { gapPlaceholder } }
                .overlay { if preview.showing { PreviewSurface(preview: preview) } }
                .onTapGesture { toggleOverlay() }
            if loading {
                VideoSpinner()
            } else if map.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "film.stack").font(.title2)
                    Text("No recordings for \(FrigateFormat.dayTitle(day).lowercased())").font(.system(size: 13))
                }
                .foregroundStyle(.white.opacity(0.8))
            } else if let error = player.error {
                Text(error).font(.system(size: 13)).foregroundStyle(.white).padding()
            } else if player.isBuffering {
                VideoSpinner()
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .overlay(alignment: .topLeading) {
            if !map.isEmpty {
                HStack(spacing: 6) {
                    timeLabel
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 8).frame(height: VideoChip.height)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    // Every object in the event, as icons (text only for labels without one).
                    ForEach(currentReview?.labels ?? [], id: \.self) { LabelIcon(label: $0, size: VideoChip.height) }
                }
                .padding(10)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !map.isEmpty {
                HStack(spacing: 8) {
                    saveMenu
                    FullscreenButton(isOn: false) { setFullscreen(true) }
                }
                .padding(10).fadingControls(overlayVisible, pointerOver: $pointerOnControls)
            }
        }
        .overlay(alignment: .bottom) {
            if !map.isEmpty {
                PlaybackOverlayControls(player: player, large: isWide, togglePlay: togglePlay, onUse: keepOverlay)
                    .fadingControls(overlayVisible, pointerOver: $pointerOnControls)
            }
        }
        // With a mouse (Mac, iPad with trackpad) the controls show while the pointer moves
        // over the video, like any video player; they hide again after a few seconds.
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            if !overlayVisible { withAnimation(.easeOut(duration: 0.25)) { overlayVisible = true } }
            keepOverlay()
        }
    }

    private var speedMenu: some View {
        Menu {
            ForEach([Float(0.5), 1, 2], id: \.self) { r in
                Button { player.setRate(r) } label: {
                    if player.rate == r { Label(rateTitle(r), systemImage: "checkmark") } else { Text(rateTitle(r)) }
                }
            }
        } label: {
            Text(rateTitle(player.rate))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.6), in: Circle())
        }
        .accessibilityLabel("Playback speed")
    }

    private func rateTitle(_ r: Float) -> String { r == 0.5 ? "½x" : "\(Int(r))x" }

    // MARK: Events

    private var eventsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // The playhead moves several times a second and every move rebuilds this screen;
                // the list only needs to change when its rows or the playing event change.
                let shown = visibleReviews
                let playingID = currentReview?.id
                Stable(key: EventsListKey(ids: shown.map(\.id), total: reviews.count, playing: playingID,
                                          loading: loading, recorded: map.spans.count, filtered: filter.isActive, day: day)) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    // No count while loading: "0 events" read as if the day were empty.
                    SectionLabel(text: loading && reviews.isEmpty ? FrigateFormat.dayTitle(day)
                                 : filter.isActive
                                 ? L("\(FrigateFormat.dayTitle(day)) · \(shown.count) of \(reviews.count) events")
                                 : L("\(FrigateFormat.dayTitle(day)) · \(shown.count) events"))
                        .padding(.top, 2)
                    if loading && reviews.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    } else if reviews.isEmpty {
                        Text("No events on this day.").font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    } else if shown.isEmpty {
                        VStack(spacing: 8) {
                            Text("No events match the filters.").font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                            Button("Clear filters") { filter = ReviewFilter() }.font(.system(size: 14, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 80)
                    }
                    ForEach(shown) { r in
                        let playing = playingID == r.id
                        Button { jump(toWall: r.startTime - 1 + annotationOffset, autoplay: true, earlier: 2) } label: {
                            HStack(spacing: 12) {
                                RemoteImage(url: client?.thumbnailURL(for: r), session: client?.session ?? .shared)
                                    .frame(width: 96, height: 54)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(alignment: .bottomTrailing) {
                                        Text(recordedDurationText(r))
                                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                            .padding(.horizontal, 4).padding(.vertical, 1)
                                            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                                            .padding(3)
                                    }
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 5) { ForEach(r.labels, id: \.self) { LabelIcon(label: $0, size: 20) } }
                                    Text(FrigateFormat.time(r.start, seconds: true)).font(.system(size: 14, weight: .semibold))
                                    let zones = (r.data.zones ?? []).map(FrigateFormat.prettyName)
                                    Text(zones.isEmpty ? (r.severity == .alert ? L("Alert") : L("Detection")) : L("Zone: \(zones.joined(separator: ", "))"))
                                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer(minLength: 0)
                                if playing {
                                    // An icon: the text "Playing" wrapped next to a row of labels.
                                    Image(systemName: "play.fill").font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Theme.onColor)
                                        .frame(width: 26, height: 26)
                                        .background(Theme.accent, in: Circle())
                                        .padding(.trailing, 4)
                                        .accessibilityLabel("Playing")
                                }
                            }
                            .padding(8)
                            .card(border: playing ? Theme.accent : Theme.cardBorder, radius: 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(r.id)
                        .contextMenu { ReviewItemMenu(item: r, serverID: route.serverID, actions: reviewActions) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                }
                .stable()
            }
            .onChange(of: pendingReviewID) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    // MARK: Loading and seeking

    private func load() async {
        guard let client else { loading = false; return }
        loading = true
        player.stop()
        map = RecordingMap()
        let start = dayStart, end = dayEnd
        async let segs = try? client.recordings(camera: camera, after: Date(timeIntervalSince1970: start), before: Date(timeIntervalSince1970: end))
        async let revs = try? client.reviews(cameras: [camera], after: Date(timeIntervalSince1970: start),
                                             before: ScreenshotMode.before ?? Date(timeIntervalSince1970: end), limit: 500)
        async let mot = try? client.motionActivity(cameras: [camera], after: Date(timeIntervalSince1970: start), before: Date(timeIntervalSince1970: end), scale: 30)
        let (s, r, m) = await (segs, revs, mot)
        reviews = (r ?? []).sorted { $0.startTime > $1.startTime }
        motion = (m ?? []).sorted { $0.startTime < $1.startTime }
        segments = (s ?? []).sorted { $0.startTime < $1.startTime }
        map = RecordingMap(segments: segments, from: start, to: end)
        await preview.prepare(client: client, camera: camera, start: start, end: end)
        // Fill the calendar's cache now, so the day picker opens without waiting.
        Task { [camera] in _ = await DayAvailability.load([(client: client, cameras: [camera])]) }
        chunkStart = nil
        chunkMap = RecordingMap()
        loading = false
        guard let last = map.spans.last else { return }

        // Start playing right away: at the requested review item, else the latest event, else near the end.
        if let t = pendingStartTime, t >= start, t < end {
            pendingStartTime = nil
            seek(toWall: t - 3 + annotationOffset, autoplay: true, skipGap: true)
        } else if let id = pendingReviewID, let item = reviews.first(where: { $0.id == id }) {
            jump(toWall: item.startTime - 1 + annotationOffset, autoplay: true, earlier: 2)
        } else if let latest = reviews.first(where: { map.hasRecording(at: $0.startTime + annotationOffset + 1) }) {
            jump(toWall: latest.startTime - 1 + annotationOffset, autoplay: true, earlier: 2)
        } else {
            seek(toWall: max(last.wallStart, last.wallEnd - 60), autoplay: true)
        }
    }

    /// Recording segments that start within the hour, unclipped, so the VOD playlist
    /// begins exactly on a segment boundary and its timeline matches the map.
    private func chunk(at hour: Double) -> RecordingMap {
        let inHour = segments.filter { $0.startTime >= hour && $0.startTime < hour + chunkLength }
        return RecordingMap(segments: inHour, from: -.infinity, to: .infinity)
    }

    /// Seeks to a wall-clock time, loading the hour of recordings that contains it.
    /// Date and time at the playhead, with a pause icon while playback is paused.
    private var timeLabel: some View {
        HStack(spacing: 5) {
            if !player.wantsToPlay && !map.isEmpty {
                Image(systemName: "pause.fill").font(.system(size: 10, weight: .bold))
            }
            Text("\(FrigateFormat.dayTitle(Date(timeIntervalSince1970: wallTime))) · \(FrigateFormat.time(Date(timeIntervalSince1970: wallTime), seconds: true))")
        }
    }

    /// Shown instead of the video when the playhead is on a moment without recordings.
    private var gapPlaceholder: some View {
        ZStack {
            Color.black
            VStack(spacing: 8) {
                Image(systemName: "video.slash").font(.system(size: 26))
                Text("No recording at this time").font(.system(size: 14, weight: .medium))
                if map.spans.contains(where: { $0.wallStart > (gapTime ?? 0) }) {
                    Text("Press play to continue at the next recording").font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .padding()
        }
    }

    /// Length of a review item as far as it was recorded; "no video" when nothing was.
    private func recordedDurationText(_ r: ReviewItem) -> String {
        let s = r.startTime + annotationOffset, e = (r.endTime ?? Date().timeIntervalSince1970) + annotationOffset
        let recorded = map.spans.reduce(0.0) { $0 + max(0, min($1.wallEnd, e) - max($1.wallStart, s)) }
        // Very short items (start equals end) cover no span; check the moment itself.
        if recorded <= 0 && map.hasRecording(at: s) { return FrigateFormat.duration(r.duration) }
        if recorded <= 0 && !map.isEmpty { return L("No video") }
        return recorded > 0 ? FrigateFormat.duration(recorded) : FrigateFormat.reviewDuration(r)
    }

    /// Released just beside a recording: move onto its nearest edge instead of showing a gap.
    private func snapToRecording(_ t: Double, within window: Double) -> Double {
        guard window > 0, !map.isEmpty, !map.hasRecording(at: t) else { return t }
        var best: (distance: Double, time: Double)?
        for s in map.spans {
            for (edge, target) in [(s.wallStart, s.wallStart), (s.wallEnd, s.wallEnd - 1)] {
                let d = abs(edge - t)
                if d <= window, d < (best?.distance ?? .infinity) { best = (d, target) }
            }
        }
        return best?.time ?? t
    }

    /// Play/pause. On a gap, play continues from the next recording.
    private func togglePlay() {
        if let gap = gapTime {
            if let next = map.spans.first(where: { $0.wallStart > gap }) { seek(toWall: next.wallStart, autoplay: true, skipGap: true) }
            return
        }
        player.toggle()
    }

    /// `earlier`: how far before `t` playback may start, on a keyframe. An exact seek has to
    /// decode from the previous keyframe up to `t`, which on cameras with few keyframes took
    /// up to seven seconds; landing on the keyframe itself starts in well under a second.
    private func seek(toWall t: Double, autoplay: Bool, skipGap: Bool = false, earlier: Double = 0) {
        guard let client, !map.isEmpty else { return }
        var target = t
        if !map.hasRecording(at: target) {
            if skipGap, let next = map.spans.first(where: { $0.wallStart > target }) {
                target = next.wallStart
            } else {
                // Nothing recorded here: show that instead of jumping elsewhere.
                player.pause()
                gapTime = t
                heldTime = nil
                preview.hide()
                return
            }
        }
        gapTime = nil
        // A segment belongs to the hour it starts in.
        let segStart = segments.last(where: { $0.startTime <= target })?.startTime ?? target
        var hour = dayStart + ((max(segStart, dayStart) - dayStart) / chunkLength).rounded(.down) * chunkLength
        if hour != chunkStart {
            var cm = chunk(at: hour)
            while cm.isEmpty && hour + chunkLength < dayEnd {
                hour += chunkLength
                cm = chunk(at: hour)
            }
            guard let first = cm.spans.first, let last = cm.spans.last else { return }
            chunkStart = hour
            chunkMap = cm
            player.load(client.vodURL(camera: camera, start: first.wallStart, end: last.wallEnd),
                        startAt: cm.playerTime(for: target), autoplay: autoplay)
            return
        }
        player.seek(to: chunkMap.playerTime(for: target), precise: earlier == 0, earlier: earlier)
        if autoplay { player.play() }
    }
}

// MARK: - Timeline

/// Vertical timeline, newest at the top, with motion as bar widths and events as tinted rows.
/// Dragging scrubs the playhead, which sits in the vertical center.
struct PlaybackTimeline: View {
    let dayStart: Double
    let dayEnd: Double
    let wallTime: Double
    let motion: [MotionActivity]
    let reviews: [ReviewItem]
    let map: RecordingMap
    let isFollowing: Bool
    /// Seconds from event times to the recording (the camera's annotation offset).
    var annotationOffset: Double = 0
    /// A tap on an event in the strip or on its label.
    var onSelect: (ReviewItem) -> Void = { _ in }
    /// Recording segments, sorted by start. Zoomed in, motion comes from these: each carries
    /// its own motion at its exact time, where Frigate's activity buckets round a segment
    /// down to the bucket it starts in and so drew motion up to ten seconds early.
    var segments: [RecordingSegment] = []
    let onScrub: (Double) -> Void
    /// Release time plus a snap window in seconds (about 24 points at the current zoom).
    let onScrubEnd: (Double, Double) -> Void
    /// A drag that turned out to be part of a tap on an event: drop it without seeking.
    var onScrubCancel: () -> Void = {}
    /// Narrow column without events (motion review on the phone): no event strip, the bars
    /// use the full width right of the labels, and a short time on the playhead.
    var compact = false

    /// Seconds per row.
    @State private var zoomIndex = 2
    @State private var dragStartTime: Double?
    @State private var fling = TimelineFling()
    /// Where a trackpad scroll has got to.
    @State private var scrollTime: Double?
    /// When an event was last tapped. A tap that moves a little also ends a drag, which must
    /// not then seek back to where the finger started.
    @State private var lastTap = Date.distantPast

    /// Zoomed in far enough that rows are shorter than the activity buckets.
    private var usesSegments: Bool { secondsPerRow <= 30 && !segments.isEmpty }

    /// Seconds per row; at the widest about three hours fit on screen.
    private let zooms: [Double] = [10, 30, 60, 120]
    private let rowHeight: CGFloat = 5

    private var secondsPerRow: Double { zooms[zoomIndex] }
    private var secondsPerPoint: Double { secondsPerRow / Double(rowHeight) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomTrailing) {
                Canvas { ctx, size in draw(ctx, size: size) }
                    .contentShape(Rectangle())
                    // Two fingers on a trackpad: the same as dragging, with the same follow-through.
                    .overlay {
                        TrackpadScroll(
                            onBegan: { fling.cancel(); dragStartTime = wallTime; scrollTime = wallTime },
                            onChanged: { p in
                                let t = clamp((dragStartTime ?? wallTime) + Double(p.y) * secondsPerPoint)
                                scrollTime = t
                                onScrub(t)
                            },
                            onEnded: { v in
                                let released = scrollTime ?? wallTime
                                dragStartTime = nil
                                scrollTime = nil
                                let snap = secondsPerPoint * 24
                                if abs(v.y) > TimelineFling.minimumSpeed {
                                    fling.start(from: released, velocity: Double(v.y) * secondsPerPoint, clamp: clamp,
                                                step: onScrub, end: { onScrubEnd($0, snap) })
                                } else {
                                    onScrubEnd(released, snap)
                                }
                            })
                    }
                    .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                        fling.cancel()
                        if let r = review(at: tap.location, size: geo.size) {
                            lastTap = Date()
                            onSelect(r)
                        }
                    })
                    .gesture(DragGesture(minimumDistance: 10)
                        .onChanged { v in
                            if dragStartTime == nil { fling.cancel() }
                            let base = dragStartTime ?? wallTime
                            if dragStartTime == nil { dragStartTime = base }
                            // Dragging down moves to later times (newest is on top).
                            onScrub(clamp(base + Double(v.translation.height) * secondsPerPoint))
                        }
                        .onEnded { v in
                            let base = dragStartTime ?? wallTime
                            dragStartTime = nil
                            if Date().timeIntervalSince(lastTap) < 0.5 { onScrubCancel(); return }
                            let released = clamp(base + Double(v.translation.height) * secondsPerPoint)
                            let snap = secondsPerPoint * 24
                            // A quick swipe keeps going, like scrolling.
                            if abs(v.velocity.height) > TimelineFling.minimumSpeed {
                                fling.start(from: released, velocity: Double(v.velocity.height) * secondsPerPoint, clamp: clamp,
                                            step: onScrub, end: { onScrubEnd($0, snap) })
                            } else {
                                onScrubEnd(released, snap)
                            }
                        })

                // Playhead
                HStack(spacing: 6) {
                    Rectangle().fill(Theme.accent).frame(height: 2)
                    Text(FrigateFormat.time(Date(timeIntervalSince1970: wallTime), seconds: !compact))
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(Theme.onColor)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 5))
                        .padding(.trailing, 8)
                }
                .padding(.leading, gutter)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .allowsHitTesting(false)

                VStack(spacing: 8) {
                    zoomButton("plus.magnifyingglass", "Zoom in", enabled: zoomIndex > 0) { zoomIndex -= 1 }
                    zoomButton("minus.magnifyingglass", "Zoom out", enabled: zoomIndex < zooms.count - 1) { zoomIndex += 1 }
                }
                .padding(12)
            }
        }
        .clipped()

    }

    private func clamp(_ t: Double) -> Double { min(max(t, dayStart), dayEnd) }

    /// The most motion in buckets that overlap `from..<to`; buckets are sorted by start time.
    private func maxMotion(in buckets: [MotionActivity], scale: Double, from: Double, to: Double) -> Double {
        var lo = 0, hi = buckets.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if buckets[mid].startTime > from - scale { hi = mid } else { lo = mid + 1 }
        }
        var best = 0.0
        var i = lo
        while i < buckets.count, buckets[i].startTime < to {
            best = max(best, buckets[i].motion ?? 0)
            i += 1
        }
        return best
    }

    /// Motion for one row: from the segments when zoomed in, else the day-wide buckets.
    /// `segmentFactor` scales segment values to the buckets on screen.
    private func motionLevel(from: Double, to: Double, segmentFactor: Double = 1) -> Double {
        guard usesSegments else { return maxMotion(in: motion, scale: 30, from: from, to: to) }
        return segmentMotion(from: from, to: to) * segmentFactor
    }

    private func segmentMotion(from: Double, to: Double) -> Double {
        // First segment that may end after `from` (segments last up to about ten seconds).
        var lo = 0, hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segments[mid].startTime > from - 20 { hi = mid } else { lo = mid + 1 }
        }
        var best = 0.0
        var i = lo
        while i < segments.count, segments[i].startTime < to {
            if segments[i].endTime > from { best = max(best, segments[i].motion ?? 0) }
            i += 1
        }
        return best
    }

    private func zoomButton(_ icon: String, _ label: LocalizedStringKey, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17))
                .foregroundStyle(Theme.text)
                .frame(width: 44, height: 44)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.controlBorder, lineWidth: 1))
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }

    // MARK: Event strip

    private var gutter: CGFloat { compact ? 60 : 64 }
    /// The strip of event blocks just right of the time labels; motion bars start after it.
    private let stripWidth: CGFloat = 18
    private var barsStart: CGFloat { compact ? gutter + 2 : gutter + stripWidth + 6 }

    /// Where an event sits on screen, newest on top: from its end down to its start.
    private func span(of r: ReviewItem, center: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        let start = r.startTime + annotationOffset
        let end = (r.endTime ?? dayEnd) + annotationOffset
        let top = center + CGFloat((wallTime - end) / secondsPerPoint)
        let bottom = center + CGFloat((wallTime - start) / secondsPerPoint)
        // Short events still get a block big enough for their icon and a finger.
        return bottom - top < stripWidth ? (bottom - stripWidth, bottom) : (top, bottom)
    }

    /// The event under a tap on the strip.
    private func review(at p: CGPoint, size: CGSize) -> ReviewItem? {
        guard p.x >= gutter - 10, p.x <= barsStart + 4 else { return nil }
        let center = size.height / 2
        return reviews
            .map { (r: $0, s: span(of: $0, center: center)) }
            .filter { p.y >= $0.s.top - 6 && p.y <= $0.s.bottom + 6 }
            .min { abs(($0.s.top + $0.s.bottom) / 2 - p.y) < abs(($1.s.top + $1.s.bottom) / 2 - p.y) }?.r
    }

    /// Event blocks in the strip, as long as the event lasted, with the label icon on top.
    private func drawEvents(_ ctx: GraphicsContext, size: CGSize) {
        let center = size.height / 2
        var lastIconY = -CGFloat.infinity
        // Top (newest) first, so an icon that would overlap the one above is left out.
        for r in reviews.sorted(by: { $0.startTime > $1.startTime }) {
            let s = span(of: r, center: center)
            guard s.bottom > 0, s.top < size.height else { continue }
            let label = r.labels.first ?? ""
            let color = Theme.labelColor(label)
            let block = CGRect(x: gutter, y: s.top, width: stripWidth, height: s.bottom - s.top)
            ctx.fill(Path(roundedRect: block, cornerRadius: 5), with: .color(color.opacity(r.severity == .alert ? 1 : 0.8)))
            guard s.top - lastIconY >= stripWidth + 2 else { continue }
            lastIconY = s.top
            let box = CGRect(x: gutter, y: s.top, width: stripWidth, height: stripWidth)
            if let symbol = LabelIcon.symbol(for: label) {
                var img = ctx.resolve(Image(systemName: symbol))
                img.shading = .color(Theme.onLabel)
                let scale = 11 / max(img.size.width, img.size.height)
                let w = img.size.width * scale, h = img.size.height * scale
                ctx.draw(img, in: CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h))
            } else {
                // No icon for this label: its first letter.
                let letter = ctx.resolve(Text(String(FrigateFormat.labelName(label).prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .bold)).foregroundColor(Theme.onLabel))
                ctx.draw(letter, at: CGPoint(x: box.midX, y: box.midY))
            }
        }
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize) {
        let center = size.height / 2
        let barAreaWidth = compact ? size.width - barsStart - 6 : size.width - gutter - barsStart
        let rows = Int(size.height / rowHeight) + 2
        // Align rows to bucket boundaries so they do not shimmer while playing.
        let topTime = wallTime + Double(center) * secondsPerPoint
        let topRowTime = (topTime / secondsPerRow).rounded(.up) * secondsPerRow
        let dayMax = max(motion.map { $0.motion ?? 0 }.max() ?? 1, 1)
        // Segment and bucket motion use different units: match the busiest segment on screen
        // to the busiest bucket on screen, so zooming in keeps the bars about as wide.
        let visibleFrom = wallTime - Double(size.height - center) * secondsPerPoint
        let visibleTo = wallTime + Double(center) * secondsPerPoint
        var segmentFactor = 1.0
        if usesSegments {
            let seg = segmentMotion(from: visibleFrom, to: visibleTo)
            let coarse = maxMotion(in: motion, scale: 30, from: visibleFrom, to: visibleTo)
            segmentFactor = seg > 0 && coarse > 0 ? coarse / seg : 1
        }
        let labelEvery = labelInterval()

        for i in 0..<rows {
            let rowEnd = topRowTime - Double(i) * secondsPerRow
            let rowStart = rowEnd - secondsPerRow
            let rowY = center + CGFloat((wallTime - rowEnd) / secondsPerPoint)
            guard rowY > -rowHeight, rowY < size.height else { continue }
            guard rowEnd > dayStart, rowStart < dayEnd else { continue }

            // Fade rows near the edges.
            let edge = min(rowY, size.height - rowY) / 40
            let opacity = min(1, max(0.25, Double(edge)))
            var row = ctx
            row.opacity = opacity

            // Blue line along the left edge where video was recorded, so gaps are visible.
            if map.hasRecording(from: rowStart, to: rowEnd) {
                row.fill(Path(CGRect(x: gutter - 7, y: rowY, width: 3, height: rowHeight)), with: .color(Theme.accent.opacity(0.7)))
            }
            // Bar width follows the motion in this row; events add their label color and a tint.
            let level = motionLevel(from: rowStart, to: rowEnd, segmentFactor: segmentFactor)
            let motionWidth = CGFloat(min(1, level / dayMax)) * barAreaWidth * 0.9
            if let r = reviews.first(where: { rowEnd > $0.startTime && rowStart < ($0.endTime ?? dayEnd) }) {
                let color = Theme.labelColor(r.labels.first ?? "")
                row.fill(Path(CGRect(x: barsStart, y: rowY, width: barAreaWidth, height: rowHeight)), with: .color(color.opacity(0.08)))
                let w = max(motionWidth, 14)
                row.fill(Path(roundedRect: CGRect(x: barsStart + (barAreaWidth - w) / 2, y: rowY + 1, width: w, height: 3), cornerRadius: 1.5),
                         with: .color(color))
            } else if map.hasRecording(from: rowStart, to: rowEnd) {
                let w = max(4, motionWidth)
                row.fill(Path(roundedRect: CGRect(x: barsStart + (barAreaWidth - w) / 2, y: rowY + 1, width: w, height: 3), cornerRadius: 1.5),
                         with: .color(level > 0 ? Theme.motion : Theme.controlBorder))
            }

            // Ticks and labels
            let t = Int(rowEnd.rounded())
            if t % Int(labelEvery) == 0 {
                row.fill(Path(CGRect(x: 0, y: rowY + 2, width: 14, height: 1)), with: .color(Color(hex: 0x6B7480)))
                let text = Text(FrigateFormat.time(Date(timeIntervalSince1970: rowEnd)))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(Theme.textSecondary)
                row.draw(text, at: CGPoint(x: 20, y: rowY + 2), anchor: .leading)
            } else if t % Int(labelEvery / 3) == 0 {
                row.fill(Path(CGRect(x: 0, y: rowY + 2, width: 7, height: 1)), with: .color(Color(hex: 0x6B7480)))
            }
        }
        drawEvents(ctx, size: size)
    }

    /// Seconds between labeled ticks for the current zoom.
    private func labelInterval() -> Double {
        switch secondsPerRow {
        case ..<15: return 300
        case ..<45: return 900
        case ..<90: return 900
        case ..<200: return 1800
        default: return 3600
        }
    }
}

// MARK: - Landscape

extension PlaybackView {
    /// Full-screen video. A tap shows or hides the overlay; it hides by itself after 4 seconds
    /// of playback without touches.
    var landscapeBody: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerLayerView(player: player.player)
                .zoomable()
                .overlay { if gapTime != nil && !preview.showing { gapPlaceholder } }
                .overlay { if preview.showing { PreviewSurface(preview: preview) } }
                .ignoresSafeArea()
                .onTapGesture { toggleOverlay() }
                // With a mouse (Mac, iPad with trackpad) the controls come back when the pointer
                // moves over the video; a click or tap toggles them as on a touch screen.
                .onContinuousHover { phase in
                    guard case .active = phase else { return }
                    if !overlayVisible { withAnimation(.easeOut(duration: 0.25)) { overlayVisible = true } }
                    keepOverlay()
                }
            if loading {
                ProgressView().tint(.white)
            } else if map.isEmpty {
                Text("No recordings for \(FrigateFormat.dayTitle(day).lowercased())")
                    .font(.system(size: 14)).foregroundStyle(.white.opacity(0.8))
            } else if player.isBuffering {
                ProgressView().tint(.white)
            }
            landscapeOverlay.fadingControls(overlayVisible)
            if showEventsPanel {
                HStack(spacing: 0) {
                    Spacer()
                    landscapeEventsPanel
                }
                .transition(.move(edge: .trailing))
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onChange(of: player.rate) { _, _ in menuOpen = false; keepOverlay() }
        .onChange(of: camera) { _, _ in menuOpen = false; keepOverlay() }
        .onChange(of: exporter.isWorking) { _, _ in menuOpen = false; keepOverlay() }
        .task(id: overlayToken) {
            // Auto-hide while playing.
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, player.wantsToPlay, !showEventsPanel, scrubTime == nil else { return }
            // Keep the overlay while one of its menus is open; check again later.
            if menuOpen || MenuPresence.isShowing { menuOpen = false; overlayToken += 1; return }
            if pointerOnControls { overlayToken += 1; return }
            withAnimation(.easeOut(duration: 0.25)) { overlayVisible = false }
        }
    }

    private func toggleOverlay() {
        menuOpen = false
        withAnimation(.easeOut(duration: 0.2)) {
            if showEventsPanel { showEventsPanel = false; return }
            overlayVisible.toggle()
        }
        overlayToken += 1
    }

    private func keepOverlay() { overlayToken += 1 }

    func setFullscreen(_ on: Bool) {
        if !isWide {
            // iPhone: full screen is the landscape view; turn the screen for it.
            fullscreen = on
            rotate(to: on ? .landscapeRight : .portrait)
            keepOverlay()
            return
        }
        withAnimation(.easeInOut(duration: 0.3)) { fullscreen = on; model.immersive = on }
        keepOverlay()
    }

    private func rotate(to orientation: UIInterfaceOrientationMask) {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { _ in }
        }
    }

    private var landscapeOverlay: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 12) {
                if fullscreen {
                    FullscreenButton(isOn: true, size: 40) { setFullscreen(false) }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Back")
                }
                Stable(key: [camera, conn?.server.name ?? ""] + (conn?.cameras.map(\.name) ?? [])) { cameraMenu }.stable()
                    .simultaneousGesture(TapGesture().onEnded { menuOpen = true; keepOverlay() })
                Spacer()
                timeLabel
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.55), in: Capsule())
                ForEach(currentReview?.labels ?? [], id: \.self) { LabelIcon(label: $0, size: 26) }
                Button { showDatePicker = true; keepOverlay() } label: {
                    Image(systemName: "calendar").font(.system(size: 19)).foregroundStyle(Theme.text).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Pick date")
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8)
            // Mac full screen: below the window buttons, which sit in the top-left corner.
            .padding(.top, fullscreen && ProcessInfo.processInfo.isMacCatalystApp ? 26 : 0)
            .background(Color.black.opacity(0.55).ignoresSafeArea(edges: [.top, .horizontal]))
            .pointerOver($pointerOnControls)

            // Middle: play controls centered, side buttons on the right.
            ZStack {
                HStack(spacing: 18) {
                    OverlayButton(systemImage: "gobackward.10", size: 50, label: "Back 10 seconds") { player.skip(-10); keepOverlay() }
                    OverlayButton(systemImage: player.wantsToPlay ? "pause.fill" : "play.fill", size: 60,
                                  label: player.wantsToPlay ? "Pause" : "Play") { togglePlay(); keepOverlay() }
                    OverlayButton(systemImage: "goforward.10", size: 50, label: "Forward 10 seconds") { player.skip(10); keepOverlay() }
                }
                .pointerOver($pointerOnControls)
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        OverlayButton(systemImage: "list.bullet", label: "Events") {
                            withAnimation(.easeOut(duration: 0.2)) { showEventsPanel = true }
                            keepOverlay()
                        }
                        saveMenu.scaleEffect(44 / 36)
                            .simultaneousGesture(TapGesture().onEnded { menuOpen = true; keepOverlay() })
                        speedMenu
                            .simultaneousGesture(TapGesture().onEnded { menuOpen = true; keepOverlay() })
                    }
                    .pointerOver($pointerOnControls)
                    .padding(.trailing, 12)
                }
            }
            .frame(maxHeight: .infinity)

            // Bottom: horizontal timeline.
            ZStack(alignment: .top) {
                HorizontalTimeline(dayStart: dayStart, dayEnd: dayEnd, wallTime: wallTime, motion: motion,
                                   reviews: visibleReviews, map: map,
                                   onScrub: { heldTime = nil; scrubTime = $0; preview.show($0 - annotationOffset) },
                                   onScrubEnd: { t, snap in
                                       finishScrub(at: t, snap: snap)
                                       keepOverlay()
                                   },
                                   onInteract: keepOverlay,
                                   onScrubCancel: { scrubTime = nil; preview.hide() },
                                   onSelect: { jump(toWall: $0.startTime - 1 + annotationOffset, autoplay: true, earlier: 2); keepOverlay() },
                                   scale: $timelineScale)
                    .padding(.top, 6)
                Rectangle().fill(Theme.accent).frame(width: 2, height: 74).allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                HStack(spacing: 16) {
                    Button { timelineScale = min(timelineScale * 2, HorizontalTimeline.maxScale); keepOverlay() } label: {
                        Image(systemName: "minus.magnifyingglass").font(.system(size: 18))
                    }
                    .accessibilityLabel("Zoom out")
                    Button { timelineScale = max(timelineScale / 2, HorizontalTimeline.minScale); keepOverlay() } label: {
                        Image(systemName: "plus.magnifyingglass").font(.system(size: 18))
                    }
                    .accessibilityLabel("Zoom in")
                    Spacer()
                    Button {
                        model.tab = .live
                        model.livePath = NavigationPath()
                        model.livePath.append(CameraRoute(serverID: route.serverID, camera: camera))
                    } label: {
                        Text("Live").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .overlay(Capsule().stroke(Theme.accent, lineWidth: 1))
                    }
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 12)
                .offset(y: 30)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 34)
            .background(Color.black.opacity(0.6).ignoresSafeArea(edges: [.bottom, .horizontal]))
            .pointerOver($pointerOnControls)
        }
    }

    private var landscapeEventsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: loading && reviews.isEmpty ? L("Events") : L("\(visibleReviews.count) events")).lineLimit(1)
                Button { withAnimation(.easeOut(duration: 0.2)) { showEventsPanel = false } } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).frame(width: 32, height: 32)
                }
                .accessibilityLabel("Close")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(visibleReviews) { r in
                            let playing = currentReview?.id == r.id
                            Button {
                                jump(toWall: r.startTime - 1 + annotationOffset, autoplay: true, earlier: 2)
                                keepOverlay()
                            } label: {
                                HStack(spacing: 10) {
                                    RemoteImage(url: client?.thumbnailURL(for: r), session: client?.session ?? .shared)
                                        .frame(width: 64, height: 36)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 4) { ForEach(r.labels, id: \.self) { LabelIcon(label: $0, size: 18) } }
                                        Text(FrigateFormat.time(r.start, seconds: true)).font(.system(size: 13, weight: .semibold))
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(6)
                                .card(border: playing ? Theme.accent : Theme.cardBorder, radius: 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(r.id)
                            .contextMenu { ReviewItemMenu(item: r, serverID: route.serverID, actions: reviewActions) }
                        }
                    }
                }
                .onAppear { if let id = currentReview?.id { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .foregroundStyle(Theme.text)
        .padding(12)
        .frame(width: 236)
        .frame(maxHeight: .infinity)
        .background(Theme.card.opacity(0.97).ignoresSafeArea())
    }
}

/// What the event list shows; it is redrawn only when this changes.
private struct EventsListKey: Equatable {
    let ids: [String]
    let total: Int
    let playing: String?
    let loading: Bool
    let recorded: Int
    let filtered: Bool
    let day: Date
}

/// A loading spinner that stands out on any picture: large, on a dark disc.
struct VideoSpinner: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        // Large only where the video is large (iPad, Mac); on an iPhone it covered the picture.
        let large = sizeClass == .regular
        ProgressView()
            .controlSize(large ? .large : .regular)
            .tint(.white)
            .frame(width: large ? 64 : 36, height: large ? 64 : 36)
            .background(.black.opacity(0.55), in: Circle())
    }
}
