import Photos
import SwiftUI

/// An export on one of the servers.
struct ExportEntry: Identifiable, Hashable {
    let serverID: UUID
    let export: FrigateExport
    var id: String { "\(serverID)/\(export.id)" }
}

/// All exports, as a grid (from the Exports row in Explore).
struct ExportsRoute: Hashable {}

/// One export, to watch, share, rename or delete.
struct ExportRoute: Hashable {
    let serverID: UUID
    let export: FrigateExport
}

/// Loads the exports of every server in view, newest first.
@MainActor
enum ExportsLoader {
    static func load(_ connections: [ServerConnection], cameras: Set<String> = [], deleted: Set<String> = []) async -> [ExportEntry] {
        var all: [ExportEntry] = []
        await withTaskGroup(of: [ExportEntry].self) { group in
            for conn in connections {
                guard let client = conn.client else { continue }
                let id = conn.server.id
                group.addTask {
                    ((try? await client.exports()) ?? []).map { ExportEntry(serverID: id, export: $0) }
                }
            }
            for await part in group { all += part }
        }
        if !cameras.isEmpty { all = all.filter { cameras.contains($0.export.camera) } }
        all.removeAll { deleted.contains($0.id) }
        return all.sorted { $0.export.date > $1.export.date }
    }
}

// MARK: - Tile

/// An export as a 16:9 picture with its name, camera and date.
struct ExportTile: View {
    let entry: ExportEntry
    @Environment(AppModel.self) private var model

    var body: some View {
        let conn = model.connection(for: entry.serverID)
        let export = entry.export
        VStack(alignment: .leading, spacing: 5) {
            Color.black
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    if export.inProgress {
                        VStack(spacing: 6) {
                            ProgressView().tint(.white)
                            Text("Exporting…").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                        }
                    } else {
                        RemoteImage(url: conn?.client?.exportThumbnailURL(export), session: conn?.client?.session ?? .shared)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !export.inProgress {
                        Image(systemName: "play.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 24, height: 24).background(.black.opacity(0.6), in: Circle()).padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cardBorder, lineWidth: 1))
            Text(export.name.isEmpty ? L("Export") : export.name)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            Text(subtitle(conn))
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private func subtitle(_ conn: ServerConnection?) -> String {
        let cam = conn?.config?.cameras[entry.export.camera]?.displayName ?? FrigateFormat.prettyName(entry.export.camera)
        let day = FrigateFormat.dayTitle(entry.export.created)
        return "\(cam) · \(day) \(FrigateFormat.time(entry.export.created))"
    }
}

// MARK: - Actions shared by the grid and the player

@MainActor
enum ExportActions {
    static func rename(_ entry: ExportEntry, to name: String, model: AppModel) async throws {
        guard let client = model.connection(for: entry.serverID)?.client else { return }
        try await client.renameExport(entry.export.id, to: name)
    }

    static func delete(_ entry: ExportEntry, model: AppModel) async throws {
        guard let client = model.connection(for: entry.serverID)?.client else { return }
        try await client.deleteExport(entry.export.id)
        withAnimation(.easeOut(duration: 0.2)) { _ = model.deletedExports.insert(entry.id) }
    }

    /// The export as a local file, for sharing or Photos; with progress in `exporter`'s pill.
    static func download(_ entry: ExportEntry, model: AppModel, exporter: ClipExporter? = nil) async throws -> URL {
        guard let client = model.connection(for: entry.serverID)?.client else { throw FrigateError.invalidURL }
        let base = entry.export.name.isEmpty ? entry.export.id : entry.export.name
        let safe = base.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        if let exporter {
            return try await exporter.downloadFile(client: client, url: client.exportFileURL(entry.export), fileName: "\(safe).mp4")
        }
        return try await client.download(client.exportFileURL(entry.export), fileName: "\(safe).mp4")
    }
}

/// Asks for a new name; shared by the grid and the player.
private struct RenameAlert: ViewModifier {
    @Binding var target: ExportEntry?
    @Binding var name: String
    let onRename: (ExportEntry, String) -> Void

    func body(content: Content) -> some View {
        content.alert("Rename export", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) { target = nil }
            Button("Rename") {
                if let t = target, !name.trimmingCharacters(in: .whitespaces).isEmpty { onRename(t, name.trimmingCharacters(in: .whitespaces)) }
                target = nil
            }
        }
    }
}

// MARK: - Grid

/// Exports as a section of its own in the iPad and Mac rail.
struct ExportsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.exportsPath) {
            ExportsView(isSection: true).appDestinations()
        }
    }
}

struct ExportsView: View {
    /// In the rail (iPad, Mac): no back button, the title where other sections have theirs.
    var isSection = false
    /// One case's exports; nil for all of them, with the cases as folders on top.
    var caseRoute: ExportCaseRoute? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var entries: [ExportEntry] = []
    @State private var cases: [ExportCaseEntry] = []
    @State private var loading = true
    @State private var renaming: ExportEntry?
    @State private var newName = ""
    @State private var deleting: ExportEntry?
    @State private var errorMessage: String?
    /// A new case to create on this server, and (from an export's menu) the export to file in it.
    @State private var creatingCaseOn: UUID?
    @State private var creatingCaseFor: ExportEntry?
    @State private var caseName = ""
    @State private var renamingCase: ExportCaseEntry?
    @State private var deletingCase: ExportCaseEntry?
    /// The case an export is being dragged over.
    @State private var dropTarget: String?
    /// The export being dragged.
    @State private var dragging: ExportEntry?

