import SwiftUI

struct EventDetailView: View {
    let route: EventRoute
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var item: ReviewItem
    @State private var player = RecordingPlayer()
    @State private var events: [FrigateEvent] = []
    @State private var timeline: [TimelineEntry] = []
    @State private var share: ShareItem?
    @State private var downloading = false
    @State private var confirmDelete = false
    @State private var errorMessage: String?

    /// Seconds of recording shown before and after the review item.
    private let padding: Double = 5

    init(route: EventRoute) {
        self.route = route
        _item = State(initialValue: route.review)
    }

    private var conn: ServerConnection? { model.connection(for: route.serverID) }
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
        return min(max(itemEnd, eventEnd), itemEnd + 60, now) + offset
    }
    /// Whole seconds, as the /vod endpoint uses, so the event range lines up with the video.
    private var clipStart: Double { (activityStart - padding).rounded(.down) }
    private var clipEnd: Double { min(activityEnd + padding, Date().timeIntervalSince1970) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    videoPlayer
                    scrubber
                    info
                    tiles
                    lifecycle
                }
                .padding(.bottom, 16)
            }
            actions
        }
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .sheet(item: $share) { ShareSheet(items: $0.items) }
        .confirmationDialog("Delete this review item and its recordings?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .task { await load() }
        .onDisappear { player.stop() }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold))
                    Text("Back").font(.system(size: 17))
                }
                .frame(height: 44)
            }
            Spacer()
            Button { Task { await download() } } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 19, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Share clip")
            .disabled(downloading || item.inProgress)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    // MARK: Player

    private var videoPlayer: some View {
        ZStack {
            PlayerLayerView(player: player.player)
                .zoomable()
            if let error = player.error {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.title2)
                    Text(error).font(.system(size: 13)).multilineTextAlignment(.center)
                }
                .foregroundStyle(.white).padding()
            } else if player.isBuffering || player.duration == 0 {
                ProgressView().tint(.white)
            } else if !player.wantsToPlay {
                OverlayButton(systemImage: "play.fill", size: 56, label: "Play") { player.play() }
            }
        }
        .aspectRatio(conn?.config?.cameras[item.camera]?.aspectRatio ?? 16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .contentShape(Rectangle())
        .onTapGesture { player.toggle() }
    }

    private var scrubber: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                let total = max(player.duration, 0.1)
                let progress = min(1, player.currentTime / total)
                let evStart = max(0, min(1, (activityStart - clipStart) / total))
                let evEnd = max(evStart, min(1, (activityEnd - clipStart) / total))
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.controlBorder).frame(height: 4)
                    RoundedRectangle(cornerRadius: 3).fill(Theme.warning.opacity(0.28))
                        .frame(width: max(0, (evEnd - evStart) * w), height: 14)
                        .offset(x: evStart * w)
                    Capsule().fill(Theme.accent).frame(width: progress * w, height: 4)
                    Circle().fill(.white).frame(width: 16, height: 16)
                        .offset(x: progress * w - 8)
                }
                .frame(height: 28)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        player.isScrubbing = true
                        player.currentTime = max(0, min(1, v.location.x / w)) * total
                    }
                    .onEnded { v in
                        player.isScrubbing = false
                        player.seek(to: max(0, min(1, v.location.x / w)) * total, precise: true)
                    })
            }
            .frame(height: 28)
            HStack {
                Text(FrigateFormat.duration(player.currentTime)).monospacedDigit()
                Spacer()
                HStack(spacing: 4) {
                    ForEach([Float(1), 2, 4], id: \.self) { r in
                        Button("\(Int(r))x") { player.setRate(r) }
                            .font(.system(size: 12, weight: player.rate == r ? .bold : .regular))
                            .foregroundStyle(player.rate == r ? Theme.accent : Theme.textSecondary)
                            .frame(minWidth: 32, minHeight: 28)
                    }
                }
                Spacer()
                Text(FrigateFormat.duration(player.duration)).monospacedDigit()
            }
            .font(.system(size: 12))
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
        return L("\(day), \(s) to \(FrigateFormat.time(end, seconds: true))")
    }

    private var tiles: some View {
        let score = events.compactMap(\.bestScore).max()
        let zones = (item.data.zones ?? []).map(FrigateFormat.prettyName)
        let subLabels = (item.data.subLabels ?? []) + events.compactMap { $0.subLabel?.name }.filter { !$0.isEmpty }
        let third: (String, String) = {
            if let s = subLabels.first {
                let isPlate = item.labels.contains { $0 == "car" || $0 == "license_plate" } && !item.labels.contains("person")
                return (isPlate ? L("PLATE") : (item.labels.contains("person") ? L("FACE") : L("SUB LABEL")), s)
            }
            if item.labels.contains("person") { return (L("FACE"), L("Unknown")) }
            return (L("DURATION"), FrigateFormat.shortDuration(trackedDuration))
        }()
        return HStack(spacing: 8) {
            tile(L("SCORE"), score.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
            tile(L("ZONES"), zones.isEmpty ? L("None") : zones.joined(separator: ", "))
            tile(third.0, third.1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
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
                    if item.hasBeenReviewed { Image(systemName: "checkmark") }
                    Text("Reviewed")
                }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(item.hasBeenReviewed ? Theme.textSecondary : Theme.onColor)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(item.hasBeenReviewed ? Theme.card : Theme.accent, in: RoundedRectangle(cornerRadius: 12))
            }
            .disabled(item.hasBeenReviewed)
            Button { Task { await download() } } label: {
                Group { if downloading { ProgressView() } else { Text("Download") } }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .card(border: Theme.controlBorder, radius: 12)
            }
            .disabled(downloading || item.inProgress)
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
        // Fetch the tracked objects first: they decide which part of the recording to load.
        let ids = item.data.detections ?? []
        events = (try? await client.events(ids: ids)) ?? []
        if player.url == nil {
            player.load(client.vodURL(camera: item.camera, start: clipStart, end: clipEnd))
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
            await conn?.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func download() async {
        guard let client else { return }
        downloading = true
        defer { downloading = false }
        do {
            let url = client.clipURL(camera: item.camera, start: clipStart, end: clipEnd)
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let file = try await client.download(url, fileName: "\(item.camera)_\(f.string(from: item.start)).mp4")
            share = ShareItem(items: [file])
        } catch {
            errorMessage = error.localizedDescription
        }
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
