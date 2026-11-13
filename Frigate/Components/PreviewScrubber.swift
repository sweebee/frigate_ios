import AVFoundation
import SwiftUI

/// Shows Frigate's low-resolution preview videos while the user drags a timeline, so the
/// picture follows the finger like in Frigate's web UI. Previews are one file per hour
/// (about 320x180, a frame every few seconds). The current hour has no file yet; for it, like
/// Frigate's web UI, the loose preview frames Frigate keeps while the hour runs are shown.
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
    /// Set while the frame on screen comes from the current hour's loose frames, not a video.
    private(set) var frameImage: UIImage?
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
        self.camera = camera
        frames = []
        framesLoaded = .distantPast
        previews = []
        loadedSrc = nil
        players = [:]
        player = AVPlayer()
        let path = "api/preview/\(camera)/start/\(Int(start))/end/\(Int(end))"
        previews = (try? await client.get([Preview].self, path)) ?? []
    }

    /// Shows the preview frame nearest to `wall`, or hides the preview when there is none.
    func show(_ wall: Double) {
        guard let client else { showing = false; return }
        guard let p = previews.first(where: { wall >= $0.start && wall < $0.end }) else {
            // Frigate writes an hour's file only after the hour; until then it keeps loose frames.
            if wall > Date().timeIntervalSince1970 - 7200 { showFrame(wall) } else { showing = false }
            return
        }
        frameImage = nil
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
        frameImage = nil
        pendingFrame = nil
        hides += 1
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

    // MARK: Frames of the running hour

    private var camera = ""
    /// Frame times and file names, oldest first, e.g. preview_front-1712345678.901234.webp.
    private var frames: [(time: Double, name: String)] = []
    private var framesLoaded = Date.distantPast
    private var loadingFrames = false
    private var pendingFrame: Double?
    private var fetchingFrame = false
    private var shownFrame = ""
    private let frameCache = NSCache<NSString, UIImage>()
    /// Counts hide() calls, so a frame that arrives after the scrub ended is not shown.
    private var hides = 0

    private func showFrame(_ wall: Double) {
        pendingFrame = wall
        // New frames keep coming in; look again when scrubbing past the last one.
        let stale = Date().timeIntervalSince(framesLoaded) > 3
        if stale && (frames.isEmpty || wall > (frames.last?.time ?? 0)) { loadFrames() }
        fetchNextFrame()
    }

    private func loadFrames() {
        guard !loadingFrames, let client else { return }
        loadingFrames = true
        let now = Date().timeIntervalSince1970
        let from = (now / 3600).rounded(.down) * 3600 - 3600
        let path = "api/preview/\(camera)/start/\(Int(from))/end/\(Int(now.rounded(.up)))/frames"
        Task { @MainActor in
            defer { loadingFrames = false }
            guard let names = try? await client.get([String].self, path) else { return }
            framesLoaded = Date()
            frames = names.compactMap { name in
                // The time follows the last "-" (camera names may contain one), before ".webp".
                guard let dash = name.lastIndex(of: "-"), let dot = name.lastIndex(of: "."), dash < dot,
                      let t = Double(name[name.index(after: dash)..<dot]) else { return nil }
                return (t, name)
            }.sorted { $0.time < $1.time }
            fetchNextFrame()
        }
    }

    /// Loads one frame at a time, always the one for the latest scrub position.
    private func fetchNextFrame() {
        guard !fetchingFrame, let wall = pendingFrame, let client, !frames.isEmpty else {
            if frames.isEmpty && !loadingFrames && pendingFrame != nil { showing = false }
            return
        }
        pendingFrame = nil
        let i = frames.firstIndex { $0.time >= wall } ?? frames.count - 1
        // Nearest of the frames around the position.
        let j = i > 0 && abs(frames[i - 1].time - wall) < abs(frames[i].time - wall) ? i - 1 : i
        let name = frames[j].name
        // Too far from any frame (nothing was recorded then): no preview.
        guard abs(frames[j].time - wall) < 90 else { showing = false; frameImage = nil; return }
        if name == shownFrame, frameImage != nil { showing = true; return }
        if let cached = frameCache.object(forKey: name as NSString) {
            frameImage = cached; shownFrame = name; showing = true
            fetchNextFrame()
            return
        }
        fetchingFrame = true
        let generation = hides
        Task { @MainActor in
            defer { fetchingFrame = false; fetchNextFrame() }
            let url = client.url("api/preview/\(name)/thumbnail.webp")
            guard let (data, response) = try? await client.session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 300,
                  let img = UIImage(data: data) else { return }
            frameCache.setObject(img, forKey: name as NSString)
            guard generation == hides else { return }
            frameImage = img
            shownFrame = name
            showing = true
        }
    }
}

/// What the scrubber shows over the video: a preview video frame, or a loose frame image.
struct PreviewSurface: View {
    let preview: PreviewScrubber

    var body: some View {
        if let img = preview.frameImage {
            Image(uiImage: img).resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
        } else {
            PlayerLayerView(player: preview.player)
        }
    }
}