    private var connections: [ServerConnection] { model.scopedConnections.filter(\.isOnline) }
    /// Servers that have cases (Frigate 0.18 and later).
    private var caseServers: [ServerConnection] { connections.filter { $0.client?.servesCases == true } }
    /// Without what was just deleted, here or in the player.
    private var visible: [ExportEntry] {
        let all = entries.filter { !model.deletedExports.contains($0.id) }
        if let caseRoute {
            return all.filter { $0.serverID == caseRoute.serverID && caseID(of: $0) == caseRoute.exportCase.id }
        }
        // Outside a case (or in one this app does not know): the cases show as folders above.
        let known = Set(cases.map(\.id))
        return all.filter { e in caseID(of: e).map { !known.contains("\(e.serverID)/\($0)") } ?? true }
    }
    private var currentCase: ExportCaseEntry? {
        caseRoute.flatMap { r in cases.first { $0.serverID == r.serverID && $0.exportCase.id == r.exportCase.id } }
            ?? caseRoute.map { ExportCaseEntry(serverID: $0.serverID, exportCase: $0.exportCase) }
    }
    /// Each load gets a number; a slower, older one that finishes later is dropped.
    @State private var loadCount = 0

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: sizeClass == .regular ? 280 : 160), spacing: 12)] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    titleBar.padding(.top, 8)
                    if loading && entries.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                    } else {
                        if caseRoute == nil && !cases.isEmpty {
                            SectionLabel(text: L("Cases"))
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(cases) { c in
                                    NavigationLink(value: ExportCaseRoute(serverID: c.serverID, exportCase: c.exportCase)) {
                                        ExportCaseTile(entry: c, exports: exports(in: c),
                                                       serverName: caseServers.count > 1 ? model.connection(for: c.serverID)?.server.name : nil)
                                            .overlay(alignment: .top) { dropOverlay(c) }
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu { caseMenu(c) }
                                    // Drop exports on a case to file them there; a case on
                                    // another server shows that it cannot take them.
                                    .onDrop(of: [.text], delegate: CaseDropDelegate(
                                        id: c.id, accepts: { accepts(c) }, target: $dropTarget,
                                        perform: { id in
                                            guard let e = entries.first(where: { $0.id == id }) ?? dragging else { return }
                                            drop(e, on: c)
                                        }))
                                }
                            }
                            if !visible.isEmpty { SectionLabel(text: L("Not in a case")).padding(.top, 8) }
                        }
                        if visible.isEmpty && (caseRoute != nil || cases.isEmpty) {
                            EmptyStateView(systemImage: caseRoute == nil ? "film.stack" : "folder",
                                           title: caseRoute == nil ? L("No exports") : L("No exports in this case"),
                                           message: caseRoute == nil
                                               ? L("Clips you export in Frigate, or save to Frigate from playback, appear here.")
                                               : L("Long-press an export to move it into this case."))
                        } else {
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(visible) { entry in
                                    NavigationLink(value: ExportRoute(serverID: entry.serverID, export: entry.export)) {
                                        ExportTile(entry: entry)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(entry.export.inProgress)
                                    .contextMenu { exportMenu(entry) }
                                    .onDrag {
                                        dragging = entry
                                        return NSItemProvider(object: entry.id as NSString)
                                    } preview: {
                                        ExportTile(entry: entry).frame(width: 180).environment(model)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .refreshable { await load() }
        }
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        // While an export is being made, look again until it is done.
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(entries.contains(where: \.export.inProgress) ? 3 : 30))
            }
        }
        .modifier(RenameAlert(target: $renaming, name: $newName) { entry, name in
            Task {
                do { try await ExportActions.rename(entry, to: name, model: model); await load() }
                catch { errorMessage = error.localizedDescription }
            }
        })
        .alert("Delete this export?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                guard let entry = deleting else { return }
                Task {
                    do { try await ExportActions.delete(entry, model: model); await load() }
                    catch { errorMessage = error.localizedDescription }
                }
            }
        } message: { Text("The video is removed from the Frigate server.") }
        .alert("New case", isPresented: Binding(get: { creatingCaseOn != nil }, set: { if !$0 { creatingCaseOn = nil; creatingCaseFor = nil } })) {
            TextField("Case name", text: $caseName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createCase() }
        } message: {
            if let e = creatingCaseFor { Text("\(e.export.name.isEmpty ? L("The export") : e.export.name) goes into it.") }
        }
        .alert("Rename case", isPresented: Binding(get: { renamingCase != nil }, set: { if !$0 { renamingCase = nil } })) {
            TextField("Case name", text: $caseName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { renameCase() }
        }
        .alert("Delete this case?", isPresented: Binding(get: { deletingCase != nil }, set: { if !$0 { deletingCase = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Delete case only") { deleteCase(withExports: false) }
            Button("Delete case and exports", role: .destructive) { deleteCase(withExports: true) }
        } message: {
            let n = deletingCase.map { exports(in: $0).count } ?? 0
            Text(n == 0 ? L("The case is empty.")
                        : L("Its \(n) exports stay available outside a case, unless you delete them too."))
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    // MARK: Title bar

    private var titleBar: some View {
        HStack {
            ScreenTitle(text: currentCase.map { $0.exportCase.name.isEmpty ? L("Case") : $0.exportCase.name } ?? L("Exports"),
                        showsBack: caseRoute != nil || !isSection)
            Spacer()
            if let c = currentCase {
                Menu { caseMenu(c) } label: { HeaderIconLabel(systemName: "ellipsis") }
                    .accessibilityLabel("More options")
            } else if caseServers.count == 1, let id = caseServers.first?.server.id {
                Button { startNewCase(on: id) } label: { HeaderIconLabel(systemName: "folder.badge.plus") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New case")
            } else if caseServers.count > 1 {
                Menu {
                    Section("New case on") {
                        ForEach(caseServers) { c in Button(c.server.name) { startNewCase(on: c.server.id) } }
                    }
                } label: { HeaderIconLabel(systemName: "folder.badge.plus") }
                    .accessibilityLabel("New case")
            }
        }
    }

    // MARK: Menus

    @ViewBuilder
    private func exportMenu(_ entry: ExportEntry) -> some View {
        Button { newName = entry.export.name; renaming = entry } label: { Label("Rename", systemImage: "pencil") }
        if model.connection(for: entry.serverID)?.client?.servesCases == true {
            Menu {
                ForEach(cases.filter { $0.serverID == entry.serverID && $0.exportCase.id != caseID(of: entry) }) { c in
                    Button { move(entry, to: c.exportCase.id) } label: { Label(c.exportCase.name, systemImage: "folder") }
                }
                Button { creatingCaseFor = entry; startNewCase(on: entry.serverID) } label: {
                    Label("New case…", systemImage: "folder.badge.plus")
                }
                if caseID(of: entry) != nil {
                    Divider()
                    Button { move(entry, to: nil) } label: { Label("Remove from case", systemImage: "tray.and.arrow.up") }
                }
            } label: { Label("Move to case", systemImage: "folder") }
        }
        Divider()
        Button(role: .destructive) { deleting = entry } label: { DestructiveMenuLabel(title: "Delete") }
    }

    @ViewBuilder
    private func caseMenu(_ c: ExportCaseEntry) -> some View {
        Button { caseName = c.exportCase.name; renamingCase = c } label: { Label("Rename case", systemImage: "pencil") }
        Divider()
        Button(role: .destructive) { deletingCase = c } label: { DestructiveMenuLabel(title: "Delete case") }
    }

    // MARK: Actions

    private func exports(in c: ExportCaseEntry) -> [ExportEntry] {
        entries.filter { $0.serverID == c.serverID && caseID(of: $0) == c.exportCase.id && !model.deletedExports.contains($0.id) }
    }

    private func client(_ serverID: UUID) -> FrigateClient? { model.connection(for: serverID)?.client }

    private func startNewCase(on serverID: UUID) {
        caseName = ""
        creatingCaseOn = serverID
    }

    private func createCase() {
        guard let serverID = creatingCaseOn, let client = client(serverID) else { return }
        let name = caseName.trimmingCharacters(in: .whitespaces)
        let export = creatingCaseFor
        guard !name.isEmpty else { return }
        Task {
            do {
                let created = try await client.createExportCase(name: name)
                if let export { try await client.moveExports([export.export.id], toCase: created.id) }
                await load()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func renameCase() {
        guard let c = renamingCase, let client = client(c.serverID) else { return }
        let name = caseName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            do { try await client.renameExportCase(c.exportCase.id, to: name); await load() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func deleteCase(withExports: Bool) {
        guard let c = deletingCase, let client = client(c.serverID) else { return }
        let gone = withExports ? exports(in: c).map(\.id) : []
        Task {
            do {
                try await client.deleteExportCase(c.exportCase.id, deletingExports: withExports)
                model.deletedExports.formUnion(gone)
                // Inside the case that is gone: back to all exports.
                if caseRoute != nil { closePresented(dismiss) } else { await load() }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    /// Whether the export being dragged can go in this case: same server, not already in it.
    private func accepts(_ c: ExportCaseEntry) -> Bool {
        guard let d = dragging else { return false }
        return d.serverID == c.serverID && caseID(of: d) != c.exportCase.id
    }

    /// Lit while an export is dragged over the case; red with the reason when it cannot go in.
    @ViewBuilder
    private func dropOverlay(_ c: ExportCaseEntry) -> some View {
        if dropTarget == c.id {
            let ok = accepts(c)
            RoundedRectangle(cornerRadius: 10)
                .stroke(ok ? Theme.accent : Theme.destructive, lineWidth: 3)
                .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(ok ? 0 : 0.55)))
                .overlay {
                    if !ok {
                        Label(dragging?.serverID != c.serverID ? L("Other server") : L("Already in this case"),
                              systemImage: "nosign")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
        }
    }

    private func drop(_ entry: ExportEntry, on c: ExportCaseEntry) {
        dragging = nil
        guard entry.serverID == c.serverID, caseID(of: entry) != c.exportCase.id else { return }
        move(entry, to: c.exportCase.id)
    }

    /// The export's case, as just moved here or in another exports screen.
    private func caseID(of e: ExportEntry) -> String? {
        if let moved = model.movedExports[e.id] { return moved.isEmpty ? nil : moved }
        return e.export.caseID
    }

    private func move(_ entry: ExportEntry, to caseID: String?) {
        guard let client = client(entry.serverID) else { return }
        // Shown in its new place at once; the server follows.
        withAnimation(.easeOut(duration: 0.2)) { model.movedExports[entry.id] = caseID ?? "" }
        Task {
            do { try await client.moveExports([entry.export.id], toCase: caseID) }
            catch {
                model.movedExports[entry.id] = nil
                errorMessage = error.localizedDescription
            }
            await load()
        }
    }

    private func load() async {
        loadCount += 1
        let mine = loadCount
        async let loadedEntries = ExportsLoader.load(connections)
        async let loadedCases = ExportCasesLoader.load(connections)
        let (e, c) = await (loadedEntries, loadedCases)
        guard mine == loadCount else { return }
        // Moves the server now shows are done.
        for x in e where model.movedExports[x.id] == (x.export.caseID ?? "") { model.movedExports[x.id] = nil }
        entries = e
        cases = c
        loading = false
    }
}

// MARK: - Player

struct ExportPlayerView: View {
    let route: ExportRoute
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var player = RecordingPlayer()
    @State private var name: String
    @State private var overlayVisible = true
    @State private var overlayToken = 0
    @State private var renaming: ExportEntry?
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var share: ShareItem?
    @State private var working = false
    @State private var exporter = ClipExporter()
    @State private var errorMessage: String?

    init(route: ExportRoute) {
        self.route = route
        _name = State(initialValue: route.export.name)
    }

    private var entry: ExportEntry { ExportEntry(serverID: route.serverID, export: route.export) }
    private var conn: ServerConnection? { model.connection(for: route.serverID) }
    private var camera: CameraConfig? { conn?.config?.cameras[route.export.camera] }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { BackButtonLabel() }
                    .accessibilityLabel("Back")
                Spacer()
                Button { Task { await shareFile() } } label: {
                    HeaderIconLabel(systemName: "square.and.arrow.up", loading: working)
                }
                .buttonStyle(.plain)
                // Not disabled while loading, which would dim the spinner; `shareFile()` ignores a second tap.
                .accessibilityLabel("Share")
            }
            .headerBarPadding()
            .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    video
                    scrubber
                    info
                    actions
                }
                .frame(maxWidth: sizeClass == .regular ? 900 : .infinity)
                .frame(maxWidth: .infinity)
            }
        }
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .overlay(alignment: .top) { ExportToast(exporter: exporter) }
        .sheet(item: $share) { ShareSheet(items: $0.items) }
        .task {
            guard let client = conn?.client else { return }
            player.load(client.exportVideoURL(route.export), autoplay: true)
        }
        .task(id: overlayToken) {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, player.wantsToPlay, !player.isScrubbing else { return }
            withAnimation(.easeOut(duration: 0.25)) { overlayVisible = false }
        }
        .onChange(of: player.wantsToPlay) { _, playing in
            if !playing { withAnimation(.easeOut(duration: 0.2)) { overlayVisible = true } }
        }
        .onDisappear { player.stop() }
        .modifier(RenameAlert(target: $renaming, name: $newName) { entry, newValue in
            Task {
                do { try await ExportActions.rename(entry, to: newValue, model: model); name = newValue }
                catch { errorMessage = error.localizedDescription }
            }
        })
        .alert("Delete this export?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    do { try await ExportActions.delete(entry, model: model); dismiss() }
                    catch { errorMessage = error.localizedDescription }
                }
            }
        } message: { Text("The video is removed from the Frigate server.") }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private var video: some View {
        ZStack {
            PlayerLayerView(player: player.player)
                .zoomable()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) { overlayVisible.toggle() }
                    overlayToken += 1
                }
                .onContinuousHover { phase in
                    guard case .active = phase else { return }
                    if !overlayVisible { withAnimation(.easeOut(duration: 0.25)) { overlayVisible = true } }
                    overlayToken += 1
                }
            if let error = player.error {
                Text(error).font(.system(size: 13)).foregroundStyle(.white).padding()
            } else if player.isBuffering || player.duration == 0 {
                VideoSpinner()
            }
        }
        .aspectRatio(camera?.aspectRatio ?? 16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .overlay(alignment: .bottom) {
            if player.duration > 0 {
                PlaybackOverlayControls(player: player, large: sizeClass == .regular, onUse: { overlayToken += 1 })
                    .fadingControls(overlayVisible)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: sizeClass == .regular ? 12 : 0))
        .padding(.horizontal, sizeClass == .regular ? 16 : 0)
    }

    private var scrubber: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                let total = max(player.duration, 0.1)
                TimelineView(.animation(paused: !player.isPlaying || player.isScrubbing)) { _ in
                    let progress = min(1, player.liveTime / total)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.controlBorder).frame(height: 4)
                        Capsule().fill(Theme.accent).frame(width: progress * w, height: 4)
                        Circle().fill(.white).frame(width: 16, height: 16).offset(x: progress * w - 8)
                    }
                }
                .frame(height: 28)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in player.scrub(to: max(0, min(1, v.location.x / w)) * total) }
                    .onEnded { v in player.endScrub(at: max(0, min(1, v.location.x / w)) * total) })
            }
            .frame(height: 28)
            HStack {
                Text(FrigateFormat.duration(player.currentTime)).monospacedDigit()
                Spacer()
                Text(FrigateFormat.duration(player.duration)).monospacedDigit()
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name.isEmpty ? L("Export") : name).font(.system(size: 22, weight: .bold))
            Text("\(camera?.displayName ?? FrigateFormat.prettyName(route.export.camera)) · \(FrigateFormat.dayTitle(route.export.created)), \(FrigateFormat.time(route.export.created))")
                .font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var actions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                actionButton("Save to Photos", "square.and.arrow.down") { Task { await saveToPhotos() } }
                actionButton("Rename", "pencil") { newName = name; renaming = entry }
            }
            Button { confirmDelete = true } label: {
                Text("Delete export")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.destructive)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .card(border: Theme.controlBorder, radius: 12)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 24)
    }

    private func actionButton(_ title: LocalizedStringKey, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity).frame(height: 48)
                .card(border: Theme.controlBorder, radius: 12)
        }
        .buttonStyle(.plain)
        .disabled(working || exporter.isWorking)
    }

    private func shareFile() async {
        guard !working else { return }
        working = true
        defer { working = false }
        exporter.state = .working(L("Preparing clip…"))
        do {
            let file = try await ExportActions.download(entry, model: model, exporter: exporter)
            exporter.state = .idle
            share = ShareItem(items: [file])
        } catch {
            exporter.state = .idle
            errorMessage = error.localizedDescription
        }
    }

    private func saveToPhotos() async {
        exporter.state = .working(L("Saving to Photos…"))
        do {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                exporter.state = .failed(L("Allow Tender to add photos in Settings to save clips."))
                return
            }
            let file = try await ExportActions.download(entry, model: model, exporter: exporter)
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: file)
            }
            try? FileManager.default.removeItem(at: file)
            exporter.state = .done(L("Saved to Photos"))
        } catch {
            exporter.state = .failed(error.localizedDescription)
        }
        try? await Task.sleep(for: .seconds(2.5))
        exporter.state = .idle
    }
}

