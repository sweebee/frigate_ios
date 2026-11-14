import SwiftUI

/// A case on one of the servers: a folder of exports in Frigate's Exports (0.18 and later).
struct ExportCaseEntry: Identifiable, Hashable {
    let serverID: UUID
    let exportCase: FrigateExportCase
    var id: String { "\(serverID)/\(exportCase.id)" }
}

/// The exports in one case.
struct ExportCaseRoute: Hashable {
    let serverID: UUID
    let exportCase: FrigateExportCase
}

/// Loads the cases of every server in view that has them, newest first.
@MainActor
enum ExportCasesLoader {
    static func load(_ connections: [ServerConnection]) async -> [ExportCaseEntry] {
        var all: [ExportCaseEntry] = []
        await withTaskGroup(of: [ExportCaseEntry].self) { group in
            for conn in connections {
                guard let client = conn.client, client.servesCases else { continue }
                let id = conn.server.id
                group.addTask { await client.exportCases().map { ExportCaseEntry(serverID: id, exportCase: $0) } }
            }
            for await part in group { all += part }
        }
        return all.sorted { $0.exportCase.createdAt > $1.exportCase.createdAt }
    }
}

// MARK: - Tile

/// A case as a folder: the newest export's picture, its name and how many exports it holds.
struct ExportCaseTile: View {
    let entry: ExportCaseEntry
    /// Its exports, newest first.
    let exports: [ExportEntry]
    /// With cases on more than one server: which one this is on.
    var serverName: String? = nil
    @Environment(AppModel.self) private var model

