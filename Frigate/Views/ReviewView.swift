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
    @State private var serverFilter: UUID? = nil
    @State private var cameraFilter: Set<String> = []
    @State private var labelFilter: Set<String> = []
    @State private var zoneFilter: Set<String> = []
    @State private var unreviewedOnly = true
    @State private var entries: [ReviewEntry] = []
    @State private var loading = false
    @State private var canLoadMore = false
    @State private var loadError: String?

    private let pageSize = 60

    private var connections: [ServerConnection] {
        let all = model.reviewConnections.filter(\.isOnline)
        guard let serverFilter else { return all }
        return all.filter { $0.server.id == serverFilter }
    }

    private var filterKey: String {
        "\(kind)|\(serverFilter?.uuidString ?? "")|\(cameraFilter.sorted())|\(labelFilter.sorted())|\(zoneFilter.sorted())|\(unreviewedOnly)|\(model.reviewConnections.map { "\($0.id)\($0.isOnline)" })"
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.reviewPath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
                    header
                    if kind == .motion {
                        MotionOverview(connections: connections, cameraFilter: cameraFilter)
                    } else {
                        list
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .refreshable { await reload() }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .appDestinations()
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
            SegmentedBar(options: [Kind.alert, .detection, .motion], selection: $kind) { k in
                switch k {
                case .alert: return countTitle(L("Alerts"), connections.reduce(0) { $0 + ($1.summary?.last24Hours?.unreviewedAlerts ?? 0) })
                case .detection: return countTitle(L("Detections"), connections.reduce(0) { $0 + ($1.summary?.last24Hours?.unreviewedDetections ?? 0) })
                case .motion: return L("Motion")
                }
            }
            filters
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
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
            HStack(spacing: 8) {
                if model.combinedReview && model.orderedConnections.count > 1 {
                    Menu {
                        Button { serverFilter = nil } label: { checkLabel(L("All servers"), serverFilter == nil) }
                        ForEach(model.orderedConnections) { c in
                            Button { serverFilter = c.server.id } label: { checkLabel(c.server.name, serverFilter == c.server.id) }
                        }
                    } label: {
                        Chip(title: serverFilter.flatMap { model.connection(for: $0)?.server.name } ?? L("All servers"), trailingChevron: true)
                    }
                }
                Menu {
                    Button { cameraFilter = [] } label: { checkLabel(L("All cameras"), cameraFilter.isEmpty) }
                    ForEach(availableCameras, id: \.camera.name) { pair in
                        Button {
                            if cameraFilter.contains(pair.camera.name) { cameraFilter.remove(pair.camera.name) } else { cameraFilter.insert(pair.camera.name) }
                        } label: { checkLabel(pair.camera.displayName, cameraFilter.contains(pair.camera.name)) }
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
                            ForEach(availableZones, id: \.self) { z in
                                Button {
                                    if zoneFilter.contains(z) { zoneFilter.remove(z) } else { zoneFilter.insert(z) }
                                } label: { checkLabel(FrigateFormat.prettyName(z), zoneFilter.contains(z)) }
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
                ForEach(group.entries) { entry in
                    if let conn = model.connection(for: entry.serverID) {
                        NavigationLink(value: EventRoute(serverID: entry.serverID, review: entry.item)) {
                            ReviewRow(entry: entry, conn: conn, showServer: model.orderedConnections.count > 1)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if !entry.item.hasBeenReviewed {
                                Button { Task { await markReviewed([entry]) } } label: { Label("Mark reviewed", systemImage: "checkmark") }
                            }
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
        return try await withThrowingTaskGroup(of: [ReviewEntry].self) { group in
            for conn in connections {
                guard let client = conn.client else { continue }
                let id = conn.server.id
                let known = Set(conn.cameras.map(\.name))
                let serverCams = cams?.filter { known.contains($0) }
                if let serverCams, serverCams.isEmpty { continue }
                group.addTask {
                    let items = try await client.reviews(cameras: serverCams, labels: labels, zones: zones, severity: severity,
                                                         reviewed: reviewed, before: before, limit: pageSize)
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
        do {
            let result = try await fetch(before: nil)
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
                await conn.refresh()
            } catch {
                loadError = error.localizedDescription
            }
        }
        if unreviewedOnly {
            withAnimation { entries.removeAll { $0.item.hasBeenReviewed } }
        }
    }

    private func markAllReviewed() async {
        await markReviewed(entries)
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
                    Text(item.inProgress ? "LIVE" : FrigateFormat.duration(item.duration))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(item.inProgress ? Theme.recording : .black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    ForEach(item.labels.prefix(3), id: \.self) { LabelTag(label: $0) }
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
