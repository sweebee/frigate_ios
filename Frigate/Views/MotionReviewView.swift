import SwiftUI

/// Review's Motion tab, like Frigate's: every camera's preview at one shared moment, with the
/// motion of all cameras on a timeline beside them. Dragging the timeline or playing (fast by
/// default) moves every preview together; cameras with motion at that moment get a border. A
/// tap on a camera opens its recording at that moment.
struct MotionReviewView: View {
    let connections: [ServerConnection]
    let cameraFilter: Set<String>
    /// The period to review: the last 24 hours, or a day.
    let start: Double
    let end: Double

    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The shared moment every preview shows.
    @State private var wallTime = Date().timeIntervalSince1970 - 30
    @State private var rangeStart = Date().timeIntervalSince1970 - 86400
    @State private var rangeEnd = Date().timeIntervalSince1970
    @State private var previews: [String: PreviewScrubber] = [:]
    /// Motion buckets per camera ("server/camera"), oldest first.
    @State private var activity: [String: [MotionActivity]] = [:]
    /// All cameras' motion together, for the timeline.
    @State private var combined: [MotionActivity] = []
    @State private var loading = true
    @State private var playing = false
    @State private var rate: Double = 8
    private let bucket: Double = 30

    private struct Cam: Identifiable {
        let conn: ServerConnection
        let camera: CameraConfig
        let id: String
    }

    private var cams: [Cam] {
        connections.flatMap { conn in
            conn.cameras.filter { cameraFilter.isEmpty || cameraFilter.contains($0.name) }.map { Cam(conn: conn, camera: $0, id: "\(conn.server.id)/\($0.name)") }
        }
    }

