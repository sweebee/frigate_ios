import SwiftUI

/// Long-press actions on a review item wherever it is listed (a camera's "Today" row, Review):
/// save to Photos, keep as an export in Frigate, share and delete. A screen owns one and adds
/// `reviewActionsHost`, which shows the progress pill, share sheet and delete confirmation.
@Observable @MainActor
final class ReviewActions {
    let exporter = ClipExporter()
    var share: ShareItem?
    var pendingDelete: (item: ReviewItem, serverID: UUID)?
    var error: String?
    /// Items deleted here; screens drop them from their lists.
    private(set) var deletedIDs: Set<String> = []
    private weak var model: AppModel?

    func attach(_ model: AppModel) { self.model = model }

    private func span(_ r: ReviewItem) -> (Double, Double) {
        (r.startTime - 3, min((r.endTime ?? Date().timeIntervalSince1970) + 3, Date().timeIntervalSince1970))
    }

    private func conn(_ serverID: UUID) -> ServerConnection? { model?.connection(for: serverID) }

    func saveToPhotos(_ r: ReviewItem, serverID: UUID) {
        guard let client = conn(serverID)?.client else { return }
        let (s, e) = span(r)
        Task { await exporter.saveToPhotos(client: client, camera: r.camera, start: s, end: e) }
    }

    func saveToFrigate(_ r: ReviewItem, serverID: UUID) {
        guard let c = conn(serverID), let client = c.client else { return }
        let (s, e) = span(r)
        let name = ClipExporter.exportName(camera: r.camera, displayName: c.config?.cameras[r.camera]?.displayName,
                                           start: r.startTime, label: r.labels.first)
        Task { await exporter.saveToFrigate(client: client, camera: r.camera, start: s, end: e, name: name) }
    }

    func shareClip(_ r: ReviewItem, serverID: UUID) {
        guard let client = conn(serverID)?.client else { return }
        let (s, e) = span(r)
        Task {
            exporter.state = .working(L("Preparing clip…"))
            do {
                let file = try await exporter.download(client: client, camera: r.camera, start: s, end: e)
                exporter.state = .idle
                share = ShareItem(items: [file])
            } catch {
                exporter.state = .failed(error.localizedDescription)
                try? await Task.sleep(for: .seconds(2.5))
                exporter.state = .idle
            }
        }
    }

    func delete(_ r: ReviewItem, serverID: UUID) async {
        guard let c = conn(serverID), let client = c.client else { return }
        do {
            try await client.deleteReviews([r.id])
            withAnimation(.easeOut(duration: 0.2)) { _ = deletedIDs.insert(r.id) }
            Task { await c.refresh() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The long-press menu for one review item.
struct ReviewItemMenu: View {
    let item: ReviewItem
    let serverID: UUID
    let actions: ReviewActions

    var body: some View {
        Button { actions.saveToPhotos(item, serverID: serverID) } label: {
            Label("Save to Photos", systemImage: "square.and.arrow.down")
        }
        Button { actions.saveToFrigate(item, serverID: serverID) } label: {
            Label("Save to Frigate", systemImage: "externaldrive")
        }
        Button { actions.shareClip(item, serverID: serverID) } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        Divider()
        Button(role: .destructive) { actions.pendingDelete = (item, serverID) } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

extension View {
    /// Progress pill, share sheet and delete confirmation for `ReviewItemMenu`.
    func reviewActionsHost(_ actions: ReviewActions) -> some View { modifier(ReviewActionsHost(actions: actions)) }
}

private struct ReviewActionsHost: ViewModifier {
    @Bindable var actions: ReviewActions
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) { ExportToast(state: actions.exporter.state) }
            .sheet(item: $actions.share) { ShareSheet(items: $0.items) }
            .alert("Delete this review item and its recordings?",
                   isPresented: Binding(get: { actions.pendingDelete != nil }, set: { if !$0 { actions.pendingDelete = nil } })) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    if let p = actions.pendingDelete { Task { await actions.delete(p.item, serverID: p.serverID) } }
                }
            } message: {
                if let r = actions.pendingDelete?.item {
                    Text("\(r.labels.first.map(FrigateFormat.labelName)?.capitalizedFirst ?? L("Event")) at \(FrigateFormat.time(r.start, seconds: true))")
                }
            }
            .alert("Something went wrong", isPresented: Binding(get: { actions.error != nil }, set: { if !$0 { actions.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(actions.error ?? "") }
            .onAppear { actions.attach(model) }
    }
}