    var body: some View {
        let conn = model.connection(for: entry.serverID)
        VStack(alignment: .leading, spacing: 5) {
            Color.black
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    if let first = exports.first(where: { !$0.export.inProgress }) {
                        RemoteImage(url: conn?.client?.exportThumbnailURL(first.export), session: conn?.client?.session ?? .shared)
                            .opacity(0.55)
                    }
                }
                .overlay {
                    Image(systemName: "folder.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 4)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cardBorder, lineWidth: 1))
            Text(entry.exportCase.name.isEmpty ? L("Case") : entry.exportCase.name)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            Text([exports.count == 1 ? L("1 export") : L("\(exports.count) exports"), serverName]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Saving to Frigate, with a case

/// A clip to keep as an export in Frigate, waiting for its name and case.
struct SaveToFrigateRequest: Identifiable {
    let id = UUID()
    let client: FrigateClient
    let camera: String
    let start: Double
    let end: Double
    let name: String
    /// The server's cameras. When given, the span can be changed and, on Frigate 0.18 and
    /// later, several cameras exported at once, as in Frigate's Export dialog.
    var cameras: [CameraConfig] = []
}

/// Asks for the export's name and, on servers with cases, which case to file it in. From
/// playback also the span and the cameras.
struct SaveToFrigateSheet: View {
    let request: SaveToFrigateRequest
    let exporter: ClipExporter
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var cases: [FrigateExportCase] = []
    @State private var loadingCases = true
    /// Nil: no case. "new": a new case named `newCase`.
    @State private var choice: String?
    @State private var newCase = ""
    @State private var start: Date
    @State private var end: Date
    @State private var multi = false
    @State private var selected: Set<String>
    /// Picked by hand: no longer follows what was active in the span.
    @State private var touched = false
    @State private var activity: [String: CameraActivity] = [:]
    @State private var loadingActivity = false

    struct CameraActivity { var objects = 0; var spans: [(Double, Double)] = [] }

    init(request: SaveToFrigateRequest, exporter: ClipExporter) {
        self.request = request
        self.exporter = exporter
        _name = State(initialValue: request.name)
        _start = State(initialValue: Date(timeIntervalSince1970: request.start))
        _end = State(initialValue: Date(timeIntervalSince1970: request.end))
        _selected = State(initialValue: [request.camera])
    }

    private static let newID = "\u{1}new"
    private static let maxItems = 50

    private var adjustable: Bool { !request.cameras.isEmpty }
    private var offersMulti: Bool { adjustable && request.client.servesCases && request.cameras.count > 1 }
    private var spanValid: Bool { end.timeIntervalSince(start) >= 1 }
    private var chosenCameras: [CameraConfig] {
        multi ? request.cameras.filter { selected.contains($0.name) } : []
    }

    var body: some View {
        NavigationStack {
            Form {
                if offersMulti {
                    Section {
                        Picker("Cameras", selection: $multi) {
                            Text("This camera").tag(false)
                            Text("Several cameras").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                }
                if adjustable {
                    Section {
                        DatePicker("From", selection: $start, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                        DatePicker("To", selection: $end, in: start...Date(), displayedComponents: [.date, .hourAndMinute])
                    } header: {
                        Text("Time span")
                    } footer: {
                        if spanValid { Text(FrigateFormat.shortDuration(end.timeIntervalSince(start))) }
                        else { Text("The end must be after the start.") }
                    }
                }
                if multi { cameraSection }
                Section {
                    TextField(multi ? L("Optional base name") : L("Name"), text: $name)
                } header: {
                    Text("Name")
                } footer: {
                    if multi { Text("Each export gets the camera's name after it.") }
                }
                if request.client.servesCases { caseSection }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(adjustable ? L("Export recordings") : L("Save to Frigate"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { closePresented(dismiss) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(multi ? L("Export \(chosenCameras.count)") : L("Save")) { save() }
                        .disabled(!canSave)
                }
            }
        }
        .presentationDetents(adjustable ? [.large] : [.medium, .large])
        .task {
            guard request.client.servesCases else { return }
            cases = await request.client.exportCases()
            loadingCases = false
        }
        .task(id: multi ? "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)" : "") {
            guard multi, spanValid else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await loadActivity()
        }
        .onChange(of: multi) { _, on in
            // A base name in place of the one camera's name, and back.
            if on, name == request.name { name = "" }
            if !on, name.isEmpty { name = request.name }
        }
    }

    private var canSave: Bool {
        guard spanValid, choice != Self.newID || !newCase.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if multi { return !chosenCameras.isEmpty && chosenCameras.count <= Self.maxItems }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Cameras

    private var cameraSection: some View {
        Section {
            ForEach(request.cameras, id: \.name) { cam in
                cameraRow(cam)
            }
        } header: {
            HStack {
                Text("Cameras")
                Spacer()
                if loadingActivity { ProgressView().controlSize(.mini) }
                Text("\(selected.count) / \(request.cameras.count) selected").textCase(nil)
            }
        } footer: {
            Text("Cameras with tracked objects in this span are selected first.")
        }
    }

    private func cameraRow(_ cam: CameraConfig) -> some View {
        let a = activity[cam.name]
        let on = selected.contains(cam.name)
        let s = start.timeIntervalSince1970, e = end.timeIntervalSince1970
        return Button {
            touched = true
            if on { selected.remove(cam.name) } else { selected.insert(cam.name) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(on ? Theme.accent : Theme.textSecondary)
                    Text(cam.displayName).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer()
                    if let a {
                        Text(a.objects == 1 ? L("1 tracked object") : L("\(a.objects) tracked objects"))
                            .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    }
                }
                // When something was going on in the span, as in Frigate's dialog.
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.cardBorder)
                        ForEach(Array((a?.spans ?? []).enumerated()), id: \.offset) { _, span in
                            let x0 = max(0, (span.0 - s) / (e - s)), x1 = min(1, (span.1 - s) / (e - s))
                            Capsule().fill(Theme.accent)
                                .frame(width: max(5, (x1 - x0) * g.size.width))
                                .offset(x: x0 * g.size.width)
                        }
                    }
                }
                .frame(height: 5)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func loadActivity() async {
        loadingActivity = true
        defer { loadingActivity = false }
        let s = start.timeIntervalSince1970, e = end.timeIntervalSince1970
        guard let items = try? await request.client.reviews(after: start.addingTimeInterval(-3600), before: end, limit: 1000) else { return }
        var out: [String: CameraActivity] = [:]
        for cam in request.cameras { out[cam.name] = CameraActivity() }
        for r in items {
            let rs = r.startTime, re = r.endTime ?? Date().timeIntervalSince1970
            guard re > s, rs < e else { continue }
            out[r.camera, default: CameraActivity()].objects += r.data.detections?.count ?? 1
            out[r.camera, default: CameraActivity()].spans.append((rs, re))
        }
        activity = out
        if !touched {
            selected = Set(out.filter { $0.value.objects > 0 }.map(\.key)).union([request.camera])
        }
    }

    // MARK: Case

    private var caseSection: some View {
        Section {
            if loadingCases && cases.isEmpty {
                ProgressView()
            }
            option(nil, L("No case"), icon: "tray")
            ForEach(cases) { c in option(c.id, c.name, icon: "folder") }
            option(Self.newID, L("New case"), icon: "folder.badge.plus")
            if choice == Self.newID {
                TextField("Case name", text: $newCase)
            }
        } header: {
            Text("Case")
        } footer: {
            Text("Cases group exports, as in Frigate's Exports.")
        }
    }

    private func option(_ id: String?, _ title: String, icon: String) -> some View {
        Button { choice = id } label: {
            HStack {
                Label(title, systemImage: icon).foregroundStyle(Theme.text)
                Spacer()
                if choice == id { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Saving

    private func save() {
        let r = request
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let choice = choice
        let caseName = newCase.trimmingCharacters(in: .whitespaces)
        let exporter = exporter
        let s = adjustable ? start.timeIntervalSince1970 : r.start
        let e = adjustable ? min(end.timeIntervalSince1970, Date().timeIntervalSince1970) : r.end
        let items: [FrigateClient.ExportItem]? = multi ? chosenCameras.map { cam in
            FrigateClient.ExportItem(camera: cam.name, start: s, end: e,
                                     name: trimmed.isEmpty
                                         ? ClipExporter.exportName(camera: cam.name, displayName: cam.displayName, start: s)
                                         : "\(trimmed) · \(cam.displayName)")
        } : nil
        closePresented(dismiss)
        Task {
            if let items {
                await exporter.saveToFrigate(client: r.client, items: items,
                                             caseID: choice == Self.newID ? nil : choice,
                                             newCaseName: choice == Self.newID ? caseName : nil)
                return
            }
            var caseID = choice
            if choice == Self.newID {
                do {
                    caseID = try await r.client.createExportCase(name: caseName).id
                } catch {
                    exporter.state = .failed(error.localizedDescription)
                    try? await Task.sleep(for: .seconds(2.5))
                    exporter.state = .idle
                    return
                }
            }
            await exporter.saveToFrigate(client: r.client, camera: r.camera, start: s, end: e, name: trimmed, caseID: caseID)
        }
    }
}

extension View {
    /// Shows `SaveToFrigateSheet` while `request` is set.
    func saveToFrigateSheet(_ request: Binding<SaveToFrigateRequest?>, exporter: ClipExporter) -> some View {
        sheet(item: request) { SaveToFrigateSheet(request: $0, exporter: exporter) }
    }
}
