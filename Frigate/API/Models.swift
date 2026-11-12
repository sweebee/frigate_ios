import Foundation

/// Decodes and discards any JSON value.
struct AnyJSON: Decodable {}

// MARK: - Config

struct FrigateConfig: Decodable {
    var cameras: [String: CameraConfig]
    var cameraGroups: [String: CameraGroupConfig]?

    enum CodingKeys: String, CodingKey {
        case cameras
        case cameraGroups = "camera_groups"
    }

    /// Cameras shown on the dashboard, in UI order.
    var orderedCameras: [CameraConfig] {
        cameras.values
            .filter { $0.enabled != false && $0.ui?.dashboard != false && ScreenshotMode.allows($0.name) }
            .sorted { ($0.ui?.order ?? 0, $0.name) < ($1.ui?.order ?? 0, $1.name) }
    }

    var orderedGroups: [(name: String, group: CameraGroupConfig)] {
        (cameraGroups ?? [:])
            .map { (name: $0.key, group: $0.value) }
            .sorted { ($0.group.order ?? 0, $0.name) < ($1.group.order ?? 0, $1.name) }
    }
}

struct CameraGroupConfig: Decodable {
    var cameras: [String]
    var icon: String?
    var order: Int?
}

struct CameraConfig: Decodable {
    var name: String
    var friendlyName: String?
    var enabled: Bool?
    var detect: Detect?
    var record: Toggle?
    var audio: Toggle?
    var live: Live?
    var ui: UI?
    var zones: [String: AnyJSON]?
    var onvif: Onvif?

    struct Detect: Decodable {
        var enabled: Bool?; var width: Int?; var height: Int?
        /// Milliseconds between detection timestamps and the recording (Frigate's detect.annotation_offset).
        var annotationOffset: Double?
        enum CodingKeys: String, CodingKey {
            case enabled, width, height
            case annotationOffset = "annotation_offset"
        }
    }
    struct Toggle: Decodable { var enabled: Bool? }
    struct Live: Decodable { var streams: [String: String]? }
    struct UI: Decodable { var order: Int?; var dashboard: Bool? }
    struct Onvif: Decodable { var host: String? }

    enum CodingKeys: String, CodingKey {
        case name, enabled, detect, record, audio, live, ui, zones, onvif
        case friendlyName = "friendly_name"
    }

    var displayName: String { friendlyName ?? FrigateFormat.prettyName(name) }
    var aspectRatio: Double {
        guard let w = detect?.width, let h = detect?.height, w > 0, h > 0 else { return 16.0 / 9.0 }
        return Double(w) / Double(h)
    }
    var hasOnvif: Bool { !(onvif?.host ?? "").isEmpty }
    /// Seconds to add to detection times to find them in the recording.
    var annotationOffset: Double { (detect?.annotationOffset ?? 0) / 1000 }

    /// go2rtc stream names, main stream first.
    var streams: [(title: String, name: String)] {
        guard let s = live?.streams, !s.isEmpty else { return [("Main", name)] }
        return s.map { (title: $0.key, name: $0.value) }
            .sorted { lhs, rhs in
                if lhs.name == name { return true }
                if rhs.name == name { return false }
                return lhs.title < rhs.title
            }
    }
}

// MARK: - Stats

struct FrigateStats: Decodable {
    var cameras: [String: CameraStats]
    var service: Service?

    struct CameraStats: Decodable {
        var cameraFps: Double?
        var detectionEnabled: Bool?
        enum CodingKeys: String, CodingKey {
            case cameraFps = "camera_fps"
            case detectionEnabled = "detection_enabled"
        }
    }
    struct Service: Decodable { var version: String?; var uptime: Double? }

    init(from decoder: Decoder) throws {
        // `cameras` sits next to detectors and other keys; decode leniently.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cameras = (try? c.decode([String: CameraStats].self, forKey: .cameras)) ?? [:]
        service = try? c.decode(Service.self, forKey: .service)
    }
    enum CodingKeys: String, CodingKey { case cameras, service }
}

// MARK: - Review

enum Severity: String, Codable, CaseIterable, Hashable {
    case alert, detection
}

struct ReviewItem: Decodable, Identifiable, Hashable {
    var id: String
    var camera: String
    var startTime: Double
    var endTime: Double?
    var severity: Severity
    var thumbPath: String?
    var data: ReviewData
    var hasBeenReviewed: Bool

