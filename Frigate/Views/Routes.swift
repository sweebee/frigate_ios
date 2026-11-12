import SwiftUI

struct CameraRoute: Hashable {
    let serverID: UUID
    let camera: String
}

struct EventRoute: Hashable {
    let serverID: UUID
    let review: ReviewItem
}

/// A tracked object from Explore.
struct ObjectRoute: Hashable {
    let serverID: UUID
    let event: FrigateEvent
}

/// The per-camera recordings overview (formerly the History tab).
struct HistoryRoute: Hashable {}

struct PlaybackRoute: Hashable {
    let serverID: UUID
    let camera: String
    let day: Date
    /// Review item to start with, if any.
    var reviewID: String? = nil
    /// Open on the timeline instead of the event list.
    var showTimeline = false
    /// Wall-clock moment to start at, e.g. a tracked object without a review item.
    var startTime: Double? = nil
}

/// Registers all detail destinations on a navigation stack.
struct AppDestinations: ViewModifier {
    func body(content: Content) -> some View {
        content
            .navigationDestination(for: CameraRoute.self) { CameraView(route: $0).id($0) }
            .navigationDestination(for: EventRoute.self) { EventDetailView(route: $0).id($0) }
            .navigationDestination(for: PlaybackRoute.self) { PlaybackView(route: $0).id($0) }
            .navigationDestination(for: ObjectRoute.self) { ObjectDetailView(route: $0).id($0) }
            .navigationDestination(for: HistoryRoute.self) { _ in HistoryOverviewView() }
    }
}

extension View {
    func appDestinations() -> some View { modifier(AppDestinations()) }

    /// Standard screen background for the dark design.
    func screenBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }
}

/// Server picker pill used in the Live and Explore headers.
struct ServerSwitcher: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button {
                model.scope = .all
            } label: {
                Label("All servers", systemImage: model.scope == .all ? "checkmark" : "square.stack.3d.up")
            }
            Divider()
            ForEach(model.orderedConnections) { conn in
                Button {
                    model.scope = .server(conn.server.id)
                } label: {
                    if model.scope == .server(conn.server.id) {
                        Label(conn.server.name, systemImage: "checkmark")
                    } else {
                        Text(conn.server.name)
                    }
                }
            }
            Divider()
            Button { model.showAddServer = true } label: { Label("Add server", systemImage: "plus") }
        } label: {
            HStack(spacing: 8) {
                switch model.scope {
                case .all:
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.onColor)
                        .frame(width: 24, height: 24)
                        .background(Theme.textTertiary, in: RoundedRectangle(cornerRadius: 7))
                    Text("All servers")
                    StatusDot(color: model.onlineConnections.isEmpty ? Theme.offline : Theme.online)
                case .server(let id):
                    if let conn = model.connection(for: id) {
                        ServerBadge(initial: conn.server.initial, tint: conn.server.tint, size: 24)
                        Text(conn.server.name)
                        StatusDot(color: conn.isOnline ? Theme.online : (conn.status == .connecting ? Theme.warning : Theme.offline))
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.text)
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .frame(height: 36)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().stroke(Theme.controlBorder, lineWidth: 1))
        }
        .accessibilityLabel("Switch server")
    }
}