// MARK: - More (phone)

enum MoreRoute: Hashable { case exports, chat, settings }

/// The phone's fourth tab: what does not get a tab of its own. iPad and Mac show these in the rail.
struct MoreView: View {
    @Environment(AppModel.self) private var model
    @State private var exportIDs: [String]?
    private var exportCount: Int? { exportIDs.map { $0.filter { !model.deletedExports.contains($0) }.count } }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.morePath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    LargeTitle(text: L("More")).padding(.bottom, 6)
                    row(.exports, "film.stack", L("Exports"),
                        exportCount.map { $0 == 1 ? L("1 clip") : L("\($0) clips") } ?? L("Clips kept in Frigate"))
                    if !model.chatConnections.isEmpty {
                        row(.chat, "bubble.left.and.text.bubble.right", L("Chat"), L("Ask Frigate about your cameras"))
                    }
                    row(.settings, "gearshape", L("Settings"), L("Servers and live view"))
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: MoreRoute.self) { route in
                switch route {
                case .exports: ExportsView()
                case .chat: ChatView(embedded: true)
                case .settings: ServersView(embedded: true)
                }
            }
            .appDestinations()
            // Again on coming back to this list, after saving or deleting exports.
            .task(id: model.morePath.isEmpty) {
                guard model.morePath.isEmpty else { return }
                exportIDs = await ExportsLoader.load(model.scopedConnections.filter(\.isOnline)).map(\.id)
            }
        }
    }

    private func row(_ route: MoreRoute, _ icon: String, _ title: String, _ subtitle: String) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 19, weight: .medium)).foregroundStyle(Theme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .card(radius: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A case as a drop target: takes the dragged export when `accepts`, and otherwise shows the
/// system's "not allowed" sign over it. SwiftUI may keep the delegate it got when the drag
/// began, so whether it accepts is asked anew each time rather than stored.
private struct CaseDropDelegate: DropDelegate {
    let id: String
    let accepts: () -> Bool
    @Binding var target: String?
    /// Called with the dragged export's id.
    let perform: (String) -> Void

    func dropEntered(info: DropInfo) { target = id }
    func dropExited(info: DropInfo) { if target == id { target = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: accepts() ? .move : .forbidden) }
    func performDrop(info: DropInfo) -> Bool {
        target = nil
        guard accepts(), let provider = info.itemProviders(for: [.text]).first else { return false }
        let perform = perform
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = object as? String else { return }
            Task { @MainActor in perform(id) }
        }
        return true
    }
}
