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
    static func load(_ connections: [ServerConnection], cameras: Set<String> = []) async -> [ExportEntry] {
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
    }

    /// The export as a local file, for sharing or Photos.
    static func download(_ entry: ExportEntry, model: AppModel) async throws -> URL {
        guard let client = model.connection(for: entry.serverID)?.client else { throw FrigateError.invalidURL }
        let base = entry.export.name.isEmpty ? entry.export.id : entry.export.name
        let safe = base.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
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
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var entries: [ExportEntry] = []
    @State private var loading = true
    @State private var renaming: ExportEntry?
    @State private var newName = ""
    @State private var deleting: ExportEntry?
    @State private var errorMessage: String?

    private var connections: [ServerConnection] { model.scopedConnections.filter(\.isOnline) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ScreenTitle(text: L("Exports"), showsBack: !isSection).padding(.top, 8)
                    if loading && entries.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                    } else if entries.isEmpty {
                        EmptyStateView(systemImage: "film.stack", title: L("No exports"),
                                       message: L("Clips you export in Frigate, or save to Frigate from playback, appear here."))
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 280 : 160), spacing: 12)], spacing: 14) {
                            ForEach(entries) { entry in
                                NavigationLink(value: ExportRoute(serverID: entry.serverID, export: entry.export)) {
                                    ExportTile(entry: entry)
                                }
                                .buttonStyle(.plain)
                                .disabled(entry.export.inProgress)
                                .contextMenu {
                                    Button { newName = entry.export.name; renaming = entry } label: { Label("Rename", systemImage: "pencil") }
                                    Button(role: .destructive) { deleting = entry } label: { DestructiveMenuLabel(title: "Delete") }
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
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func load() async {
        entries = await ExportsLoader.load(connections)
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
                    Group { if working { ProgressView() } else { HeaderIconLabel(systemName: "square.and.arrow.up") } }
                }
                .buttonStyle(.plain)
                .disabled(working)
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
        .overlay(alignment: .top) { ExportToast(state: exporter.state) }
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
        working = true
        defer { working = false }
        do { share = ShareItem(items: [try await ExportActions.download(entry, model: model)]) }
        catch { errorMessage = error.localizedDescription }
    }

    private func saveToPhotos() async {
        exporter.state = .working(L("Saving to Photos…"))
        do {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                exporter.state = .failed(L("Allow Tender to add photos in Settings to save clips."))
                return
            }
            let file = try await ExportActions.download(entry, model: model)
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
    @State private var exportCount: Int?

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
            .task {
                exportCount = await ExportsLoader.load(model.scopedConnections.filter(\.isOnline)).count
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
