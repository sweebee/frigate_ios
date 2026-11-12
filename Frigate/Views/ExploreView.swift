import SwiftUI

/// A tracked object on one of the servers.
struct ExploreEntry: Identifiable, Hashable {
    let serverID: UUID
    let event: FrigateEvent
    var id: String { "\(serverID.uuidString)/\(event.id)" }
}

/// Filters of the Explore tab, like Frigate's Explore page.
struct ExploreFilter: Equatable {
    var cameras: Set<String> = []
    var labels: Set<String> = []
    var zones: Set<String> = []
    var subLabels: Set<String> = []
    var day: Date? = nil
    var sort: FrigateClient.EventSort = .newest

    var isActive: Bool { self != ExploreFilter() }
    /// Rows per label until a label is picked or the order changes; then one grid.
    var showsGrid: Bool { !labels.isEmpty || sort != .newest }
    /// Only the label rows' shortcut endpoint can be used.
    var isPlain: Bool { cameras.isEmpty && zones.isEmpty && subLabels.isEmpty && day == nil && ScreenshotMode.cameras == nil }
}

struct ExploreView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ExploreFilter()
    @State private var rows: [LabelRow] = []
    @State private var grid: [ExploreEntry] = []
    @State private var loading = false
    @State private var canLoadMore = false
    @State private var loadError: String?
    @State private var knownLabels: [String] = []
    @State private var knownSubLabels: [String] = []
    @State private var showDayPicker = false

    struct LabelRow: Identifiable {
        let label: String
        var count: Int?
        var entries: [ExploreEntry]
        var id: String { label }
    }

    private let pageSize = 50

    private var connections: [ServerConnection] { model.scopedConnections.filter(\.isOnline) }

    private var loadKey: String {
        "\(filter)|\(connections.map(\.id))"
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.explorePath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    header
                    content
                }
                .padding(.bottom, 24)
            }
            .refreshable { await reload() }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .appDestinations()
            .task(id: loadKey) { await reload() }
            .task(id: connections.map(\.id)) { await loadOptions() }
            .sheet(isPresented: $showDayPicker) { DayPickerSheet(day: $filter.day) }
        }
    }

    // MARK: Header and filters

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                LargeTitle(text: L("Explore"))
                Spacer()
            }
            .padding(.horizontal, 16)
            if model.orderedConnections.count > 1 {
                HStack { ServerSwitcher(); Spacer() }.padding(.horizontal, 16)
            }
            filters
        }
        .padding(.top, 8)
    }

    private var cameraOptions: [CameraConfig] {
        var seen = Set<String>()
        return connections.flatMap(\.cameras).filter { seen.insert($0.name).inserted }
    }

    private var zoneOptions: [String] {
        var zones = Set<String>()
        for cam in cameraOptions where filter.cameras.isEmpty || filter.cameras.contains(cam.name) {
            zones.formUnion(cam.zones?.keys ?? [:].keys)
        }
        zones.formUnion(filter.zones)
        return zones.sorted()
    }

    private var labelOptions: [String] {
        var set = Set(knownLabels)
        set.formUnion(rows.map(\.label))
        set.formUnion(filter.labels)
        return set.sorted { FrigateFormat.labelName($0) < FrigateFormat.labelName($1) }
    }

    private var subLabelOptions: [String] {
        Set(knownSubLabels).union(filter.subLabels).sorted()
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    option(L("All cameras"), filter.cameras.isEmpty) { filter.cameras = [] }
                    ForEach(cameraOptions, id: \.name) { cam in
                        option(cam.displayName, filter.cameras.contains(cam.name)) { toggle(&filter.cameras, cam.name) }
                    }
                } label: {
                    Chip(title: filter.cameras.isEmpty ? L("Cameras") : (filter.cameras.count == 1
                            ? cameraOptions.first { filter.cameras.contains($0.name) }?.displayName ?? L("\(filter.cameras.count) cameras")
                            : L("\(filter.cameras.count) cameras")),
                         outlined: !filter.cameras.isEmpty, trailingChevron: true)
                }
                Menu {
                    option(L("All labels"), filter.labels.isEmpty) { filter.labels = [] }
                    ForEach(labelOptions, id: \.self) { l in
                        option(FrigateFormat.labelName(l).capitalizedFirst, filter.labels.contains(l)) { toggle(&filter.labels, l) }
                    }
                } label: {
                    Chip(title: filter.labels.isEmpty ? L("Labels") : filter.labels.map { FrigateFormat.labelName($0).capitalizedFirst }.sorted().joined(separator: ", "),
                         outlined: !filter.labels.isEmpty, trailingChevron: true)
                }
                if !zoneOptions.isEmpty {
                    Menu {
                        option(L("All zones"), filter.zones.isEmpty) { filter.zones = [] }
                        ForEach(zoneOptions, id: \.self) { z in
                            option(FrigateFormat.prettyName(z), filter.zones.contains(z)) { toggle(&filter.zones, z) }
                        }
                    } label: {
                        Chip(title: filter.zones.isEmpty ? L("Zones") : filter.zones.map(FrigateFormat.prettyName).sorted().joined(separator: ", "),
                             outlined: !filter.zones.isEmpty, trailingChevron: true)
                    }
                }
                if !subLabelOptions.isEmpty {
                    Menu {
                        option(L("All sub labels"), filter.subLabels.isEmpty) { filter.subLabels = [] }
                        ForEach(subLabelOptions, id: \.self) { s in
                            option(s, filter.subLabels.contains(s)) { toggle(&filter.subLabels, s) }
                        }
                    } label: {
                        Chip(title: filter.subLabels.isEmpty ? L("Sub labels") : filter.subLabels.sorted().joined(separator: ", "),
                             outlined: !filter.subLabels.isEmpty, trailingChevron: true)
                    }
                }
                Menu {
                    option(L("All dates"), filter.day == nil) { filter.day = nil }
                    let today = Calendar.current.startOfDay(for: Date())
                    option(L("Today"), filter.day == today) { filter.day = today }
                    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
                    option(L("Yesterday"), filter.day == yesterday) { filter.day = yesterday }
                    Button { showDayPicker = true } label: { Label("Pick date…", systemImage: "calendar") }
                } label: {
                    Chip(title: filter.day.map(FrigateFormat.dayTitle) ?? L("All dates"), outlined: filter.day != nil, trailingChevron: true)
                }
                Menu {
                    option(L("Newest first"), filter.sort == .newest) { filter.sort = .newest }
                    option(L("Oldest first"), filter.sort == .oldest) { filter.sort = .oldest }
                    option(L("Highest score"), filter.sort == .score) { filter.sort = .score }
                } label: {
                    Chip(title: sortTitle, outlined: filter.sort != .newest, systemImage: "arrow.up.arrow.down")
                }
                if filter.isActive {
                    Button { filter = ExploreFilter() } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 34, height: 34)
                            .background(Theme.card, in: Circle())
                            .overlay(Circle().stroke(Theme.controlBorder, lineWidth: 1))
                    }
                    .accessibilityLabel("Clear filters")
                }
            }
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    private var sortTitle: String {
        switch filter.sort {
        case .newest: return L("Newest first")
        case .oldest: return L("Oldest first")
        case .score: return L("Highest score")
        }
    }

    private func toggle(_ set: inout Set<String>, _ value: String) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }

    @ViewBuilder
    private func option(_ title: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if on { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let empty = filter.showsGrid ? grid.isEmpty : rows.isEmpty
        if connections.isEmpty {
            EmptyStateView(systemImage: "wifi.slash", title: L("No servers online"), message: L("Tracked objects appear when a server is reachable."))
        } else if loading && empty {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        } else if let loadError, empty {
            EmptyStateView(systemImage: "exclamationmark.triangle", title: L("Could not load objects"), message: loadError)
        } else if empty {
            EmptyStateView(systemImage: "magnifyingglass", title: L("Nothing found"), message: L("No tracked objects match these filters."))
        } else if filter.showsGrid {
            gridView
        } else {
            ForEach(rows) { row in labelRow(row) }
        }
    }

    private func labelRow(_ row: LabelRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                filter.labels = [row.label]
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(FrigateFormat.labelName(row.label).capitalizedFirst)
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text)
                    if let count = row.count {
                        Text(L("\(count) tracked objects")).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(row.entries) { entry in
                        NavigationLink(value: ObjectRoute(serverID: entry.serverID, event: entry.event)) {
                            ObjectTile(entry: entry, showLabel: false)
                                .frame(width: 128, height: 128)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 6)
    }

    private var gridView: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(grid) { entry in
                    NavigationLink(value: ObjectRoute(serverID: entry.serverID, event: entry.event)) {
                        ObjectTile(entry: entry, showLabel: true)
                            .aspectRatio(1, contentMode: .fit)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if entry.id == grid.last?.id, canLoadMore, !loading { Task { await loadMore() } }
                    }
                }
            }
            if loading && !grid.isEmpty { ProgressView().frame(height: 44) }
        }
        .padding(.horizontal, 16)
    }

    // MARK: Loading

    private var dayRange: (after: Date?, before: Date?) {
        guard let day = filter.day else { return (nil, nil) }
        return (day, Calendar.current.date(byAdding: .day, value: 1, to: day))
    }

    private func loadOptions() async {
        var labels = Set<String>(), subs = Set<String>()
        for conn in connections {
            guard let client = conn.client else { continue }
            labels.formUnion((try? await client.trackedLabels()) ?? [])
            subs.formUnion((try? await client.subLabels()) ?? [])
        }
        knownLabels = Array(labels)
        knownSubLabels = Array(subs)
    }

    /// Server and the cameras to ask it for, or nil when the camera filter excludes it.
    private func targets() -> [(conn: ServerConnection, client: FrigateClient, cameras: [String]?)] {
        connections.compactMap { conn in
            guard let client = conn.client else { return nil }
            if filter.cameras.isEmpty { return (conn, client, nil) }
            let cams = conn.cameras.map(\.name).filter { filter.cameras.contains($0) }
            return cams.isEmpty ? nil : (conn, client, cams)
        }
    }

    private func search(labels: [String]?, before: Date?, after: Date?, limit: Int) async throws -> [ExploreEntry] {
        let f = filter
        let zones = f.zones.isEmpty ? nil : Array(f.zones)
        let subs = f.subLabels.isEmpty ? nil : Array(f.subLabels)
        return try await withThrowingTaskGroup(of: [ExploreEntry].self) { group in
            for t in targets() {
                let id = t.conn.server.id
                let client = t.client, cams = t.cameras
                group.addTask {
                    try await client.searchEvents(cameras: cams, labels: labels, zones: zones, subLabels: subs,
                                                  after: after, before: before, sort: f.sort, limit: limit)
                        .map { ExploreEntry(serverID: id, event: $0) }
                }
            }
            var all: [ExploreEntry] = []
            for try await part in group { all += part }
            return sorted(all)
        }
    }

    private func sorted(_ list: [ExploreEntry]) -> [ExploreEntry] {
        switch filter.sort {
        case .newest: return list.sorted { $0.event.startTime > $1.event.startTime }
        case .oldest: return list.sorted { $0.event.startTime < $1.event.startTime }
        case .score: return list.sorted { ($0.event.bestScore ?? 0) > ($1.event.bestScore ?? 0) }
        }
    }

    private func reload() async {
        loading = true
        loadError = nil
        do {
            if filter.showsGrid {
                let range = dayRange
                let result = try await search(labels: filter.labels.isEmpty ? nil : Array(filter.labels),
                                              before: range.before, after: range.after, limit: pageSize)
                grid = result
                // Frigate pages by time; sorting by score shows the best matches only.
                canLoadMore = filter.sort != .score && result.count >= pageSize
            } else {
                rows = try await loadRows()
            }
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }

    private func loadRows() async throws -> [LabelRow] {
        var byLabel: [String: LabelRow] = [:]
        if filter.isPlain {
            // One request per server: the latest objects of each label plus the totals.
            for t in targets() {
                let items = try await t.client.exploreEvents(limit: 10)
                for item in items {
                    var row = byLabel[item.event.label] ?? LabelRow(label: item.event.label, count: 0, entries: [])
                    row.entries.append(ExploreEntry(serverID: t.conn.server.id, event: item.event))
                    byLabel[item.event.label] = row
                }
                // event_count repeats on every item of a label; add it once per server.
                for (label, count) in Dictionary(items.map { ($0.event.label, $0.eventCount ?? 0) }, uniquingKeysWith: { a, _ in a }) {
                    let current = byLabel[label]?.count ?? 0
                    byLabel[label]?.count = current + count
                }
            }
        } else {
            let range = dayRange
            // Ask the servers which labels exist; the filter options may not have loaded yet.
            var found = Set(knownLabels)
            for t in targets() { found.formUnion((try? await t.client.trackedLabels()) ?? []) }
            let labels = Array(found)
            try await withThrowingTaskGroup(of: (String, [ExploreEntry]).self) { group in
                for label in labels {
                    group.addTask { (label, try await search(labels: [label], before: range.before, after: range.after, limit: 10)) }
                }
                for try await (label, entries) in group where !entries.isEmpty {
                    byLabel[label] = LabelRow(label: label, count: nil, entries: entries)
                }
            }
        }
        return byLabel.values
            .map { row in
                var r = row
                r.entries = Array(r.entries.sorted { $0.event.startTime > $1.event.startTime }.prefix(10))
                return r
            }
            .sorted {
                if let a = $0.count, let b = $1.count, a != b { return a > b }
                return ($0.entries.first?.event.startTime ?? 0) > ($1.entries.first?.event.startTime ?? 0)
            }
    }

    private func loadMore() async {
        guard let last = grid.last?.event.startTime else { return }
        loading = true
        let range = dayRange
        let labels = filter.labels.isEmpty ? nil : Array(filter.labels)
        let more: [ExploreEntry]?
        if filter.sort == .oldest {
            more = try? await search(labels: labels, before: range.before, after: Date(timeIntervalSince1970: last), limit: pageSize)
        } else {
            more = try? await search(labels: labels, before: Date(timeIntervalSince1970: last), after: range.after, limit: pageSize)
        }
        if let more {
            let known = Set(grid.map(\.id))
            let fresh = more.filter { !known.contains($0.id) }
            grid += fresh
            canLoadMore = !fresh.isEmpty
        }
        loading = false
    }
}

