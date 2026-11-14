import SwiftUI

struct CameraRoute: Hashable {
    let serverID: UUID
    let camera: String
}

struct EventRoute: Hashable {
    let serverID: UUID
    let review: ReviewItem
    /// A tracked object to start with (opened from Explore): shown first, video starts there.
    var focusEventID: String? = nil
}

/// A tracked object from Explore.
struct ObjectRoute: Hashable {
    let serverID: UUID
    let event: FrigateEvent
}

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
            // A tracked object opens the event it belongs to; the object screen only when it has none.
            .navigationDestination(for: ObjectRoute.self) { ObjectOrEventView(route: $0).id($0) }
            .navigationDestination(for: ExportsRoute.self) { _ in ExportsView() }
            .navigationDestination(for: ExportRoute.self) { ExportPlayerView(route: $0).id($0) }
    }
}

extension View {
    func appDestinations() -> some View { modifier(AppDestinations()) }

    /// Standard screen background for the dark design.
    func screenBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }
}