    private var isWide: Bool { sizeClass == .regular }

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: isWide ? 260 : 150), spacing: 10)], spacing: 10) {
                        ForEach(cams) { cam in tile(cam) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    // Room for the controls floating at the bottom.
                    .padding(.bottom, 90)
                }
                controls.padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            PlaybackTimeline(dayStart: rangeStart, dayEnd: rangeEnd, wallTime: wallTime, motion: combined, reviews: [],
                             map: fullMap, isFollowing: !playing,
                             onScrub: { t in playing = false; move(to: t) },
                             onScrubEnd: { t, _ in move(to: t) })
                .frame(width: isWide ? 220 : 150)
                .background(Theme.card.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.trailing, isWide ? 16 : 8)
                .padding(.vertical, 8)
                .overlay { if loading && combined.isEmpty { ProgressView() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: cams.map(\.id) + ["\(start)-\(end)"]) { await load() }
        .task(id: playing) { await play() }
        .onDisappear { playing = false }
    }

    // MARK: Tiles

    private func tile(_ cam: Cam) -> some View {
        let preview = previews[cam.id]
        let active = hasMotion(cam.id, at: wallTime)
        return NavigationLink(value: PlaybackRoute(serverID: cam.conn.server.id, camera: cam.camera.name,
                                                   day: Calendar.current.startOfDay(for: Date(timeIntervalSince1970: wallTime)),
                                                   startTime: wallTime)) {
            Color.black
                .aspectRatio(cam.camera.aspectRatio, contentMode: .fit)
                .overlay {
                    if let preview, preview.showing {
                        PreviewSurface(preview: preview)
                    } else if !loading {
                        Text("No preview")
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 6) {
                        if connections.count > 1 { ServerBadge(initial: cam.conn.server.initial, tint: cam.conn.server.tint) }
                        Text(cam.camera.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(active ? Theme.motion : Theme.cardBorder, lineWidth: active ? 3 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(cam.camera.displayName))
    }

    /// Motion in the bucket around `t` for one camera.
    private func hasMotion(_ id: String, at t: Double) -> Bool {
        guard let list = activity[id], !list.isEmpty else { return false }
        // Last bucket starting at or before t (binary search; the list is sorted).
        var lo = 0, hi = list.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if list[mid].startTime <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0, t - list[found].startTime < bucket else { return false }
        return (list[found].motion ?? 0) > 0
    }

    // MARK: Controls

    /// The same round buttons as the playback screens.
    private var controls: some View {
        let size: CGFloat = isWide ? 56 : 44
        return HStack(spacing: isWide ? 16 : 10) {
            OverlayButton(systemImage: "gobackward.10", size: size, label: "Back 10 seconds") { move(to: wallTime - 10) }
            OverlayButton(systemImage: playing ? "pause.fill" : "play.fill", size: isWide ? 64 : 44, label: playing ? "Pause" : "Play") {
                // At the end: start ten minutes back.
                if !playing && wallTime >= rangeEnd - 5 { move(to: rangeEnd - 600) }
                playing.toggle()
            }
            OverlayButton(systemImage: "goforward.10", size: size, label: "Forward 10 seconds") { move(to: wallTime + 10) }
            Menu {
                ForEach([4.0, 8, 12, 16], id: \.self) { r in
                    Button { rate = r } label: {
                        if rate == r { Label("\(Int(r))x", systemImage: "checkmark") } else { Text("\(Int(r))x") }
                    }
                }
            } label: {
                Text("\(Int(rate))x")
                    .font(.system(size: isWide ? 16 : 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(.black.opacity(0.6), in: Circle())
            }
            .accessibilityLabel("Playback speed")
        }
    }

    // MARK: Time

    /// The timeline draws motion only where it has recordings; here it covers the whole range.
    private var fullMap: RecordingMap {
        var map = RecordingMap()
        map.spans = [.init(wallStart: rangeStart, wallEnd: rangeEnd, offset: 0)]
        return map
    }

    private func move(to t: Double) {
        wallTime = min(max(t, rangeStart), rangeEnd)
        for p in previews.values { p.show(wallTime) }
    }

    /// Steps the shared moment forward while playing, `rate` seconds per second.
    private func play() async {
        guard playing else { return }
        let tick = 0.25
        while playing && !Task.isCancelled {
            try? await Task.sleep(for: .seconds(tick))
            guard playing else { return }
            if wallTime + tick * rate >= rangeEnd { move(to: rangeEnd); playing = false; return }
            move(to: wallTime + tick * rate)
        }
    }

    // MARK: Loading

    private func load() async {
        loading = true
        let now = min(end, Date().timeIntervalSince1970)
        // A new period starts at its end (most recent).
        if rangeStart != start || wallTime > now || wallTime < start { wallTime = now - 30 }
        rangeEnd = now
        rangeStart = start
        var made: [String: PreviewScrubber] = [:]
        for cam in cams { made[cam.id] = previews[cam.id] ?? PreviewScrubber() }
        previews = made

        await withTaskGroup(of: Void.self) { group in
            for cam in cams {
                guard let client = cam.conn.client, let preview = made[cam.id] else { continue }
                let start = rangeStart - 3600
                group.addTask { await preview.prepare(client: client, camera: cam.camera.name, start: start, end: now) }
            }
            // Motion per server, every camera at once.
            for conn in connections {
                guard let client = conn.client else { continue }
                let names = conn.cameras.filter { cameraFilter.isEmpty || cameraFilter.contains($0.name) }.map(\.name)
                let serverID = conn.server.id
                let from = Date(timeIntervalSince1970: rangeStart), to = Date(timeIntervalSince1970: now)
                group.addTask {
                    let byCamera = await client.motionActivityByCamera(names, after: from, before: to, scale: Int(bucket))
                    await MainActor.run {
                        for (cam, items) in byCamera {
                            activity["\(serverID)/\(cam)"] = items.sorted { $0.startTime < $1.startTime }
                        }
                    }
                }
            }
        }
        combined = activity.values.flatMap { $0 }.sorted { $0.startTime < $1.startTime }
        loading = false
        move(to: wallTime)
    }
}
