import AVFoundation
import SwiftUI

/// Row of recent unreviewed alerts at the top of Live, like Frigate's live dashboard.
/// Each plays Frigate's short preview clip on a loop over its thumbnail, or shows the thumbnail.
struct RecentAlertsStrip: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [ReviewEntry] = []
    /// Long-press actions, the same as on events elsewhere.
    @State private var actions = ReviewActions()

    private var connections: [ServerConnection] { model.scopedConnections.filter(\.isOnline) }
    private var loadKey: String { connections.map(\.id.uuidString).joined() }

    var body: some View {
        // A VStack exists even when empty (an empty Group does not), so the loader below runs.
        VStack(spacing: 0) {
            if !entries.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(entries) { entry in
                            NavigationLink(value: EventRoute(serverID: entry.serverID, review: entry.item)) {
                                AlertPreviewTile(entry: entry)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { ReviewItemMenu(item: entry.item, serverID: entry.serverID, actions: actions) }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
                .frame(height: 84)
            }
        }
        // Without alerts, take no room (cancel the spacing of the stack around it).
        .padding(.bottom, entries.isEmpty ? -14 : 0)
        .reviewActionsHost(actions)
        .onChange(of: actions.deletedIDs) { _, ids in entries.removeAll { ids.contains($0.item.id) } }
        .task(id: loadKey) {
            // Refresh while Live is visible; reviewed items drop out.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func load() async {
        var all: [ReviewEntry] = []
        for conn in connections {
            guard let client = conn.client else { continue }
            let items = (try? await client.reviews(severity: .alert, reviewed: false,
                                                   after: Date().addingTimeInterval(-86400),
                                                   before: ScreenshotMode.before, limit: 10)) ?? []
            all += items.map { ReviewEntry(serverID: conn.server.id, item: $0) }
        }
        all = all.filter { !model.reviewedIDs.contains($0.item.id) }
        entries = Array(all.sorted { $0.item.startTime > $1.item.startTime }.prefix(10))
    }
}

struct AlertPreviewTile: View {
    let entry: ReviewEntry
    @Environment(AppModel.self) private var model

    var body: some View {
        let conn = model.connection(for: entry.serverID)
        let client = conn?.client
        ZStack {
            RemoteImage(url: client?.thumbnailURL(for: entry.item), session: client?.session ?? .shared)
            if model.playAlertPreviews, !entry.item.inProgress, let client {
                LoopingVideo(url: client.url("api/review/\(entry.item.id)/preview", query: ["format": "mp4"]))
            }
        }
        .frame(width: 150, height: 84)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 3) {
                ForEach(entry.item.labels.prefix(3), id: \.self) { LabelIcon(label: $0, size: 16) }
            }
            .padding(5)
        }
        .overlay(alignment: .bottomLeading) {
            Group {
                if entry.item.inProgress { Text("LIVE") } else { RelativeTimeText(date: entry.item.start) }
            }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(entry.item.inProgress ? Theme.recording : .black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                .padding(5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cardBorder, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("\(entry.item.labels.map(FrigateFormat.labelName).joined(separator: ", ")) at \(FrigateFormat.time(entry.item.start))"))
    }
}

/// Muted video that loops, shown only while its layer has a frame, so the thumbnail below
/// stays visible until then (and again if the layer is emptied, e.g. in the background).
struct LoopingVideo: View {
    let url: URL
    @State private var player = AVQueuePlayer()
    @State private var looper: AVPlayerLooper?
    @State private var ready = false

    var body: some View {
        PlayerLayerView(player: player, gravity: .resizeAspectFill, onReadyForDisplay: { ready = $0 }, background: .clear)
            .opacity(ready ? 1 : 0)
            .allowsHitTesting(false)
            // Runs again each time the tile appears. Every run gets a fresh player: a looper
            // added to a player that another looper still feeds throws inside AVFoundation.
            .task(id: url) {
                stop()
                let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPCookiesKey": HTTPCookieStorage.shared.cookies ?? []])
                let fresh = AVQueuePlayer()
                fresh.isMuted = true
                looper = AVPlayerLooper(player: fresh, templateItem: AVPlayerItem(asset: asset))
                player = fresh
                fresh.play()
            }
            // The system pauses video in the background; carry on when the app is back.
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                if looper != nil { player.play() }
            }
            .onDisappear { stop() }
    }

    private func stop() {
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
        ready = false
    }
}
