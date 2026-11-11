import AVFoundation
import SwiftUI

/// Shows Frigate's low-resolution preview videos while the user drags a timeline, so the
/// picture follows the finger like in Frigate's web UI. Previews are one file per hour
/// (about 320x180, a frame every few seconds); the current hour has none yet.
@Observable @MainActor
final class PreviewScrubber {
    struct Preview: Decodable {
        let src: String
        let start: Double
        let end: Double
    }

    /// The player whose frame is on screen. Each hour gets its own player, and the view only
    /// switches to it once its first seek is done, so crossing an hour never shows black.
    private(set) var player = AVPlayer()
    /// True while a preview frame for the scrub position is on screen.
    private(set) var showing = false
    private var players: [String: AVPlayer] = [:]

    private var previews: [Preview] = []
    private var client: FrigateClient?
    private var loadedSrc: String?
    private var seeking = false
    private var pendingTime: Double?

    init() {}

    private func makePlayer(_ url: URL) -> AVPlayer {
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPCookiesKey": HTTPCookieStorage.shared.cookies ?? []])
        let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        p.isMuted = true
        p.automaticallyWaitsToMinimizeStalling = false
        return p
    }

    /// Loads the list of preview files for a camera and day.
    func prepare(client: FrigateClient, camera: String, start: Double, end: Double) async {
        self.client = client
        previews = []
        loadedSrc = nil
        players = [:]
        player = AVPlayer()
        let path = "api/preview/\(camera)/start/\(Int(start))/end/\(Int(end))"
        previews = (try? await client.get([Preview].self, path)) ?? []
    }

    /// Shows the preview frame nearest to `wall`, or hides the preview when there is none.
    func show(_ wall: Double) {
        guard let client, let p = previews.first(where: { wall >= $0.start && wall < $0.end }) else {
            showing = false
            return
        }
        if loadedSrc != p.src {
            loadedSrc = p.src
            if players[p.src] == nil {
                // Keep a few hours around for scrubbing back and forth.
                if players.count >= 4 { players = players.filter { $0.value === player } }
                players[p.src] = makePlayer(client.url(p.src))
            }
            seeking = false
        }
        pendingTime = wall - p.start
        // Show the last frame until the new hour has one; the first scrub shows once it lands.
        seekNext()
    }

    /// Hides the preview, e.g. once the full-quality video has arrived.
    func hide() {
        showing = false
        pendingTime = nil
        loadedSrc = nil
    }

    /// Issues at most one seek at a time and always jumps to the latest requested position.
    private func seekNext() {
        guard !seeking, let t = pendingTime, let src = loadedSrc, let target = players[src] else { return }
        pendingTime = nil
        seeking = true
        // Exact seeks: preview files have a keyframe only every few minutes, so a seek with
        // tolerance lands far too early. They are small, so decoding up to the frame is quick.
        target.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] done in
            Task { @MainActor in
                guard let self else { return }
                self.seeking = false
                if done, self.loadedSrc == src {
                    if self.player !== target { self.player = target }
                    if self.loadedSrc != nil { self.showing = true }
                }
                self.seekNext()
            }
        }
    }
}
