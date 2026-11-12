import Foundation
import SwiftUI

/// Handles `frigate://` links:
///   frigate://add?url=http://host:8971&name=Home      add a server (asks nothing, tests on connect)
///   frigate://live | review | explore | history | settings      switch tab (history: recordings overview)
///   frigate://camera/<camera>[?server=<name>]         open a camera's live view
///   frigate://playback/<camera>[?day=yyyy-MM-dd&view=timeline]  open playback
///   frigate://event/<review id>[?server=<name>]       open a review item
extension AppModel {
    func handle(_ url: URL) async {
        guard url.scheme == "frigate" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let arg = url.pathComponents.dropFirst().first

        let conn: ServerConnection? = {
            if let name = q("server") { return orderedConnections.first { $0.server.name.caseInsensitiveCompare(name) == .orderedSame } }
            if case .server(let id) = scope { return connections[id] }
            return orderedConnections.first
        }()

        switch url.host {
        case "add":
            guard let raw = q("url"), let base = ServerConfig.normalizedURL(raw) else { return }
            if servers.contains(where: { $0.url == base.absoluteString }) { return }
            save(ServerConfig(name: q("name") ?? base.host ?? "Frigate", url: base.absoluteString), password: nil)
        case "live": tab = .live; livePath = NavigationPath()
        case "review":
            tab = .review
            reviewPath = NavigationPath()
            if let v = q("view") { reviewKindRequest = v }
        case "explore": tab = .explore; explorePath = NavigationPath()
        case "history": tab = .explore; explorePath = NavigationPath(); explorePath.append(HistoryRoute())
        case "settings": tab = .settings
        case "camera":
            guard let conn, let arg else { return }
            tab = .live
            livePath = NavigationPath()
            livePath.append(CameraRoute(serverID: conn.server.id, camera: arg))
        case "playback":
            guard let conn, let arg else { return }
            tab = .explore
            explorePath = NavigationPath()
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            let day = q("day").flatMap { f.date(from: $0) } ?? Date()
            explorePath.append(PlaybackRoute(serverID: conn.server.id, camera: arg, day: Calendar.current.startOfDay(for: day), reviewID: q("review"), showTimeline: q("view") == "timeline"))
        case "event":
            guard let conn, let arg, let client = conn.client else { return }
            let item: ReviewItem
            do { item = try await client.review(id: arg) } catch {
                NSLog("Frigate deep link: could not load review \(arg): \(error)")
                return
            }
            tab = .review
            reviewPath = NavigationPath()
            reviewPath.append(EventRoute(serverID: conn.server.id, review: item))
        default: break
        }
    }
}
