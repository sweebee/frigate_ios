import SwiftUI

/// Playback's "Detail" view, like Frigate's: the day's events as cards, the one that plays
/// opened up with its objects and their lifecycle. The lifecycle row at the playhead is lit; a
/// tap on a row plays from there, a tap on another event opens it and plays it.
struct PlaybackDetailList: View {
    let reviews: [ReviewItem]
    /// The event under the playhead.
    let playingID: String?
    /// Playhead in recording time; lifecycle times plus `annotationOffset` are on that clock.
    let wallTime: Double
    let annotationOffset: Double
    let client: FrigateClient?
    let serverID: UUID
    let actions: ReviewActions
    var compact = false
    /// Plays from a moment in recording time.
    let onJump: (Double) -> Void

    @State private var openID: String?
    /// The card asked to open while its objects load; it opens once they are there, so it never
    /// shows a spinner or grows afterwards.
    @State private var pendingID: String?
    @State private var details: [String: EventDetailData] = [:]
    @State private var loadingIDs: Set<String> = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: a lazy stack guesses the height of rows it has not drawn, and a card
                // opening then made the list jump.
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(reviews) { r in
                        let open = openID == r.id
                        let data = details[r.id]
                        PlaybackDetailCard(review: r, open: open, loading: pendingID == r.id, playing: playingID == r.id,
                                           data: data,
                                           highlight: open ? data?.entryIndex(at: wallTime - annotationOffset) : nil,
                                           compact: compact, client: client,
                                           onHeader: { tapHeader(r, proxy: proxy) },
                                           onEntry: { onJump($0 + annotationOffset - 1) })
                            .equatable()
                            .id(r.id)
                            .contextMenu { ReviewItemMenu(item: r, serverID: serverID, actions: actions) }
                    }
                }
                .padding(.horizontal, compact ? 0 : 16)
                .padding(.bottom, 24)
            }
            // The event that starts playing opens by itself, as in Frigate.
            .onChange(of: playingID, initial: true) { old, id in
                guard let id, id != openID else { return }
                open(id, proxy: proxy, anchor: nil, animated: old != nil)
                prefetch(around: id)
            }
        }
    }

    /// Cards open and close at once; only the scroll that keeps one in view is animated.
    private static let motion = Animation.easeInOut(duration: 0.28)

    private func tapHeader(_ r: ReviewItem, proxy: ScrollViewProxy) {
        if openID == r.id {
            openID = nil
        } else {
            onJump(r.startTime + annotationOffset - 1)
            // The card that was open above it closes, which would pull this one up out of
            // view; bring the tapped card's header back to the top.
            open(r.id, proxy: proxy, anchor: .top, animated: true)
        }
    }

    private func open(_ id: String, proxy: ScrollViewProxy, anchor: UnitPoint?, animated: Bool) {
        if details[id] != nil {
            pendingID = nil
            openID = id
            scroll(proxy, to: id, anchor: anchor, animated: animated)
            return
        }
        pendingID = id
        Task {
            await load(id)
            guard pendingID == id else { return }   // another card was asked for meanwhile
            pendingID = nil
            openID = id
            scroll(proxy, to: id, anchor: anchor, animated: animated)
        }
    }

    /// After the cards have their new size (next run loop), so the scroll aims at the right spot.
    private func scroll(_ proxy: ScrollViewProxy, to id: String, anchor: UnitPoint?, animated: Bool) {
        DispatchQueue.main.async {
            withAnimation(animated ? Self.motion : nil) { proxy.scrollTo(id, anchor: anchor) }
        }
    }

    /// The events around the one playing, so tapping a neighbour opens it at once.
    private func prefetch(around id: String) {
        guard let i = reviews.firstIndex(where: { $0.id == id }) else { return }
        let near = reviews[max(0, i - 2)...min(reviews.count - 1, i + 2)].map(\.id)
        Task { for n in near where n != id { await load(n) } }
    }

    private func load(_ id: String) async {
        guard details[id] == nil, !loadingIDs.contains(id), let client,
              let r = reviews.first(where: { $0.id == id }) else { return }
        loadingIDs.insert(id)
        defer { loadingIDs.remove(id) }
        let ids = Array((r.data.detections ?? []).prefix(10))
        async let events = (try? await client.events(ids: ids)) ?? []
        var entries: [TimelineEntry] = []
        await withTaskGroup(of: [TimelineEntry].self) { group in
            for oid in ids { group.addTask { (try? await client.timeline(sourceId: oid)) ?? [] } }
            for await part in group { entries += part }
        }
        let loaded = await events
        details[id] = EventDetailData(objects: loaded.sorted { $0.startTime < $1.startTime },
                                      entries: entries.sorted { $0.timestamp < $1.timestamp })
    }
}

