import Foundation

enum FrigateError: LocalizedError {
    case invalidURL
    case http(Int, String?)
    case unauthorized
    case notFrigate

    var errorDescription: String? {
        switch self {
        case .invalidURL: return L("The server address is not a valid URL.")
        case .http(let code, let detail): return L("Server returned \(code)\(detail.map { ": \($0)" } ?? "").")
        case .unauthorized: return L("Login failed. Check the username and password.")
        case .notFrigate: return L("This address did not respond like a Frigate server.")
        }
    }
}

/// Thin client for the Frigate HTTP API of one server.
final class FrigateClient: @unchecked Sendable {
    let baseURL: URL
    let session: URLSession
    /// The server's version ("0.18.2-cfa08c5"), once connected.
    var version: String?
    private let decoder = JSONDecoder()

    init(baseURL: URL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    /// Builds a URL relative to the server root, e.g. `api/review`.
    func url(_ path: String, query: [String: String?] = [:]) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var comps = URLComponents(url: baseURL.appendingPathComponent(""), resolvingAgainstBaseURL: false)!
        let basePath = comps.path.hasSuffix("/") ? comps.path : comps.path + "/"
        comps.path = basePath + trimmed
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        comps.queryItems = items.isEmpty ? nil : items.sorted { $0.name < $1.name }
        return comps.url!
    }

    // MARK: Raw requests

    func data(_ path: String, query: [String: String?] = [:], timeout: TimeInterval? = nil) async throws -> Data {
        var req = URLRequest(url: url(path, query: query))
        if let timeout { req.timeoutInterval = timeout }
        return try await perform(req)
    }

    func get<T: Decodable>(_ type: T.Type, _ path: String, query: [String: String?] = [:]) async throws -> T {
        let data = try await data(path, query: query)
        return try decoder.decode(T.self, from: data)
    }

    @discardableResult
    func post(_ path: String, json: Any) async throws -> Data {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Frigate rejects cookie-authenticated POSTs without this header.
        req.setValue("1", forHTTPHeaderField: "X-CSRF-TOKEN")
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await perform(req)
    }

