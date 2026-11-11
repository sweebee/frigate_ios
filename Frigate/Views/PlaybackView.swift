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
    private var wallTime: Double { scrubTime ?? (chunkMap.isEmpty ? dayStart : chunkMap.wallTime(for: player.currentTime)) }

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

    var body: some View {
        VStack(spacing: 0) {
            header
            videoPlayer
            progressBar
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
                                 onScrub: { scrubTime = $0 },
                                 onScrubEnd: { t in
                                     scrubTime = nil
                                     seek(toWall: t, autoplay: player.wantsToPlay)
                                 })
            }
        }
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) { ExportToast(state: exporter.state) }
        .sheet(item: $share) { ShareSheet(items: $0.items) }
        .sheet(isPresented: $showDatePicker) {
            RecordingCalendarSheet(day: $day, sources: client.map { [(client: $0, cameras: Optional([camera]))] } ?? [])
        }
        .task(id: "\(camera)|\(day.timeIntervalSince1970)") { await load() }
        .onDisappear { player.stop() }
        .onChange(of: player.finishedCount) { _, _ in
            // Continue with the next hour that has recordings.
            guard let chunkStart else { return }
            let next = chunkStart + chunkLength
            if next < dayEnd { seek(toWall: next, autoplay: true) }
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
                    Text("\(FrigateFormat.dayTitle(Date(timeIntervalSince1970: wallTime))) · \(FrigateFormat.time(Date(timeIntervalSince1970: wallTime), seconds: true))")
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
            if !map.isEmpty { saveMenu.padding(10) }
        }
        .overlay(alignment: .bottom) {
            if !map.isEmpty {
                HStack(spacing: 10) {
                    OverlayButton(systemImage: "gobackward.10", label: "Back 10 seconds") { player.skip(-10) }
                    OverlayButton(systemImage: player.wantsToPlay ? "pause.fill" : "play.fill", label: player.wantsToPlay ? "Pause" : "Play") { player.toggle() }
                    OverlayButton(systemImage: "goforward.10", label: "Forward 10 seconds") { player.skip(10) }
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

    private func rateTitle(_ r: Float) -> String { r == 0.5 ? "½x" : "\(Int(r))x" }

    private var progressBar: some View {
        GeometryReader { geo in
            let total = max(dayEnd - dayStart, 1)
            let p = (wallTime - dayStart) / total
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.controlBorder)
                Rectangle().fill(Theme.accent).frame(width: geo.size.width * max(0, min(1, p)))
            }
        }
        .frame(height: 3)
    }

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
                                        Text(FrigateFormat.duration(r.duration))
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
        chunkStart = nil
        chunkMap = RecordingMap()
        loading = false
        guard let last = map.spans.last else { return }

        // Start playing right away: at the requested review item, else the latest event, else near the end.
        if let id = pendingReviewID, let item = reviews.first(where: { $0.id == id }) {
            seek(toWall: item.startTime - 3 + annotationOffset, autoplay: true)
        } else if let latest = reviews.first {
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
    private func seek(toWall t: Double, autoplay: Bool) {
        guard let client, !map.isEmpty else { return }
        // Skip gaps: move to the next moment with a recording.
        var target = t
        if !map.hasRecording(at: target), let next = map.spans.first(where: { $0.wallStart > target }) { target = next.wallStart }
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
    let onScrubEnd: (Double) -> Void

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
                            onScrubEnd(clamp(base + Double(v.translation.height) * secondsPerPoint))
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

            // Bar width follows the motion in this row; events add their label color and a tint.
            let level = motion.filter { $0.startTime >= rowStart - 15 && $0.startTime < rowEnd }.map { $0.motion ?? 0 }.max() ?? 0
            let motionWidth = CGFloat(level / maxMotion) * barAreaWidth * 0.9
            if let r = reviews.first(where: { rowEnd > $0.startTime && rowStart < ($0.endTime ?? dayEnd) }) {
                let color = Theme.labelColor(r.labels.first ?? "")
                row.fill(Path(CGRect(x: gutter, y: rowY, width: barAreaWidth, height: rowHeight)), with: .color(color.opacity(0.14)))
                let w = max(motionWidth, 14)
                row.fill(Path(roundedRect: CGRect(x: gutter + (barAreaWidth - w) / 2, y: rowY + 1, width: w, height: 3), cornerRadius: 1.5),
                         with: .color(color))
            } else if map.hasRecording(at: (rowStart + rowEnd) / 2) {
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