/// The objects of one event and their lifecycle, loaded when its card opens.
struct EventDetailData: Equatable {
    let objects: [FrigateEvent]
    let entries: [TimelineEntry]

    func entries(for object: FrigateEvent) -> [TimelineEntry] {
        entries.filter { $0.sourceId == object.id }
    }

    /// The last lifecycle row at or before `time` (detection clock), across all objects.
    func entryIndex(at time: Double) -> Int? {
        entries.lastIndex { $0.timestamp <= time + 0.25 }
    }
}

/// One event: a header row, and when open its objects with their lifecycle. Equatable on its
/// data only, so the playhead moving does not rebuild closed cards or close a menu.
private struct PlaybackDetailCard: View, Equatable {
    let review: ReviewItem
    let open: Bool
    let loading: Bool
    let playing: Bool
    let data: EventDetailData?
    let highlight: Int?
    let compact: Bool
    let client: FrigateClient?
    let onHeader: () -> Void
    let onEntry: (Double) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.review == b.review && a.open == b.open && a.loading == b.loading && a.playing == b.playing && a.data == b.data
            && a.highlight == b.highlight && a.compact == b.compact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onHeader) { header }.buttonStyle(.plain)
            if open { objects }
        }
        .card(border: open || playing ? Theme.accent : Theme.cardBorder, radius: 12)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(review.severity == .alert ? Theme.destructive : Theme.warning).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(FrigateFormat.time(review.start, seconds: true))
                        .font(.system(size: compact ? 13 : 14, weight: .semibold).monospacedDigit())
                    ForEach(review.labels, id: \.self) { LabelIcon(label: $0, size: compact ? 18 : 20) }
                }
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, compact ? 10 : 12).padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let n = review.data.detections?.count ?? 0
        let objects = n == 1 ? L("1 object") : L("\(n) objects")
        let length = review.endTime.map { FrigateFormat.shortDuration($0 - review.startTime) }
        return [objects, length].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var objects: some View {
        if let data {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(data.objects) { o in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            LabelTag(label: o.label, size: 12)
                            if let s = o.bestScore {
                                Text("\(Int((s * 100).rounded()))%").font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            if let name = o.subLabel?.name, !name.isEmpty {
                                Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            }
                        }
                        .padding(.bottom, 4)
                        ForEach(data.entries(for: o), id: \.self) { e in
                            let lit = highlight.map { data.entries[$0] == e } ?? false
                            Button { onEntry(e.timestamp) } label: {
                                HStack(spacing: 8) {
                                    Text(e.description).font(.system(size: 13)).lineLimit(2)
                                    Spacer(minLength: 6)
                                    Text(FrigateFormat.time(Date(timeIntervalSince1970: e.timestamp), seconds: true))
                                        .font(.system(size: 12).monospacedDigit())
                                        .foregroundStyle(lit ? Theme.accent : Theme.textSecondary)
                                }
                                .foregroundStyle(lit ? Theme.accent : Theme.text)
                                .frame(minHeight: 30)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.cardBorder).frame(width: 2) }
                }
            }
            .padding(.horizontal, compact ? 10 : 12).padding(.bottom, 10)
        } else {
            // About the height of one object with a few rows, so the card hardly grows once
            // they arrive.
            ProgressView().frame(maxWidth: .infinity, minHeight: 120).padding(.bottom, 6)
        }
    }
}
