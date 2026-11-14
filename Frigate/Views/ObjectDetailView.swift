import SwiftUI

/// Details of one tracked object: its snapshot, scores, zones and lifecycle, with a way to
/// watch the video, like Frigate's "Tracked object details".
struct ObjectDetailView: View {
    let route: ObjectRoute
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var timeline: [TimelineEntry] = []
    @State private var share: ShareItem?
    @State private var opening = false
    @State private var errorMessage: String?

    private var event: FrigateEvent { route.event }
    private var conn: ServerConnection? { model.connection(for: route.serverID) }
    private var client: FrigateClient? { conn?.client }
    private var camera: CameraConfig? { conn?.config?.cameras[event.camera] }

    var body: some View {
        VStack(spacing: 0) {
            header
            if sizeClass == .regular {
                // iPad and Mac: the snapshot beside the details instead of above them.
                WideDetailLayout(aspect: camera?.aspectRatio ?? 16 / 9) {
                    image.clipShape(RoundedRectangle(cornerRadius: 12))
                } details: {
                    info
                    tiles
                } extra: {
                    lifecycle
                } actions: {
                    actions
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        image
                        info
                        tiles
                        lifecycle
                    }
                    .padding(.bottom, 16)
                }
                actions
            }
        }
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .sheet(item: $share) { ShareSheet(items: $0.items) }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .task {
            if let client { timeline = (try? await client.timeline(sourceId: event.id)) ?? [] }
        }
    }

    private var header: some View {
        HStack {
            // Only the arrow, like every other screen.
            Button { dismiss() } label: {
                BackButtonLabel()
            }
            .accessibilityLabel("Back")
            Spacer()
            if event.hasSnapshot == true {
                Button { Task { await shareSnapshot() } } label: {
                    HeaderIconLabel(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share snapshot")
            }
        }
        .headerBarPadding()
        .padding(.bottom, 8)
    }

    private var image: some View {
        RemoteImage(url: event.hasSnapshot == true ? client?.snapshotURL(for: event) : client?.thumbnailURL(for: event),
                    session: client?.session ?? .shared, contentMode: .fit)
            .zoomable()
            .aspectRatio(camera?.aspectRatio ?? 16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Color.black)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                LabelTag(label: event.label)
                if let sub = event.subLabel?.name, !sub.isEmpty {
                    Text(sub).font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.control, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            Text(camera?.displayName ?? FrigateFormat.prettyName(event.camera))
                .font(.system(size: 22, weight: .bold))
            Text(timeText).font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var timeText: String {
        let start = Date(timeIntervalSince1970: event.startTime)
        let day = FrigateFormat.dayTitle(start)
        let s = FrigateFormat.time(start, seconds: true)
        guard let end = event.endTime else { return L("\(day), \(s), in progress") }
        return L("\(day), \(s) to \(FrigateFormat.time(Date(timeIntervalSince1970: end), seconds: true))")
    }

    private var tiles: some View {
        let zones = (event.zones ?? []).map(FrigateFormat.prettyName)
        let duration = event.endTime.map { $0 - event.startTime }
        return HStack(spacing: 8) {
            tile(L("SCORE"), event.bestScore.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
            tile(L("ZONES"), zones.isEmpty ? L("None") : zones.joined(separator: ", "))
            if let plate = event.recognizedPlate {
                tile(L("PLATE"), plate)
            } else {
                tile(L("DURATION"), duration.map { $0 > 3600 ? L("> 1 h") : FrigateFormat.shortDuration($0) } ?? "LIVE")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

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

    private var actions: some View {
        Button { Task { await openVideo() } } label: {
            HStack(spacing: 8) {
                if opening { ProgressView().tint(Theme.onColor) } else { Image(systemName: "play.fill") }
                Text("Watch video")
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.onColor)
            .frame(maxWidth: .infinity).frame(height: 48)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(opening)
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
        .background(Theme.background)
    }

    /// Opens the review item the object belongs to; without one, the recording of that moment.
    private func openVideo() async {
        guard let client else { return }
        opening = true
        defer { opening = false }
        if let review = try? await client.review(forEvent: event.id) {
            model.explorePath.append(EventRoute(serverID: route.serverID, review: review))
        } else {
            let start = Date(timeIntervalSince1970: event.startTime)
            model.explorePath.append(PlaybackRoute(serverID: route.serverID, camera: event.camera,
                                                   day: Calendar.current.startOfDay(for: start), showTimeline: true,
                                                   startTime: event.startTime))
        }
    }

    private func shareSnapshot() async {
        guard let client else { return }
        do {
            let file = try await client.download(client.snapshotURL(for: event), fileName: "\(event.camera)_\(event.id).jpg")
            share = ShareItem(items: [file])
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// iPad and Mac: the media as large as the window allows, with the details around it.
/// - Upright windows: media across the full width, the details under it.
/// - Wide windows: media on the left and the details beside it; when the media leaves room
///   under it (a window not much wider than tall), `extra` fills that room instead of the side.
/// `details`, `extra` and `actions` bring their own 16 pt side margins.
struct WideDetailLayout<Media: View, Details: View, Extra: View, Actions: View>: View {
    let aspect: Double
    /// Height under the picture that `media` also uses, e.g. a scrubber.
    var reserve: CGFloat = 0
    @ViewBuilder let media: Media
    @ViewBuilder let details: Details
    @ViewBuilder let extra: Extra
    @ViewBuilder let actions: Actions

    var body: some View {
        GeometryReader { geo in
            if geo.size.width < geo.size.height * 1.1 {
                stacked(geo.size)
            } else {
                sideBySide(geo.size)
            }
        }
    }

    private func stacked(_ size: CGSize) -> some View {
        let width = size.width - 32
        let height = min(width / aspect, size.height * 0.55)
        return VStack(spacing: 0) {
            media
                .frame(width: height * aspect, height: height + reserve, alignment: .top)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    details
                    extra
                }
                .padding(.bottom, 16)
            }
            actions
        }
        .padding(.bottom, 8)
    }

    private func sideBySide(_ size: CGSize) -> some View {
        let sideWidth = min(400, size.width * 0.36)
        let maxWidth = max(200, size.width - sideWidth - 32)
        let height = min(maxWidth / aspect, max(160, size.height - 28 - reserve))
        // Room left under the media for `extra`.
        let below = size.height - 28 - reserve - height
        let extraBelow = below >= 200
        return HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                media
                    .frame(width: height * aspect, height: height + reserve, alignment: .top)
                if extraBelow {
                    ScrollView {
                        // Its margins are for a column of its own; under the media it lines
                        // up with the media's edges instead.
                        extra.padding(.horizontal, -16).padding(.bottom, 16)
                    }
                    .scrollIndicators(.never)
                }
            }
            .frame(width: maxWidth, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        details
                        if !extraBelow { extra }
                    }
                    .padding(.bottom, 16)
                }
                actions
            }
            .frame(width: sideWidth)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.leading, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// Opens a tracked object from Explore: the event it belongs to when there is one (video,
/// every object's snapshot, the actions), the object screen otherwise.
struct ObjectOrEventView: View {
    let route: ObjectRoute
    @Environment(AppModel.self) private var model
    @State private var review: ReviewItem?
    @State private var resolved = false

    var body: some View {
        Group {
            if let review {
                EventDetailView(route: EventRoute(serverID: route.serverID, review: review, focusEventID: route.event.id))
            } else if resolved {
                ObjectDetailView(route: route)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).screenBackground()
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
        .task {
            guard !resolved, let client = model.connection(for: route.serverID)?.client else { resolved = true; return }
            review = try? await client.review(forEvent: route.event.id)
            resolved = true
        }
    }
}

/// A tracked object's snapshot (with its box), large, to look at and share.
struct SnapshotViewer: View {
    let event: FrigateEvent
    let client: FrigateClient?
    var cameraName: String?
    @Environment(\.dismiss) private var dismiss
    @State private var share: ShareItem?
    @State private var working = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                RemoteImage(url: event.hasSnapshot == true ? client?.snapshotURL(for: event) : client?.thumbnailURL(for: event),
                            session: client?.session ?? .shared, contentMode: .fit)
                    .zoomable()
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(Color.black)
                HStack(spacing: 8) {
                    LabelTag(label: event.label, size: 13)
                    if let sub = event.subLabel?.name, !sub.isEmpty {
                        Text(sub).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    }
                }
                .padding(.horizontal, 16)
                Text(subtitle).font(.system(size: 15)).foregroundStyle(Theme.textSecondary).padding(.horizontal, 16)
                Spacer()
            }
            .screenBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await shareSnapshot() } } label: {
                        if working { ProgressView() } else { Image(systemName: "square.and.arrow.up") }
                    }
                    .disabled(working || event.hasSnapshot != true)
                    .accessibilityLabel("Share snapshot")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: $share) { ShareSheet(items: $0.items) }
        .presentationDetents([.large])
    }

    private var subtitle: String {
        var parts: [String] = []
        if let s = event.bestScore { parts.append(L("Score \(Int((s * 100).rounded()))%")) }
        parts.append(FrigateFormat.time(Date(timeIntervalSince1970: event.startTime), seconds: true))
        if let cameraName { parts.append(cameraName) }
        return parts.joined(separator: " · ")
    }

    private func shareSnapshot() async {
        guard let client else { return }
        working = true
        defer { working = false }
        if let file = try? await client.download(client.snapshotURL(for: event), fileName: "\(event.camera)_\(event.id).jpg") {
            share = ShareItem(items: [file])
        }
    }
}
