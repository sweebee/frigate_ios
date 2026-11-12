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
                if let self, self.wantsToPlay, !self.stepping { self.player.play() }
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
        watchFastPlayback()
    }

    func pause() {
        wantsToPlay = false
        watchFastPlayback()
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


    // MARK: Fast playback

    /// Stepping through the recording instead of playing it, for rates the player cannot reach.
    private var stepTask: Task<Void, Never>?
    private(set) var stepping = false

    /// Above 2x AVPlayer has to decode every frame of a Frigate recording (its HLS has no
    /// I-frame playlist to skip with), which a heavy stream cannot keep up with: 4x stood still.
    /// Try it, and when the position hardly moves, step through keyframes instead: one second
    /// forward every 1/rate seconds, so the speed holds, only less smooth.
    private func watchFastPlayback() {
        stepTask?.cancel()
        stepTask = nil
        stepping = false
        guard rate > 2, wantsToPlay else { return }
        stepTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let before = currentTime
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, wantsToPlay, rate > 2 else { return }
            if currentTime - before >= 1.2 * 1.5 { return }  // native playback keeps up
            stepping = true
            player.pause()
            // Each jump waits for the previous one (a new seek cancels one in flight, and then
            // no frame ever shows); the target follows the clock so the speed holds.
            var basePos = currentTime
            var baseClock = Date()
            var lastTarget = currentTime
            while !Task.isCancelled, wantsToPlay, rate > 2 {
                // Dragging the scrubber or skipping moves the position: continue from there.
                if isScrubbing || abs(currentTime - lastTarget) > 2 {
                    try? await Task.sleep(for: .milliseconds(100))
                    basePos = currentTime
                    baseClock = Date()
                    lastTarget = currentTime
                    continue
                }
                let target = basePos + -baseClock.timeIntervalSinceNow * Double(rate)
                if duration > 0, target >= duration - 0.3 {
                    seek(to: duration)
                    wantsToPlay = false
                    finishedCount += 1
                    break
                }
                currentTime = target
                lastTarget = target
                _ = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                                      toleranceBefore: CMTime(seconds: 1, preferredTimescale: 600), toleranceAfter: .zero)
                currentTime = lastTarget
                try? await Task.sleep(for: .milliseconds(30))
            }
            stepping = false
            if !Task.isCancelled, wantsToPlay { player.rate = rate }
        }
    }

    func skip(_ delta: Double) { seek(to: currentTime + delta) }

    func setRate(_ r: Float) {
        rate = r
        player.defaultRate = r
        if wantsToPlay { player.rate = r }
        watchFastPlayback()
    }

    func stop() {
        wantsToPlay = false
        watchFastPlayback()
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