/// Square thumbnail of a tracked object with its age, like the tiles on Frigate's Explore page.
struct ObjectTile: View {
    let entry: ExploreEntry
    var showLabel: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let conn = model.connection(for: entry.serverID)
        let event = entry.event
        Color.clear
            .overlay {
                RemoteImage(url: conn?.client?.thumbnailURL(for: event), session: conn?.client?.session ?? .shared)
            }
            .overlay(alignment: .topLeading) {
                if showLabel {
                    HStack(spacing: 4) {
                        LabelTag(label: event.label)
                        if let score = event.bestScore {
                            Text("\(Int((score * 100).rounded()))%")
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    .padding(6)
                }
            }
            .overlay(alignment: .bottom) {
                HStack(spacing: 4) {
                    if showLabel {
                        Text(conn?.config?.cameras[event.camera]?.displayName ?? FrigateFormat.prettyName(event.camera))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                    } else {
                        Spacer(minLength: 0)
                    }
                    Text(FrigateFormat.relative(Date(timeIntervalSince1970: event.startTime)))
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Sheet with a calendar for picking one day.
struct DayPickerSheet: View {
    @Binding var day: Date?
    @Environment(\.dismiss) private var dismiss
    @State private var picked = Date()

    var body: some View {
        NavigationStack {
            DatePicker("Date", selection: $picked, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding(.horizontal)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { day = Calendar.current.startOfDay(for: picked); dismiss() }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .presentationDetents([.medium, .large])
        .onAppear { picked = day ?? Date() }
    }
}
