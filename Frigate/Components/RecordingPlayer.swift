import AVFoundation
import SwiftUI

/// Wraps an AVPlayer for HLS recordings from Frigate's /vod endpoint.
@Observable @MainActor
final class RecordingPlayer {
    let player = AVPlayer()
    var currentTime: Double = 0
    var duration: Double = 0
    var isPlaying = false
    var isBuffering = false
    var rate: Float = 1
    var error: String?
    var isScrubbing = false
    /// Incremented each time the current item plays to its end.
    var finishedCount = 0

    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var itemStatusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private(set) var url: URL?
    private(set) var pendingStart: Double?
    /// Seeks still in flight; until they finish the player reports its old position.
    private var seeksInFlight = 0

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                // While a new item is still moving to its start position it reports 0; ignore that.
                guard let self, !self.isScrubbing, self.pendingStart == nil, self.seeksInFlight == 0 else { return }
                self.currentTime = t.seconds.isFinite ? t.seconds : 0
                if let d = self.player.currentItem?.duration.seconds, d.isFinite { self.duration = d }
            }
        }
        statusObserver = player.observe(\.timeControlStatus) { [weak self] p, _ in
            let status = p.timeControlStatus
            Task { @MainActor in
                self?.isPlaying = status == .playing
                self?.isBuffering = status == .waitingToPlayAtSpecifiedRate
            }
        }
    }

    func load(_ url: URL, startAt: Double = 0, autoplay: Bool = true) {
        self.url = url
        error = nil
        currentTime = startAt
        duration = 0
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: [
            // Segments load from the Frigate server directly, so send its login cookies too.
            "AVURLAssetHTTPCookiesKey": HTTPCookieStorage.shared.cookies ?? [],
        ]))
        // 0 lets AVPlayer pick a buffer that fits the connection; on slow links it buffers more.
        item.preferredForwardBufferDuration = 0
        itemStatusObserver = item.observe(\.status) { [weak self] item, _ in
            let failed = item.status == .failed
            let message = item.error?.localizedDescription
            let ready = item.status == .readyToPlay
            Task { @MainActor in
                guard let self else { return }
                if failed { self.error = message ?? L("Playback failed") }
                if ready {
                    let d = item.duration.seconds
                    if d.isFinite { self.duration = d }
                    // A seek issued before the item was ready may land on a keyframe; repeat it exactly.
                    if let pending = self.pendingStart {
                        self.pendingStart = nil
                        self.seek(to: pending, precise: true)
                    }
                }
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.wantsToPlay = false
                self?.finishedCount += 1
            }
        }
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        stallObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Keep going once enough has loaded; play() waits for the buffer.
                if let self, self.wantsToPlay, !self.isScrubbing { self.player.play() }
            }
        }
        player.replaceCurrentItem(with: item)
        pendingStart = startAt > 0 ? startAt : nil
        if startAt > 0 { seek(to: startAt, precise: true) }
        if autoplay { play() }
    }

    /// Whether the user wants playback running. A stall must not count as pausing.
    private(set) var wantsToPlay = false

    func play() {
        if duration > 0, currentTime >= duration - 0.3 { seek(to: 0) }
        wantsToPlay = true
        // play() (unlike playImmediately) waits for enough buffered video and resumes by
        // itself after a stall, instead of stopping when the buffer runs dry on slow links.
        player.defaultRate = rate
        player.play()
    }

    func pause() {
        wantsToPlay = false
        player.pause()
    }

    func toggle() { wantsToPlay ? pause() : play() }

    func seek(to seconds: Double, precise: Bool = false) {
        let t = max(0, duration > 0 ? min(seconds, duration) : seconds)
        currentTime = t
        seeksInFlight += 1
        let tol = precise ? CMTime.zero : CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol) { [weak self] done in
            Task { @MainActor in
                guard let self else { return }
                self.seeksInFlight = max(0, self.seeksInFlight - 1)
                // Report where the player landed once the last seek is done.
                guard done, self.seeksInFlight == 0, !self.isScrubbing else { return }
                let now = self.player.currentTime().seconds
                if now.isFinite { self.currentTime = now }
            }
        }
    }


    // MARK: Scrubbing

    private var scrubTarget: Double?
    private var scrubSeeking = false

    /// Follows a finger on a scrub bar: the picture jumps along, one seek at a time and always
    /// to the latest position, so seeks never pile up behind the finger. Playback holds until
    /// `endScrub`.
    func scrub(to seconds: Double) {
        if !isScrubbing {
            isScrubbing = true
            player.pause()
        }
        currentTime = max(0, duration > 0 ? min(seconds, duration) : seconds)
        scrubTarget = currentTime
        scrubNext()
    }

    private func scrubNext() {
        guard !scrubSeeking, let t = scrubTarget else { return }
        scrubTarget = nil
        scrubSeeking = true
        let tol = CMTime(seconds: 0.25, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
            Task { @MainActor in
                self?.scrubSeeking = false
                self?.scrubNext()
            }
        }
    }

    /// Lets go of the scrub bar: lands exactly there and plays on if it was playing.
    func endScrub(at seconds: Double) {
        scrubTarget = nil
        isScrubbing = false
        seek(to: seconds, precise: true)
        if wantsToPlay {
            player.defaultRate = rate
            player.play()
        }
    }

    /// Exact, so the position does not snap back to a nearby keyframe once the seek lands.
    func skip(_ delta: Double) { seek(to: currentTime + delta, precise: true) }

    func setRate(_ r: Float) {
        rate = r
        player.defaultRate = r
        if wantsToPlay { player.rate = r }
    }

    func stop() {
        wantsToPlay = false
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
        return v
    }

    func updateUIView(_ v: PlayerUIView, context: Context) {
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
    }

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// Round translucent button used over video.
struct OverlayButton: View {
    let systemImage: String
    var size: CGFloat = 44
    var label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.black.opacity(0.6), in: Circle())
        }
        .accessibilityLabel(label)
    }
}

/// Presents a share sheet for files or images.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ShareItem: Identifiable {
    let id = UUID()
    let items: [Any]
}
