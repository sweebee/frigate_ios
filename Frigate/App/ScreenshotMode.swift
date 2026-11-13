import Foundation

/// Hidden option for App Store screenshots: launch with `-ScreenshotCameras carport,voordeur`
/// to show only those cameras everywhere (Live, Review, History, counts). Not visible to users.
enum ScreenshotMode {
    static let cameras: [String]? = {
        guard let raw = UserDefaults.standard.string(forKey: "ScreenshotCameras"), !raw.isEmpty else { return nil }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }()

    /// `-ScreenshotTime <unix seconds>`: "live" pictures are the recording at that moment
    /// (e.g. daylight for screenshots taken at night); live video and its status stay off.
    static let liveTime: Double? = {
        let t = UserDefaults.standard.double(forKey: "ScreenshotTime")
        return t > 0 ? t : nil
    }()

    /// Lists of recent items end at the screenshot time, so their pictures match it.
    static var before: Date? { liveTime.map { Date(timeIntervalSince1970: $0 + 60) } }

    static func allows(_ camera: String) -> Bool { cameras?.contains(camera) ?? true }

    /// The cameras to request from the API when the caller did not choose any.
    static func scope(_ requested: [String]?) -> [String]? {
        guard let cameras else { return requested }
        guard let requested, !requested.isEmpty else { return cameras }
        return requested.filter(cameras.contains)
    }
}
