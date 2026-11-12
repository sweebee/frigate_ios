import Foundation

/// Hidden option for App Store screenshots: launch with `-ScreenshotCameras carport,voordeur`
/// to show only those cameras everywhere (Live, Review, History, counts). Not visible to users.
enum ScreenshotMode {
    static let cameras: [String]? = {
        guard let raw = UserDefaults.standard.string(forKey: "ScreenshotCameras"), !raw.isEmpty else { return nil }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }()

    static func allows(_ camera: String) -> Bool { cameras?.contains(camera) ?? true }

    /// The cameras to request from the API when the caller did not choose any.
    static func scope(_ requested: [String]?) -> [String]? {
        guard let cameras else { return requested }
        guard let requested, !requested.isEmpty else { return cameras }
        return requested.filter(cameras.contains)
    }
}
