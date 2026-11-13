import SwiftUI

struct ReviewEntry: Identifiable, Hashable {
    let serverID: UUID
    var item: ReviewItem
    var id: String { "\(serverID.uuidString)/\(item.id)" }
}

struct ReviewView: View {
    enum Kind: Hashable { case alert, detection, motion }

    @Environment(AppModel.self) private var model
    @State private var kind: Kind = .alert
    @State private var cameraFilter: Set<String> = []
    @State private var labelFilter: Set<String> = []
    @State private var zoneFilter: Set<String> = []
    @State private var unreviewedOnly = true
    /// Like Frigate: the last 24 hours, or one chosen day.
    @State private var range: ReviewRange = .last24Hours
    @State private var pickingDay = false
    @State private var entries: [ReviewEntry] = []
    @State private var loading = false
    @State private var canLoadMore = false
    @State private var loadError: String?
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Items on screen, for the timeline beside the grid.
    @State private var visibility = ReviewVisibility()

    private let pageSize = 60

    private var connections: [ServerConnection] { model.reviewConnections.filter(\.isOnline) }

    private var filterKey: String {
        "\(kind)|\(cameraFilter.sorted())|\(labelFilter.sorted())|\(zoneFilter.sorted())|\(unreviewedOnly)|\(range)|\(model.reviewConnections.map { "\($0.id)\($0.isOnline)" })"
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.reviewPath) {
            ScrollViewReader { proxy in
                HStack(spacing: 0) {
                    if kind == .motion {
                        // Motion fills the screen below the header: previews and a timeline.
                        VStack(spacing: 0) {
                            header.padding(.horizontal, 16)
                            MotionReviewView(connections: connections, cameraFilter: cameraFilter,
                                             start: range.bounds.after.timeIntervalSince1970,
                                             end: range.bounds.before.timeIntervalSince1970)
                        }
                    } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
                            header
                            list
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                    }
                    if showsTimeline {
                        // Beside the grid, like Frigate's review page; tap or drag to jump.
                        ReviewTimeline(entries: entries, visibility: visibility) { entry in
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(entry.id, anchor: .top) }
                        }
                        .frame(width: 76)
                        .padding(.top, 70)
                        .padding(.bottom, 16)
                        .padding(.trailing, 12)
                    }
                }
            }
            .refreshable { await reload() }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .appDestinations()
            .sheet(isPresented: $pickingDay) {
                DayPickerSheet(day: Binding(get: { range.day }, set: { if let d = $0 { range = .day(d) } }))
            }
            .task(id: filterKey) { await reload() }
            .onChange(of: model.reviewKindRequest, initial: true) { _, v in
                guard let v else { return }
                kind = v == "motion" ? .motion : (v == "detection" ? .detection : .alert)
                model.reviewKindRequest = nil
            }
            .onAppear {
                // Pick up items marked or deleted in the detail view.
                if !entries.isEmpty { Task { await reload(silent: true) } }
            }
            // Keep up with reviews done elsewhere while this tab is open.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    if !Task.isCancelled && model.tab == .review { await reload(silent: true) }
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                LargeTitle(text: L("Review"))
                Spacer()
                if kind != .motion {
                    Button("Mark all reviewed") { Task { await markAllReviewed() } }
                        .font(.system(size: 15, weight: .medium))
                        .disabled(!entries.contains { !$0.item.hasBeenReviewed })
                }
            }
            if isWide {
                // Wide screens: the kinds on the left and the filters on the right, on one line.
                HStack(spacing: 16) {
                    kindBar.frame(maxWidth: 560)
                    Spacer(minLength: 0)
                    filterChips.fixedSize()
                }
            } else {
                kindBar
                filters
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var kindBar: some View {
        SegmentedBar(options: [Kind.alert, .detection, .motion], selection: $kind) { k in
            switch k {
            case .alert: return countTitle(L("Alerts"), max(connections.reduce(0) { $0 + ($1.summary?.last24Hours?.unreviewedAlerts ?? 0) }, listedUnreviewed(.alert)))
            case .detection: return countTitle(L("Detections"), max(connections.reduce(0) { $0 + ($1.summary?.last24Hours?.unreviewedDetections ?? 0) }, listedUnreviewed(.detection)))
            case .motion: return L("Motion")
            }
        }
    }

    /// Unreviewed items of the last day in the loaded list. The summary behind the counts is
    /// refreshed less often, so a brand new item would otherwise be missing from the count.
    private func listedUnreviewed(_ k: Kind) -> Int {
        guard k == kind else { return 0 }
        let dayAgo = Date().addingTimeInterval(-86400)
        return entries.filter { !$0.item.hasBeenReviewed && $0.item.start > dayAgo }.count
    }

    private func countTitle(_ title: String, _ n: Int) -> String { n > 0 ? "\(title) · \(n)" : title }

    private var availableCameras: [(server: ServerConnection, camera: CameraConfig)] {
        connections.flatMap { c in c.cameras.map { (server: c, camera: $0) } }
    }

    private var availableLabels: [String] {
        var labels = Set<String>()
        for e in entries { labels.formUnion(e.item.labels) }
        labels.formUnion(labelFilter)
        return labels.sorted()
    }

    /// Zones configured on the cameras in view, plus any seen in the loaded items.
    private var availableZones: [String] {
        var zones = Set<String>()
        for (_, cam) in availableCameras where cameraFilter.isEmpty || cameraFilter.contains(cam.name) {
            zones.formUnion(cam.zones?.keys ?? [:].keys)
        }
        for e in entries { zones.formUnion(e.item.data.zones ?? []) }
        zones.formUnion(zoneFilter)
        return zones.sorted()
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            filterChips
            .padding(.horizontal, 16)
        }
        // Scroll edge to edge instead of being cut off at the page margin.
        .padding(.horizontal, -16)
    }

    private var filterChips: some View {
            HStack(spacing: 8) {
                Menu {
                    Button { cameraFilter = [] } label: { checkLabel(L("All cameras"), cameraFilter.isEmpty) }
                    // With several servers, cameras are grouped under their server's name.
                    ForEach(connections) { conn in
                        Section(connections.count > 1 ? conn.server.name : "") {
                            ForEach(conn.cameras, id: \.name) { cam in
                                Button {
                                    if cameraFilter.contains(cam.name) { cameraFilter.remove(cam.name) } else { cameraFilter.insert(cam.name) }
                                } label: { checkLabel(cam.displayName, cameraFilter.contains(cam.name)) }
                            }
                        }
                    }
                } label: {
                    Chip(title: cameraFilter.isEmpty ? L("Cameras") : L("\(cameraFilter.count) cameras"),
                         outlined: !cameraFilter.isEmpty, trailingChevron: true)
                }
                if kind != .motion {
                    Menu {
                        Button { labelFilter = [] } label: { checkLabel(L("All labels"), labelFilter.isEmpty) }
                        ForEach(availableLabels, id: \.self) { l in
                            Button {
                                if labelFilter.contains(l) { labelFilter.remove(l) } else { labelFilter.insert(l) }
                            } label: { checkLabel(FrigateFormat.labelName(l).capitalizedFirst, labelFilter.contains(l)) }
                        }
                    } label: {
                        Chip(title: labelFilter.isEmpty ? L("Labels") : labelFilter.map(FrigateFormat.labelName).sorted().joined(separator: ", "),
                             outlined: !labelFilter.isEmpty, trailingChevron: true)
                    }
                    if !availableZones.isEmpty {
                        Menu {
                            Button { zoneFilter = [] } label: { checkLabel(L("All zones"), zoneFilter.isEmpty) }
                            // With several servers, zones are grouped under their server's name.
                            ForEach(connections) { conn in
                                let zones = conn.zones(only: cameraFilter)
                                if !zones.isEmpty {
                                    Section(connections.count > 1 ? conn.server.name : "") {
                                        ForEach(zones, id: \.self) { z in
                                            Button {
                                                if zoneFilter.contains(z) { zoneFilter.remove(z) } else { zoneFilter.insert(z) }
                                            } label: { checkLabel(FrigateFormat.prettyName(z), zoneFilter.contains(z)) }
                                        }
                                    }
                                }
                            }
                        } label: {
                            Chip(title: zoneFilter.isEmpty ? L("Zones") : zoneFilter.map(FrigateFormat.prettyName).sorted().joined(separator: ", "),
                                 outlined: !zoneFilter.isEmpty, trailingChevron: true)
                        }
                    }
                    Button { unreviewedOnly.toggle() } label: {
                        Chip(title: L("Unreviewed"), outlined: unreviewedOnly)
                    }
                    .buttonStyle(.plain)
                }
                Menu {
                    let today = Calendar.current.startOfDay(for: Date())
                    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today
                    Button { range = .last24Hours } label: { checkLabel(L("Last 24 hours"), range == .last24Hours) }
                    Button { range = .day(today) } label: { checkLabel(L("Today"), range == .day(today)) }
                    Button { range = .day(yesterday) } label: { checkLabel(L("Yesterday"), range == .day(yesterday)) }
                    Button { pickingDay = true } label: { Label("Pick date…", systemImage: "calendar") }
                } label: {
                    Chip(title: range.title, outlined: range != .last24Hours, trailingChevron: true)
                }
            }
    }

    @ViewBuilder
    private func checkLabel(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        if model.reviewConnections.allSatisfy({ !$0.isOnline }) && !model.reviewConnections.isEmpty {
            EmptyStateView(systemImage: "wifi.slash", title: L("No servers online"), message: L("Review items appear when a server is reachable."))
        } else if loading && entries.isEmpty {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        } else if let loadError, entries.isEmpty {
            EmptyStateView(systemImage: "exclamationmark.triangle", title: L("Could not load review"), message: loadError)
        } else if entries.isEmpty {
            EmptyStateView(systemImage: "checkmark.circle", title: unreviewedOnly ? L("All caught up") : L("Nothing here"),
                           message: unreviewedOnly ? (kind == .alert ? L("There are no unreviewed alerts.") : L("There are no unreviewed detections.")) : nil)
        } else {
            ForEach(groupedByDay, id: \.day) { group in
                SectionLabel(text: FrigateFormat.dayTitle(group.day)).padding(.top, 6)
                if isWide {
                    // iPad and Mac: large pictures in a grid, like Frigate's review page.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                        ForEach(group.entries) { entry in
                            if let conn = model.connection(for: entry.serverID) {
                                NavigationLink(value: EventRoute(serverID: entry.serverID, review: entry.item)) {
                                    ReviewTile(entry: entry, conn: conn, showServer: model.orderedConnections.count > 1)
                                }
                                .buttonStyle(.plain)
                                .id(entry.id)
                                .contextMenu { reviewMenu(entry) }
                                .onGeometryChange(for: Bool.self) { proxy in
                                    // On screen: its middle within the scroll view.
                                    guard let bounds = proxy.bounds(of: .scrollView) else { return false }
                                    let frame = proxy.frame(in: .scrollView)
                                    return frame.midY >= 0 && frame.midY <= bounds.height
                                } action: { on in
                                    visibility.set(entry.id, on)
                                }
                                .onDisappear { visibility.set(entry.id, false) }
                            }
                        }
                    }
                } else {
                ForEach(group.entries) { entry in
                    if let conn = model.connection(for: entry.serverID) {
                        NavigationLink(value: EventRoute(serverID: entry.serverID, review: entry.item)) {
                            ReviewRow(entry: entry, conn: conn, showServer: model.orderedConnections.count > 1)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { reviewMenu(entry) }
                    }
                }
                }
            }
            if canLoadMore {
                Button {
                    Task { await loadMore() }
                } label: {
                    HStack { Spacer(); if loading { ProgressView() } else { Text("Load more") }; Spacer() }
                        .frame(height: 44)
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func reviewMenu(_ entry: ReviewEntry) -> some View {
        if !entry.item.hasBeenReviewed {
            Button { Task { await markReviewed([entry]) } } label: { Label("Mark reviewed", systemImage: "checkmark") }
        }
    }

    private var isWide: Bool { sizeClass == .regular }
    private var showsTimeline: Bool { isWide && kind != .motion && !entries.isEmpty }

    private var groupedByDay: [(day: Date, entries: [ReviewEntry])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: entries) { cal.startOfDay(for: $0.item.start) }
        return groups.keys.sorted(by: >).map { (day: $0, entries: groups[$0]!) }
    }

    // MARK: Loading

    private func fetch(before: Date?) async throws -> [ReviewEntry] {
        guard kind != .motion else { return [] }
        let severity: Severity = kind == .alert ? .alert : .detection
        let cams = cameraFilter.isEmpty ? nil : Array(cameraFilter)
        let labels = labelFilter.isEmpty ? nil : Array(labelFilter)
        let zones = zoneFilter.isEmpty ? nil : Array(zoneFilter)
        let reviewed: Bool? = unreviewedOnly ? false : nil
        let bounds = range.bounds
        return try await withThrowingTaskGroup(of: [ReviewEntry].self) { group in
            for conn in connections {
                guard let client = conn.client else { continue }
                let id = conn.server.id
                let known = Set(conn.cameras.map(\.name))
                let serverCams = cams?.filter { known.contains($0) }
                if let serverCams, serverCams.isEmpty { continue }
                group.addTask {
                    let items = try await client.reviews(cameras: serverCams, labels: labels, zones: zones, severity: severity,
                                                         reviewed: reviewed, after: bounds.after, before: before ?? bounds.before, limit: pageSize)
                    return items.map { ReviewEntry(serverID: id, item: $0) }
                }
            }
            var all: [ReviewEntry] = []
            for try await part in group { all += part }
            return all.sorted { $0.item.startTime > $1.item.startTime }
        }
    }

    private func reload(silent: Bool = false) async {
        if !silent { loading = true }
        loadError = nil
        // The counts on the segments and the tab badge come from each server's summary;
        // refresh it too, so items reviewed elsewhere (e.g. in Frigate's web UI) drop out.
        let counts = Task { await model.refreshAll() }
        defer { _ = counts }
        do {
            var result = try await fetch(before: nil)
            // Frigate's list can lag a moment behind items just marked reviewed.
            for i in result.indices where model.reviewedIDs.contains(result[i].item.id) { result[i].item.hasBeenReviewed = true }
            if unreviewedOnly { result.removeAll { $0.item.hasBeenReviewed } }
            entries = result
            canLoadMore = result.count >= pageSize
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }

    private func loadMore() async {
        guard let oldest = entries.last?.item.start else { return }
        loading = true
        if let more = try? await fetch(before: oldest) {
            let known = Set(entries.map(\.id))
            let fresh = more.filter { !known.contains($0.id) }
            entries += fresh
            canLoadMore = !fresh.isEmpty
        }
        loading = false
    }

    private func markReviewed(_ list: [ReviewEntry]) async {
        let byServer = Dictionary(grouping: list.filter { !$0.item.hasBeenReviewed }, by: \.serverID)
        for (serverID, items) in byServer {
            guard let conn = model.connection(for: serverID), let client = conn.client else { continue }
            do {
                try await client.markViewed(items.map(\.item.id))
                let ids = Set(items.map(\.id))
                for i in entries.indices where ids.contains(entries[i].id) { entries[i].item.hasBeenReviewed = true }
                model.reviewedIDs.formUnion(items.map(\.item.id))
                await conn.refresh()
            } catch {
                loadError = error.localizedDescription
            }
        }
        if unreviewedOnly {
            withAnimation { entries.removeAll { $0.item.hasBeenReviewed } }
        }
    }

    /// Marks every unreviewed item that matches the current filters, not only the loaded page,
    /// and refreshes the counts (again a moment later: Frigate's summary can lag behind).
    private func markAllReviewed() async {
        guard kind != .motion else { return }
        let severity: Severity = kind == .alert ? .alert : .detection
        let cams = cameraFilter.isEmpty ? nil : Array(cameraFilter)
        let labels = labelFilter.isEmpty ? nil : Array(labelFilter)
        let zones = zoneFilter.isEmpty ? nil : Array(zoneFilter)
        for conn in connections {
            guard let client = conn.client else { continue }
            let known = Set(conn.cameras.map(\.name))
            let serverCams = cams?.filter { known.contains($0) }
            if let serverCams, serverCams.isEmpty { continue }
            do {
                // Pages of unreviewed items until none are left (bounded, to be safe).
                for _ in 0..<20 {
                    let items = try await client.reviews(cameras: serverCams, labels: labels, zones: zones, severity: severity,
                                                         reviewed: false, limit: 500)
                    let ids = items.map(\.id).filter { !model.reviewedIDs.contains($0) }
                    if ids.isEmpty { break }
                    for chunk in stride(from: 0, to: ids.count, by: 100) {
                        try await client.markViewed(Array(ids[chunk..<min(chunk + 100, ids.count)]))
                    }
                    model.reviewedIDs.formUnion(ids)
                }
            } catch {
                loadError = error.localizedDescription
            }
        }
        for i in entries.indices { entries[i].item.hasBeenReviewed = true }
        if unreviewedOnly { withAnimation { entries.removeAll() } }
        await model.refreshAll()
        try? await Task.sleep(for: .seconds(2))
        await model.refreshAll()
    }
}

struct ReviewRow: View {
    let entry: ReviewEntry
    let conn: ServerConnection
    var showServer: Bool = true

    var body: some View {
        let item = entry.item
        let camName = conn.config?.cameras[item.camera]?.displayName ?? FrigateFormat.prettyName(item.camera)
        HStack(spacing: 12) {
            RemoteImage(url: conn.client?.thumbnailURL(for: item), session: conn.client?.session ?? .shared)
                .frame(width: 112, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    Text(item.inProgress ? "LIVE" : FrigateFormat.reviewDuration(item))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(item.inProgress ? Theme.recording : .black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    ForEach(item.labels.prefix(4), id: \.self) { LabelIcon(label: $0) }
                }
                HStack(spacing: 6) {
                    if showServer { ServerBadge(initial: conn.server.initial, tint: conn.server.tint) }
                    Text(camName).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                }
                Text(meta(item)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !item.hasBeenReviewed {
                Circle().fill(Theme.accent).frame(width: 10, height: 10).padding(.trailing, 4)
                    .accessibilityLabel("Unreviewed")
            }
        }
        .padding(8)
        .card(radius: 12)
        .contentShape(Rectangle())
    }

    private func meta(_ item: ReviewItem) -> String {
        var parts: [String] = []
        if showServer { parts.append(conn.server.name) }
        parts.append(FrigateFormat.time(item.start))
        let zones = (item.data.zones ?? []).map(FrigateFormat.prettyName)
        if !zones.isEmpty { parts.append(zones.joined(separator: ", ").lowercased()) }
        let subs = item.data.subLabels ?? []
        if !subs.isEmpty { parts.append(subs.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// Motion tab: motion activity per camera over the last 24 hours.
struct MotionOverview: View {
    let connections: [ServerConnection]
    let cameraFilter: Set<String>
    @State private var activity: [String: [MotionActivity]] = [:]
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: L("Last 24 hours")).padding(.top, 6)
            if loading && activity.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            }
            ForEach(connections) { conn in
                ForEach(conn.cameras.filter { cameraFilter.isEmpty || cameraFilter.contains($0.name) }, id: \.name) { cam in
                    let key = "\(conn.server.id)/\(cam.name)"
                    NavigationLink(value: PlaybackRoute(serverID: conn.server.id, camera: cam.name, day: Calendar.current.startOfDay(for: Date()))) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                if connections.count > 1 { ServerBadge(initial: conn.server.initial, tint: conn.server.tint) }
                                Text(cam.displayName).font(.system(size: 15, weight: .semibold))
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                            }
                            ActivityStrip(start: Date().addingTimeInterval(-86400), end: Date(), buckets: 72,
                                          motion: activity[key] ?? [], reviews: [])
                            HStack {
                                Text("24 h ago"); Spacer(); Text("12 h ago"); Spacer(); Text("Now")
                            }
                            .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .card(radius: 12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task(id: connections.map(\.id)) { await load() }
    }

    private func load() async {
        loading = true
        let end = Date(), start = end.addingTimeInterval(-86400)
        for conn in connections {
            guard let client = conn.client else { continue }
            let names = conn.cameras.map(\.name)
            let byCamera = await client.motionActivityByCamera(names, after: start, before: end, scale: 1200)
            for (cam, items) in byCamera { activity["\(conn.server.id)/\(cam)"] = items }
        }
        loading = false
    }
}

/// The period Review shows: like Frigate, the last 24 hours by default, or one day.
enum ReviewRange: Hashable, CustomStringConvertible {
    case last24Hours
    case day(Date)

    var description: String {
        switch self {
        case .last24Hours: return "24h"
        case .day(let d): return "\(Int(d.timeIntervalSince1970))"
        }
    }

    var day: Date? { if case .day(let d) = self { return d } else { return nil } }

    var bounds: (after: Date, before: Date) {
        let now = Date()
        switch self {
        case .last24Hours: return (now.addingTimeInterval(-86400), now)
        case .day(let d):
            let end = Calendar.current.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86400)
            return (d, min(end, now))
        }
    }

    var title: String {
        switch self {
        case .last24Hours: return L("Last 24 hours")
        case .day(let d): return FrigateFormat.dayTitle(d)
        }
    }
}
