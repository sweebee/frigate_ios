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
                } side: {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            info
                            tiles
                            lifecycle
                        }
                        .padding(.bottom, 16)
                    }
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
                Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Back")
            Spacer()
            if event.hasSnapshot == true {
                Button { Task { await shareSnapshot() } } label: {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 19, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Share snapshot")
            }
        }
        .padding(.horizontal, 8)
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

/// Media on the left at its own aspect ratio, as large as the window allows, and a column of
/// details on the right; for iPad and Mac.
struct WideDetailLayout<Media: View, Side: View>: View {
    let aspect: Double
    /// Height under the picture that `media` also uses, e.g. a scrubber.
    var reserve: CGFloat = 0
    @ViewBuilder let media: Media
    @ViewBuilder let side: Side

    var body: some View {
        GeometryReader { geo in
            let sideWidth = min(400, geo.size.width * 0.36)
            let maxWidth = max(200, geo.size.width - sideWidth - 48)
            let height = min(maxWidth / aspect, max(160, geo.size.height - 24 - reserve))
            HStack(alignment: .top, spacing: 16) {
                media
                    .frame(width: height * aspect, height: height + reserve, alignment: .top)
                    .frame(width: maxWidth, alignment: .top)
                VStack(spacing: 0) { side }
                    .frame(width: sideWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }
}