    struct ReviewData: Decodable, Hashable {
        var detections: [String]?
        var objects: [String]?
        var subLabels: [String]?
        var zones: [String]?
        var audio: [String]?
        var thumbTime: Double?
        enum CodingKeys: String, CodingKey {
            case detections, objects, zones, audio
            case subLabels = "sub_labels"
            case thumbTime = "thumb_time"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, camera, severity, data
        case startTime = "start_time"
        case endTime = "end_time"
        case thumbPath = "thumb_path"
        case hasBeenReviewed = "has_been_reviewed"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        camera = try c.decode(String.self, forKey: .camera)
        startTime = try c.decode(Double.self, forKey: .startTime)
        endTime = try c.decodeIfPresent(Double.self, forKey: .endTime)
        severity = try c.decode(Severity.self, forKey: .severity)
        thumbPath = try c.decodeIfPresent(String.self, forKey: .thumbPath)
        data = try c.decode(ReviewData.self, forKey: .data)
        // /api/review/<id> leaves this out.
        hasBeenReviewed = try c.decodeIfPresent(Bool.self, forKey: .hasBeenReviewed) ?? false
    }

    var start: Date { Date(timeIntervalSince1970: startTime) }
    var end: Date? { endTime.map { Date(timeIntervalSince1970: $0) } }
    var duration: TimeInterval { max(0, (endTime ?? Date().timeIntervalSince1970) - startTime) }
    var inProgress: Bool { endTime == nil }

    /// Unique labels: objects first, then audio, with "-verified" suffixes removed.
    var labels: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in (data.objects ?? []) + (data.audio ?? []) {
            let l = raw.replacingOccurrences(of: "-verified", with: "")
            if seen.insert(l).inserted { out.append(l) }
        }
        return out
    }

    /// Path for the thumbnail, relative to the server root.
    var thumbnailPath: String? {
        guard let p = thumbPath, !p.isEmpty else { return nil }
        return p.replacingOccurrences(of: "/media/frigate", with: "")
    }
}

struct ReviewSummary: Decodable {
    var last24Hours: DayCounts?
    enum CodingKeys: String, CodingKey { case last24Hours }

    struct DayCounts: Decodable {
        var reviewedAlert: Int?
        var reviewedDetection: Int?
        var totalAlert: Int?
        var totalDetection: Int?
        enum CodingKeys: String, CodingKey {
            case reviewedAlert = "reviewed_alert"
            case reviewedDetection = "reviewed_detection"
            case totalAlert = "total_alert"
            case totalDetection = "total_detection"
        }
        var unreviewedAlerts: Int { max(0, (totalAlert ?? 0) - (reviewedAlert ?? 0)) }
        var unreviewedDetections: Int { max(0, (totalDetection ?? 0) - (reviewedDetection ?? 0)) }
    }
}

struct MotionActivity: Decodable, Hashable {
    var startTime: Double
    var motion: Double?
    var camera: String?
    enum CodingKeys: String, CodingKey {
        case motion, camera
        case startTime = "start_time"
    }
}

// MARK: - Events and timeline

struct FrigateEvent: Decodable, Identifiable, Hashable {
    var id: String
    var camera: String
    var label: String
    var subLabel: SubLabel?
    var zones: [String]?
    var startTime: Double
    var endTime: Double?
    var hasClip: Bool?
    var hasSnapshot: Bool?
    var topScore: Double?
    var data: EventData?

    struct EventData: Decodable, Hashable {
        var score: Double?
        var topScore: Double?
        var box: [Double]?
        enum CodingKeys: String, CodingKey {
            case score, box
            case topScore = "top_score"
        }
    }

    /// `sub_label` is either a string or `[name, score]`.
    struct SubLabel: Decodable, Hashable {
        var name: String
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { name = s; return }
            var arr = try decoder.unkeyedContainer()
            name = (try? arr.decode(String.self)) ?? ""
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, camera, label, zones, data
        case subLabel = "sub_label"
        case startTime = "start_time"
        case endTime = "end_time"
        case hasClip = "has_clip"
        case hasSnapshot = "has_snapshot"
        case topScore = "top_score"
    }

    var bestScore: Double? { data?.topScore ?? topScore ?? data?.score }
}