    /// Streams a chat answer from Frigate's GenAI chat (/api/chat/completion, newline-delimited JSON).
    /// `messages` is the conversation as Frigate returned it last time, plus the new user message.
    func chat(messages: [[String: Any]]) -> AsyncThrowingStream<[String: Any], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: url("api/chat/completion"))
                    req.httpMethod = "POST"
                    req.timeoutInterval = 180
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("1", forHTTPHeaderField: "X-CSRF-TOKEN")
                    req.httpBody = try JSONSerialization.data(withJSONObject: ["messages": messages, "stream": true])
                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await b in bytes { body.append(b) }
                        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
                        let detail = (json?["error"] ?? json?["message"] ?? json?["detail"]) as? String
                        throw http.statusCode == 401 ? FrigateError.unauthorized : FrigateError.http(http.statusCode, detail)
                    }
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func perform(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { return data }
        if http.statusCode == 401 || http.statusCode == 403 { throw FrigateError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
                ?? (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw FrigateError.http(http.statusCode, detail)
        }
        return data
    }

    // MARK: Auth and info

    func version(timeout: TimeInterval = 6) async throws -> String {
        let data = try await data("api/version", timeout: timeout)
        guard let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              s.first?.isNumber == true, s.count < 40 else { throw FrigateError.notFrigate }
        return s
    }

    func login(user: String, password: String) async throws {
        do {
            try await post("api/login", json: ["user": user, "password": password])
        } catch FrigateError.http(let code, _) where code == 400 || code == 401 {
            throw FrigateError.unauthorized
        }
    }

    func config() async throws -> FrigateConfig { try await get(FrigateConfig.self, "api/config") }
    func stats() async throws -> FrigateStats { try await get(FrigateStats.self, "api/stats") }

    // MARK: Review

    func reviews(cameras: [String]? = nil, labels: [String]? = nil, zones: [String]? = nil, severity: Severity? = nil,
                 reviewed: Bool? = nil, after: Date? = nil, before: Date? = nil, limit: Int = 100) async throws -> [ReviewItem] {
        var q: [String: String?] = ["limit": String(limit)]
        let cameras = ScreenshotMode.scope(cameras)
        if let cameras, !cameras.isEmpty { q["cameras"] = cameras.joined(separator: ",") }
        if let labels, !labels.isEmpty { q["labels"] = labels.joined(separator: ",") }
        if let zones, !zones.isEmpty { q["zones"] = zones.joined(separator: ",") }
        if let severity { q["severity"] = severity.rawValue }
        if let reviewed { q["reviewed"] = reviewed ? "1" : "0" }
        if let after { q["after"] = String(after.timeIntervalSince1970) }
        if let before { q["before"] = String(before.timeIntervalSince1970) }
        return try await get([ReviewItem].self, "api/review", query: q)
    }

    func reviewSummary() async throws -> ReviewSummary {
        let q: [String: String?] = ["cameras": ScreenshotMode.cameras?.joined(separator: ",")]
        return try await get(ReviewSummary.self, "api/review/summary", query: q)
    }

    /// Days ("yyyy-MM-dd") that have recordings for the cameras, or all cameras.
    func recordingDays(cameras: [String]? = nil) async throws -> Set<String> {
        // Days in the user's time zone; Frigate defaults to UTC.
        var q: [String: String?] = ["timezone": TimeZone.current.identifier]
        let cameras = ScreenshotMode.scope(cameras)
        if let cameras, !cameras.isEmpty { q["cameras"] = cameras.joined(separator: ",") }
        let map = try await get([String: Bool].self, "api/recordings/summary", query: q)
        return Set(map.filter(\.value).keys)
    }

    /// Alert and detection counts per day ("yyyy-MM-dd").
    func reviewDays(cameras: [String]? = nil) async throws -> [String: ReviewSummary.DayCounts] {
        // Days in the user's time zone; Frigate defaults to UTC.
        var q: [String: String?] = ["timezone": TimeZone.current.identifier]
        let cameras = ScreenshotMode.scope(cameras)
        if let cameras, !cameras.isEmpty { q["cameras"] = cameras.joined(separator: ",") }
        let all = try await get([String: ReviewSummary.DayCounts].self, "api/review/summary", query: q)
        return all.filter { $0.key != "last24Hours" }
    }

    func markViewed(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await post("api/reviews/viewed", json: ["ids": ids, "reviewed": true])
    }

    // MARK: Exports

    /// Every export on the server, newest first.
    func exports() async throws -> [FrigateExport] {
        try await get([FrigateExport].self, "api/exports").sorted { $0.date > $1.date }
    }

    /// Through the local proxy, which renames HEVC's `hev1` tag so the video shows.
    func exportVideoURL(_ export: FrigateExport) -> URL { HLSProxy.shared.url(for: exportFileURL(export)) }
    /// The file itself, for downloading.
    func exportFileURL(_ export: FrigateExport) -> URL { url(FrigateExport.servedPath(export.videoPath)) }
    func exportThumbnailURL(_ export: FrigateExport) -> URL? {
        export.thumbPath.isEmpty ? nil : url(FrigateExport.servedPath(export.thumbPath))
    }

    /// Asks Frigate to export a span of recordings; it makes the file in the background.
    func startExport(camera: String, start: Double, end: Double, name: String) async throws {
        try await post("api/export/\(camera)/start/\(Int(start.rounded(.down)))/end/\(Int(end.rounded(.up)))",
                       json: ["playback": "realtime", "source": "recordings", "name": name])
    }

    func renameExport(_ id: String, to name: String) async throws {
        // Frigate 0.15 and later; older versions take the name in the path.
        do {
            try await send("PATCH", "api/export/\(id)/rename", json: ["name": name])
        } catch FrigateError.http(let code, _) where code == 404 || code == 405 {
            try await send("PATCH", "api/export/\(id)/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)", json: [:])
        }
    }

    func deleteExport(_ id: String) async throws {
        // Frigate 0.18 deletes in bulk; earlier versions one at a time.
        do {
            try await post("api/exports/delete", json: ["ids": [id]])
        } catch FrigateError.http(let code, _) where code == 404 || code == 405 {
            try await send("DELETE", "api/export/\(id)", json: nil)
        }
    }

    @discardableResult
    private func send(_ method: String, _ path: String, json: Any?) async throws -> Data {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.setValue("1", forHTTPHeaderField: "X-CSRF-TOKEN")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return try await perform(req)
    }

    func deleteReviews(_ ids: [String]) async throws {
        try await post("api/reviews/delete", json: ["ids": ids])
    }

    func motionActivity(cameras: [String], after: Date, before: Date, scale: Int) async throws -> [MotionActivity] {
        try await get([MotionActivity].self, "api/review/activity/motion", query: [
            "cameras": cameras.joined(separator: ","),
            "after": String(Int(after.timeIntervalSince1970)),
            "before": String(Int(before.timeIntervalSince1970)),
            "scale": String(scale),
        ])
    }

    /// Motion per camera. Frigate merges cameras when several are requested at once,
    /// so this asks for each camera separately.
    func motionActivityByCamera(_ cameras: [String], after: Date, before: Date, scale: Int) async -> [String: [MotionActivity]] {
        await withTaskGroup(of: (String, [MotionActivity]).self) { group in
            for cam in cameras {
                group.addTask {
                    (cam, (try? await self.motionActivity(cameras: [cam], after: after, before: before, scale: scale)) ?? [])
                }
            }
            var out: [String: [MotionActivity]] = [:]
            for await (cam, items) in group { out[cam] = items }
            return out
        }
    }

    // MARK: Events

    /// Fetches events one by one: Frigate ignores an id filter on /api/events and would
    /// return the latest events of every camera instead.
    func events(ids: [String]) async throws -> [FrigateEvent] {
        guard !ids.isEmpty else { return [] }
        return await withTaskGroup(of: FrigateEvent?.self) { group in
            for id in ids.prefix(20) {
                group.addTask { try? await self.get(FrigateEvent.self, "api/events/\(id)") }
            }
            var out: [FrigateEvent] = []
            for await e in group { if let e { out.append(e) } }
            return out.sorted { $0.startTime < $1.startTime }
        }
    }

    /// The latest tracked objects per label, with each label's total count (Explore page).
    func exploreEvents(limit: Int = 10) async throws -> [ExploreEvent] {
        try await get([ExploreEvent].self, "api/events/explore", query: ["limit": String(limit)])
    }

    enum EventSort: String { case newest = "date_desc", oldest = "date_asc", score = "score_desc" }

    /// Tracked objects matching the filters, as Frigate's Explore search does.
    func searchEvents(cameras: [String]? = nil, labels: [String]? = nil, zones: [String]? = nil, subLabels: [String]? = nil,
                      plate: String? = nil,
                      after: Date? = nil, before: Date? = nil, sort: EventSort = .newest, limit: Int = 50) async throws -> [FrigateEvent] {
        var q: [String: String?] = ["limit": String(limit), "sort": sort.rawValue, "include_thumbnails": "0"]
        let cameras = ScreenshotMode.scope(cameras)
        if let cameras, !cameras.isEmpty { q["cameras"] = cameras.joined(separator: ",") }
        if let labels, !labels.isEmpty { q["labels"] = labels.joined(separator: ",") }
        if let zones, !zones.isEmpty { q["zones"] = zones.joined(separator: ",") }
        if let subLabels, !subLabels.isEmpty { q["sub_labels"] = subLabels.joined(separator: ",") }
        if let plate { q["recognized_license_plate"] = plate }
        if let after { q["after"] = String(after.timeIntervalSince1970) }
        if let before { q["before"] = String(before.timeIntervalSince1970) }
        return try await get([FrigateEvent].self, "api/events", query: q)
    }

    func trackedLabels() async throws -> [String] { try await get([String].self, "api/labels") }
    func subLabels() async throws -> [String] { try await get([String].self, "api/sub_labels") }
    /// Plates Frigate's license plate recognition has read.
    func recognizedPlates() async throws -> [String] { try await get([String].self, "api/recognized_license_plates") }

    /// The review item an object belongs to, for playing its video.
    func review(forEvent id: String) async throws -> ReviewItem {
        await withReviewedStatus(try await get(ReviewItem.self, "api/review/event/\(id)"))
    }

    /// A single review item, with its reviewed flag.
    func review(id: String) async throws -> ReviewItem {
        await withReviewedStatus(try await get(ReviewItem.self, "api/review/\(id)"))
    }

    /// Single-item endpoints have no reviewed flag; read it from the list around the item's start.
    private func withReviewedStatus(_ item: ReviewItem) async -> ReviewItem {
        let listed = try? await get([ReviewItem].self, "api/review", query: [
            "cameras": item.camera, "limit": "20",
            "after": String(item.startTime - 1), "before": String(item.startTime + 1),
        ])
        return listed?.first { $0.id == item.id } ?? item
    }

    func activeEvents() async throws -> [FrigateEvent] {
        try await get([FrigateEvent].self, "api/events", query: ["in_progress": "1", "limit": "100"])
    }

    func timeline(sourceId: String) async throws -> [TimelineEntry] {
        try await get([TimelineEntry].self, "api/timeline", query: ["source_id": sourceId])
    }

    func recordings(camera: String, after: Date, before: Date) async throws -> [RecordingSegment] {
        try await get([RecordingSegment].self, "api/\(camera)/recordings", query: [
            "after": String(Int(after.timeIntervalSince1970)),
            "before": String(Int(before.timeIntervalSince1970)),
        ])
    }

    // MARK: Media URLs

    func latestImageURL(camera: String, height: Int? = nil) -> URL {
        if let t = ScreenshotMode.liveTime {
            return url("api/\(camera)/recordings/\(Int(t))/snapshot.jpg", query: ["height": height.map(String.init)])
        }
        return url("api/\(camera)/latest.jpg", query: ["height": height.map(String.init)])
    }

    func mjpegURL(camera: String, height: Int = 720) -> URL {
        url("api/\(camera)", query: ["height": String(height)])
    }

    func thumbnailURL(for event: FrigateEvent) -> URL { url("api/events/\(event.id)/thumbnail.webp") }

    /// Snapshot of an object with its bounding box drawn in.
    func snapshotURL(for event: FrigateEvent) -> URL { url("api/events/\(event.id)/snapshot.jpg", query: ["bbox": "1"]) }
    /// The same snapshot without the box: a still of the scene, e.g. while its video loads.
    func cleanSnapshotURL(for event: FrigateEvent) -> URL { url("api/events/\(event.id)/snapshot.jpg") }

    func thumbnailURL(for review: ReviewItem) -> URL? {
        review.thumbnailPath.map { url($0) }
    }

    /// HLS playlist for a recording range, routed through the local proxy so HEVC plays.
    func vodURL(camera: String, start: Double, end: Double) -> URL {
        HLSProxy.shared.url(for: url("vod/\(camera)/start/\(Int(start.rounded(.down)))/end/\(Int(end.rounded(.up)))/index.m3u8"))
    }

    /// A short clip (an event, an object) to play. Frigate 0.17 and later cut `/vod/clip` at
    /// each recording segment: the first piece is only the seconds up to the next segment
    /// (3 s, 1.5 MB in a test) where `/vod` sends one long first piece (13 s, 6.5 MB), which on
    /// a remote connection is seconds before the video shows. Frigate's own web app uses it.
    func clipVODURL(camera: String, start: Double, end: Double) -> URL {
        guard servesClipVOD else { return vodURL(camera: camera, start: start, end: end) }
        return HLSProxy.shared.url(for: url("vod/clip/\(camera)/start/\(Int(start.rounded(.down)))/end/\(Int(end.rounded(.up)))/index.m3u8"))
    }

    private var servesClipVOD: Bool {
        let parts = (version ?? "").split(separator: "-").first?.split(separator: ".").compactMap { Int($0) } ?? []
        guard parts.count >= 2 else { return false }
        return parts[0] > 0 || parts[1] >= 17
    }

    func clipURL(camera: String, start: Double, end: Double) -> URL {
        url("api/\(camera)/start/\(Int(start.rounded(.down)))/end/\(Int(end.rounded(.up)))/clip.mp4")
    }

    /// Names of the server's go2rtc streams; empty when Frigate runs without go2rtc restreams.
    func go2rtcStreams() async throws -> Set<String> {
        Set(try await get([String: AnyJSON].self, "api/go2rtc/streams").keys)
    }

    /// Whether a go2rtc stream can receive audio (a camera speaker), like Frigate's web UI
    /// checks: one of its producers offers "audio, sendonly".
    func supportsTwoWayAudio(stream: String) async -> Bool {
        struct Info: Decodable {
            struct Producer: Decodable { let medias: [String]? }
            let producers: [Producer]?
        }
        guard let info = try? await get(Info.self, "api/go2rtc/streams/\(stream)") else { return false }
        return (info.producers ?? []).contains { ($0.medias ?? []).contains { $0.contains("audio, sendonly") } }
    }

    /// Websocket version of a server path, e.g. `ws` for Frigate's event feed.
    func socketURL(_ path: String, query: [String: String?] = [:]) -> URL {
        var comps = URLComponents(url: url(path, query: query), resolvingAgainstBaseURL: false)!
        comps.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        return comps.url!
    }

    /// Websocket URL of the go2rtc MSE endpoint proxied by Frigate.
    func liveSocketURL(stream: String, mode: String) -> URL {
        var comps = URLComponents(url: url("live/\(mode)/api/ws", query: ["src": stream]), resolvingAgainstBaseURL: false)!
        comps.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        return comps.url!
    }

    /// Downloads a file to a temporary location with the given name. `progress` gets the bytes
    /// received and expected (0 when the server does not say) as they come in.
    func download(_ url: URL, fileName: String, progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> URL {
        let delegate = progress.map { DownloadProgress(report: $0) }
        let (tmp, response) = try await session.download(from: url, delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FrigateError.http(http.statusCode, nil)
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        if dest.pathExtension == "mp4" { MP4Patch.patchFile(at: dest) }
        return dest
    }
}


/// Reports a download's progress from its task's byte counts.
final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Int64, Int64) -> Void
    private var observation: NSKeyValueObservation?

    init(report: @escaping @Sendable (Int64, Int64) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.observe(\.countOfBytesReceived, options: [.new]) { [report] task, _ in
            report(task.countOfBytesReceived, max(0, task.countOfBytesExpectedToReceive))
        }
    }
}
