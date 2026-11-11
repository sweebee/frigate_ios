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
    private(set) var url: URL?
    private var pendingStart: Double?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
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
        item.preferredForwardBufferDuration = NetworkStatus.shared.isExpensive ? 8 : 4
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
                self?.finishedCount += 1
            }
        }
        player.replaceCurrentItem(with: item)
        pendingStart = startAt > 0 ? startAt : nil
        if startAt > 0 { seek(to: startAt, precise: true) }
        if autoplay { play() }
    }

    func play() {
        if duration > 0, currentTime >= duration - 0.3 { seek(to: 0) }
        player.playImmediately(atRate: rate)
    }

    func pause() { player.pause() }
    func toggle() { isPlaying ? pause() : play() }

    func seek(to seconds: Double, precise: Bool = false) {
        let t = max(0, duration > 0 ? min(seconds, duration) : seconds)
        currentTime = t
        let tol = precise ? CMTime.zero : CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol) { [weak self] done in
            // Report where the player actually landed; the periodic observer is silent while paused.
            Task { @MainActor in
                guard let self, done, !self.isScrubbing else { return }
                let now = self.player.currentTime().seconds
                if now.isFinite { self.currentTime = now }
            }
        }
    }

    func skip(_ delta: Double) { seek(to: currentTime + delta) }

    func setRate(_ r: Float) {
        rate = r
        if isPlaying { player.rate = r }
    }

    func stop() {
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