/// An item of /api/events/explore: an event plus how many objects its label has in total.
struct ExploreEvent: Decodable {
    var event: FrigateEvent
    var eventCount: Int?
    private enum Keys: String, CodingKey { case eventCount = "event_count" }
    init(from decoder: Decoder) throws {
        event = try FrigateEvent(from: decoder)
        eventCount = try decoder.container(keyedBy: Keys.self).decodeIfPresent(Int.self, forKey: .eventCount)
    }
}

struct TimelineEntry: Decodable, Hashable {
    var timestamp: Double
    var camera: String
    var sourceId: String?
    var classType: String
    var data: EntryData?

    struct EntryData: Decodable, Hashable {
        var label: String?
        var subLabel: FrigateEvent.SubLabel?
        var zones: [String]?
        var attribute: String?
        enum CodingKeys: String, CodingKey {
            case label, zones, attribute
            case subLabel = "sub_label"
        }
    }

    enum CodingKeys: String, CodingKey {
        case timestamp, camera, data
        case sourceId = "source_id"
        case classType = "class_type"
    }

    var description: String {
        let label = FrigateFormat.labelName(data?.label ?? "object").capitalizedFirst
        switch classType {
        case "visible": return L("\(label) detected")
        case "entered_zone":
            let z = (data?.zones ?? []).map(FrigateFormat.prettyName).joined(separator: ", ")
            return z.isEmpty ? L("\(label) entered a zone") : L("\(label) entered \(z)")
        case "active": return L("\(label) became active")
        case "stationary": return L("\(label) became stationary")
        case "attribute":
            let a = data?.attribute.map(FrigateFormat.labelName) ?? "attribute"
            return L("\(label) recognized as \(a)")
        case "gone": return L("\(label) left the frame")
        case "heard": return L("\(label) heard")
        case "external": return L("\(label) (external)")
        default: return "\(label): \(classType.replacingOccurrences(of: "_", with: " "))"
        }
    }
}

struct RecordingSegment: Decodable, Hashable {
    var startTime: Double
    var endTime: Double
    var duration: Double?
    var motion: Double?
    var objects: Double?
    enum CodingKeys: String, CodingKey {
        case duration, motion, objects
        case startTime = "start_time"
        case endTime = "end_time"
    }
}

// MARK: - Formatting

enum FrigateFormat {
    static func prettyName(_ raw: String) -> String {
        let s = raw.replacingOccurrences(of: "_", with: " ")
        return s.capitalizedFirst
    }

    /// Frigate object label in the user's language (table Labels.xcstrings), e.g. person -> persoon.
    static func labelName(_ raw: String) -> String {
        let pretty = raw.replacingOccurrences(of: "_", with: " ")
        return Bundle.main.localizedString(forKey: raw, value: pretty, table: "Labels")
    }

    static func time(_ date: Date, seconds: Bool = false) -> String {
        let f = DateFormatter()
        f.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
        return f.string(from: date)
    }

    /// "1.9 s" under a minute, otherwise "m:ss".
    static func shortDuration(_ t: TimeInterval) -> String {
        if t < 60 {
            let f = NumberFormatter()
            f.maximumFractionDigits = t < 10 ? 1 : 0
            f.minimumFractionDigits = 0
            return "\(f.string(from: NSNumber(value: max(t, 0.1))) ?? "0") s"
        }
        return duration(t)
    }

    /// Review items are normally seconds to minutes long. Frigate sometimes closes one only
    /// after a restart, days later; show such lengths as "> 1 h" instead of e.g. 128:46:38.
    static func reviewDuration(_ item: ReviewItem) -> String {
        item.duration > 3600 ? L("> 1 h") : duration(item.duration)
    }

    static func duration(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func dayTitle(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return L("Today") }
        if cal.isDateInYesterday(date) { return L("Yesterday") }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return f.string(from: date)
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let d = now.timeIntervalSince(date)
        if d < 60 { return L("Just now") }
        if d < 3600 { return L("\(Int(d / 60)) min ago") }
        if d < 86400 { return L("\(Int(d / 3600)) h ago") }
        let days = Int(d / 86400)
        return L("\(days) days ago")
    }

    /// "0.18.2-cfa08c5" -> "v0.18"
    static func shortVersion(_ v: String) -> String {
        let parts = v.split(separator: "-").first?.split(separator: ".") ?? []
        return "v" + parts.prefix(2).joined(separator: ".")
    }
}

extension String {
    var capitalizedFirst: String {
        guard let f = first else { return self }
        return f.uppercased() + dropFirst()
    }
}
