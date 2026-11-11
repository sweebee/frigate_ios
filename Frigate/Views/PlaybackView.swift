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

    /// Whether any recording overlaps `start..<end`.
    func hasRecording(from start: Double, to end: Double) -> Bool {
        spans.contains { $0.wallStart < end && $0.wallEnd > start }
    }

    func hasRecording(at wall: Double) -> Bool {
        spans.contains { wall >= $0.wallStart && wall <= $0.wallEnd }
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
    // Landscape playback state.
    @State private var overlayVisible = true
    @State private var showEventsPanel = false
    @State private var overlayToken = 0
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

    init(route: PlaybackRoute) {
        self.route = route
        _camera = State(initialValue: route.camera)
        _day = State(initialValue: route.day)
        _pendingReviewID = State(initialValue: route.reviewID)
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
        let t = snapToRecording(raw, within: snap)
        heldTime = t
        scrubTime = nil
        seek(toWall: t, autoplay: player.wantsToPlay)
        Task {
            // Release only once the player is ready and has reported a nearby position
            // on two checks in a row, so a new hour loading cannot flash its start.
            var steady = 0
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(150))
                if heldTime != t { return }
                let ready = player.duration > 0 && player.pendingStart == nil
                steady = ready && abs(playerWallTime - t) < 1.5 ? steady + 1 : 0
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
        let t = wallTime
        return visibleReviews.filter { $0.startTime - 5 <= t }.max { $0.startTime < $1.startTime }
    }

    private var currentReview: ReviewItem? {
        let t = wallTime
        return reviews.first { t >= $0.startTime - 5 && t <= ($0.endTime ?? .infinity) + 5 }
    }

    /// iPhone held sideways: full-screen video with an overlay, like an NVR app.
    private var isLandscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        Group {
            if isLandscape { landscapeBody } else { portraitBody }
        }
        .overlay(alignment: .top) { ExportToast(state: exporter.state) }
        .sheet(item: $share) { ShareSheet(items: $0.items) }
        .sheet(isPresented: $showDatePicker) {
            RecordingCalendarSheet(day: $day, sources: client.map { [(client: $0, cameras: Optional([camera]))] } ?? [])
        }
        .task(id: "\(camera)|\(day.timeIntervalSince1970)") { await load() }
        .onChange(of: player.wantsToPlay) { _, playing in
            // Paused: bring the controls back so it is clear the video is not stuck.
            if !playing { withAnimation(.easeOut(duration: 0.2)) { overlayVisible = true } }
            overlayToken += 1
        }
        .onDisappear { player.stop() }
        .onChange(of: player.finishedCount) { _, _ in
            // Continue with the next hour that has recordings.
            guard let chunkStart else { return }
            let next = chunkStart + chunkLength
            if next < dayEnd { seek(toWall: next, autoplay: true, skipGap: true) }
        }
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
                                 map: map, isFollowing: scrubTime == nil,
                                 onScrub: { heldTime = nil; scrubTime = $0; preview.show($0 - annotationOffset) },
                                 onScrubEnd: { t, snap in finishScrub(at: t, snap: snap) })
            }
        }
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: overlayToken) {
            // Hide the video controls after 4 seconds of playback without touches.
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, player.wantsToPlay, scrubTime == nil else { return }
            if menuOpen || MenuPresence.isShowing { menuOpen = false; overlayToken += 1; return }
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
                    Button { shareClip(r.startTime - 3, (r.endTime ?? Date().timeIntervalSince1970) + 3) } label: {
                        Label("Share event", systemImage: "square.and.arrow.up")
                    }
                }
            }
            Section("From the playhead") {
                ForEach([30.0, 60, 300], id: \.self) { secs in
                    Button { save(wallTime - secs / 2, wallTime + secs / 2) } label: {
                        Label(secs < 60 ? L("Save \(Int(secs)) seconds") : L("Save \(Int(secs / 60)) minutes"),
                              systemImage: "film")
                    }
                }
            }
        } label: {
            Image(systemName: exporter.isWorking ? "hourglass" : "square.and.arrow.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
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
                Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Back")
            Spacer()
            Stable(key: [camera, conn?.server.name ?? ""] + (conn?.cameras.map(\.name) ?? [])) { cameraMenu }.stable()
            Spacer()
            Button { showDatePicker = true } label: {
                Image(systemName: "calendar").font(.system(size: 19)).foregroundStyle(Theme.text).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Pick date")
        }
        .padding(.horizontal, 8)
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
                .overlay { if preview.showing { PlayerLayerView(player: preview.player) } }
                .onTapGesture { toggleOverlay() }
            if loading {
                ProgressView().tint(.white)
            } else if map.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "film.stack").font(.title2)
                    Text("No recordings for \(FrigateFormat.dayTitle(day).lowercased())").font(.system(size: 13))
                }
                .foregroundStyle(.white.opacity(0.8))
            } else if let error = player.error {
                Text(error).font(.system(size: 13)).foregroundStyle(.white).padding()
            } else if player.isBuffering {
                ProgressView().tint(.white)
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
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    if let r = currentReview, let label = r.labels.first {
                        LabelTag(label: label)
                    }
                }
                .padding(10)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !map.isEmpty && overlayVisible { saveMenu.padding(10).transition(.opacity) }
        }
        .overlay(alignment: .bottom) {
            if !map.isEmpty && overlayVisible {
                HStack(spacing: 10) {
                    OverlayButton(systemImage: "gobackward.10", label: "Back 10 seconds") { player.skip(-10); keepOverlay() }
                    OverlayButton(systemImage: player.wantsToPlay ? "pause.fill" : "play.fill", label: player.wantsToPlay ? "Pause" : "Play") { togglePlay(); keepOverlay() }
                    OverlayButton(systemImage: "goforward.10", label: "Forward 10 seconds") { player.skip(10); keepOverlay() }
                    Menu {
                        ForEach([Float(0.5), 1, 2, 4, 8], id: \.self) { r in
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
                .padding(10)
            }
        }
    }

    private var speedMenu: some View {
        Menu {
            ForEach([Float(0.5), 1, 2, 4, 8], id: \.self) { r in
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
                LazyVStack(alignment: .leading, spacing: 8) {
                    let shown = visibleReviews
                    SectionLabel(text: filter.isActive
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
                        let playing = currentReview?.id == r.id
                        Button { seek(toWall: r.startTime - 3 + annotationOffset, autoplay: true) } label: {
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
                                    HStack(spacing: 5) { ForEach(r.labels.prefix(3), id: \.self) { LabelTag(label: $0) } }
                                    Text(FrigateFormat.time(r.start, seconds: true)).font(.system(size: 14, weight: .semibold))
                                    let zones = (r.data.zones ?? []).map(FrigateFormat.prettyName)
                                    Text(zones.isEmpty ? (r.severity == .alert ? L("Alert") : L("Detection")) : L("Zone: \(zones.joined(separator: ", "))"))
                                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer(minLength: 0)
                                if playing {
                                    Text("Playing").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent).padding(.trailing, 6)
                                }
                            }
                            .padding(8)
                            .card(border: playing ? Theme.accent : Theme.cardBorder, radius: 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(r.id)
                        .contextMenu {
                            Button { save(r.startTime - 3, (r.endTime ?? Date().timeIntervalSince1970) + 3) } label: {
                                Label("Save video to Photos", systemImage: "square.and.arrow.down")
                            }
                            Button { shareClip(r.startTime - 3, (r.endTime ?? Date().timeIntervalSince1970) + 3) } label: {
                                Label("Share video", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
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
        async let revs = try? client.reviews(cameras: [camera], after: Date(timeIntervalSince1970: start), before: Date(timeIntervalSince1970: end), limit: 500)
        async let mot = try? client.motionActivity(cameras: [camera], after: Date(timeIntervalSince1970: start), before: Date(timeIntervalSince1970: end), scale: 30)
        let (s, r, m) = await (segs, revs, mot)
        reviews = (r ?? []).sorted { $0.startTime > $1.startTime }
        motion = m ?? []
        segments = (s ?? []).sorted { $0.startTime < $1.startTime }
        map = RecordingMap(segments: segments, from: start, to: end)
        await preview.prepare(client: client, camera: camera, start: start, end: end)
        chunkStart = nil
        chunkMap = RecordingMap()
        loading = false
        guard let last = map.spans.last else { return }

        // Start playing right away: at the requested review item, else the latest event, else near the end.
        if let id = pendingReviewID, let item = reviews.first(where: { $0.id == id }) {
            seek(toWall: item.startTime - 3 + annotationOffset, autoplay: true)
        } else if let latest = reviews.first(where: { map.hasRecording(at: $0.startTime + annotationOffset + 1) }) {
            seek(toWall: latest.startTime - 3 + annotationOffset, autoplay: true)
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

    private func seek(toWall t: Double, autoplay: Bool, skipGap: Bool = false) {
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
        player.seek(to: chunkMap.playerTime(for: target), precise: true)
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
    let onScrub: (Double) -> Void
    /// Release time plus a snap window in seconds (about 24 points at the current zoom).
    let onScrubEnd: (Double, Double) -> Void

    /// Seconds per row.
    @State private var zoomIndex = 2
    @State private var dragStartTime: Double?
    private let zooms: [Double] = [10, 30, 60, 120, 300]
    private let rowHeight: CGFloat = 5

    private var secondsPerRow: Double { zooms[zoomIndex] }
    private var secondsPerPoint: Double { secondsPerRow / Double(rowHeight) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomTrailing) {
                Canvas { ctx, size in draw(ctx, size: size) }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { v in
                            let base = dragStartTime ?? wallTime
                            if dragStartTime == nil { dragStartTime = base }
                            // Dragging down moves to later times (newest is on top).
                            onScrub(clamp(base + Double(v.translation.height) * secondsPerPoint))
                        }
                        .onEnded { v in
                            let base = dragStartTime ?? wallTime
                            dragStartTime = nil
                            onScrubEnd(clamp(base + Double(v.translation.height) * secondsPerPoint), secondsPerPoint * 24)
                        })

                // Playhead
                HStack(spacing: 6) {
                    Rectangle().fill(Theme.accent).frame(height: 2)
                    Text(FrigateFormat.time(Date(timeIntervalSince1970: wallTime), seconds: true))
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.onColor)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 5))
                        .padding(.trailing, 8)
                }
                .padding(.leading, 64)
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

    private func draw(_ ctx: GraphicsContext, size: CGSize) {
        let gutter: CGFloat = 64
        let center = size.height / 2
        let barAreaWidth = size.width - gutter * 2
        let rows = Int(size.height / rowHeight) + 2
        // Align rows to bucket boundaries so they do not shimmer while playing.
        let topTime = wallTime + Double(center) * secondsPerPoint
        let topRowTime = (topTime / secondsPerRow).rounded(.up) * secondsPerRow
        let maxMotion = max(motion.map { $0.motion ?? 0 }.max() ?? 1, 1)
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
            let level = motion.filter { $0.startTime >= rowStart - 15 && $0.startTime < rowEnd }.map { $0.motion ?? 0 }.max() ?? 0
            let motionWidth = CGFloat(level / maxMotion) * barAreaWidth * 0.9
            if let r = reviews.first(where: { rowEnd > $0.startTime && rowStart < ($0.endTime ?? dayEnd) }) {
                let color = Theme.labelColor(r.labels.first ?? "")
                row.fill(Path(CGRect(x: gutter, y: rowY, width: barAreaWidth, height: rowHeight)), with: .color(color.opacity(0.14)))
                let w = max(motionWidth, 14)
                row.fill(Path(roundedRect: CGRect(x: gutter + (barAreaWidth - w) / 2, y: rowY + 1, width: w, height: 3), cornerRadius: 1.5),
                         with: .color(color))
            } else if map.hasRecording(from: rowStart, to: rowEnd) {
                let w = max(4, motionWidth)
                row.fill(Path(roundedRect: CGRect(x: gutter + (barAreaWidth - w) / 2, y: rowY + 1, width: w, height: 3), cornerRadius: 1.5),
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
                .overlay { if preview.showing { PlayerLayerView(player: preview.player) } }
                .ignoresSafeArea()
                .onTapGesture { toggleOverlay() }
            if loading {
                ProgressView().tint(.white)
            } else if map.isEmpty {
                Text("No recordings for \(FrigateFormat.dayTitle(day).lowercased())")
                    .font(.system(size: 14)).foregroundStyle(.white.opacity(0.8))
            } else if player.isBuffering {
                ProgressView().tint(.white)
            }
            if overlayVisible {
                landscapeOverlay.transition(.opacity)
            } else {
                VStack {
                    Spacer()
                    GeometryReader { geo in
                        let p = max(0, min(1, (wallTime - dayStart) / max(dayEnd - dayStart, 1)))
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.15))
                            Rectangle().fill(Theme.accent).frame(width: geo.size.width * p)
                        }
                    }
                    .frame(height: 3)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
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

    private var landscapeOverlay: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Back")
                Stable(key: [camera, conn?.server.name ?? ""] + (conn?.cameras.map(\.name) ?? [])) { cameraMenu }.stable()
                    .simultaneousGesture(TapGesture().onEnded { menuOpen = true; keepOverlay() })
                Spacer()
                timeLabel
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.55), in: Capsule())
                if let r = currentReview, let label = r.labels.first { LabelTag(label: label) }
                Button { showDatePicker = true; keepOverlay() } label: {
                    Image(systemName: "calendar").font(.system(size: 19)).foregroundStyle(Theme.text).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Pick date")
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8)
            .background(Color.black.opacity(0.55).ignoresSafeArea(edges: [.top, .horizontal]))

            // Middle: play controls centered, side buttons on the right.
            ZStack {
                HStack(spacing: 18) {
                    OverlayButton(systemImage: "gobackward.10", size: 50, label: "Back 10 seconds") { player.skip(-10); keepOverlay() }
                    OverlayButton(systemImage: player.wantsToPlay ? "pause.fill" : "play.fill", size: 60,
                                  label: player.wantsToPlay ? "Pause" : "Play") { togglePlay(); keepOverlay() }
                    OverlayButton(systemImage: "goforward.10", size: 50, label: "Forward 10 seconds") { player.skip(10); keepOverlay() }
                }
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
                                   scale: $timelineScale)
                    .padding(.top, 6)
                Rectangle().fill(Theme.accent).frame(width: 2, height: 52).allowsHitTesting(false)
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
        }
    }

    private var landscapeEventsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: L("\(visibleReviews.count) events")).lineLimit(1)
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
                                seek(toWall: r.startTime - 3 + annotationOffset, autoplay: true)
                                keepOverlay()
                            } label: {
                                HStack(spacing: 10) {
                                    RemoteImage(url: client?.thumbnailURL(for: r), session: client?.session ?? .shared)
                                        .frame(width: 64, height: 36)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 4) { ForEach(r.labels.prefix(1), id: \.self) { LabelTag(label: $0) } }
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
