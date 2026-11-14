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
                if status == .playing {
                    self?.reloads = 0
                    self?.player.currentItem?.preferredForwardBufferDuration = 0
                }
            }
        }
    }

    /// `startInPlaylist`: the URL's playlist already begins at `startAt` (EXT-X-START), so no
    /// seek; the position shows `startAt` until the player reports where it is.
    func load(_ url: URL, startAt: Double = 0, autoplay: Bool = true, startInPlaylist: Bool = false) {
        reloads = 0
        replaceItem(url, startAt: startAt, autoplay: autoplay, seekToStart: !startInPlaylist)
    }

    private func replaceItem(_ url: URL, startAt: Double, autoplay: Bool, seekToStart: Bool = true) {
        self.url = url
        error = nil
        currentTime = startAt
        duration = 0
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: [
            // Segments load from the Frigate server directly, so send its login cookies too.
            "AVURLAssetHTTPCookiesKey": HTTPCookieStorage.shared.cookies ?? [],
        ]))
        // Start once a little video is in, like Frigate's web player. Left to choose (0), AVPlayer
        // first buffered about 15 s, which on weak Wi-Fi took 8 to 10 s instead of 4.5 (with the
        // early start in checkProgress). Once it plays, the buffer goes back to automatic so it
        // keeps loading ahead.
        item.preferredForwardBufferDuration = 2
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
        pendingStart = seekToStart && startAt > 0 ? startAt : nil
        if seekToStart && startAt > 0 { seek(to: startAt, precise: true) }
        if autoplay { play() }
        startWatchdog()
    }

    // MARK: Stall recovery

    private var watchdog: Task<Void, Never>?
    /// Reloads since playback last ran; reset by every new `load`.
    private var reloads = 0
    private var stuckSince: Date?
    private var lastProgress = (time: 0.0, buffered: 0.0)

    /// AVPlayer sometimes never finishes loading a recording, or keeps waiting with a full
    /// buffer, until the same URL is opened again. This does that by itself.
    private func startWatchdog() {
        watchdog?.cancel()
        stuckSince = nil
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                self.checkProgress()
            }
        }
    }

    private func checkProgress() {
        guard let item = player.currentItem, let url, error == nil, !isScrubbing else { stuckSince = nil; return }
        let ready = item.status == .readyToPlay
        // Only a wait the user sees: the item not loading, or play that does not start.
        guard !ready || (wantsToPlay && player.timeControlStatus == .waitingToPlayAtSpecifiedRate) else {
            stuckSince = nil
            return
        }
        let t = player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
        let ranges = item.loadedTimeRanges.map(\.timeRangeValue)

        // Start as soon as a few seconds are loaded, like Frigate's web player, instead of
        // waiting while AVPlayer "evaluates the buffering rate", which can take seconds.
        if ready, wantsToPlay, seeksInFlight == 0, pendingStart == nil,
           player.reasonForWaitingToPlay == .toMinimizeStalls || player.reasonForWaitingToPlay == .evaluatingBufferingRate,
           let range = ranges.first(where: { $0.containsTime(player.currentTime()) }),
           range.end.seconds - t >= 3 || (duration > 0 && range.end.seconds >= duration - 0.5) {
            player.playImmediately(atRate: rate)
            stuckSince = nil
            return
        }
        let buffered = ranges.reduce(0.0) { $0 + ($1.duration.seconds.isFinite ? $1.duration.seconds : 0) }
        // Anything still arriving or moving is a slow connection, not a hang.
        if stuckSince == nil || abs(t - lastProgress.time) > 0.05 || abs(buffered - lastProgress.buffered) > 0.05 {
            lastProgress = (t, buffered)
            stuckSince = Date()
            return
        }
        let stuck = Date().timeIntervalSince(stuckSince!)

        // Enough video is there but the player keeps waiting: start it.
        if ready, seeksInFlight == 0, stuck >= 2, let range = ranges.first(where: { $0.containsTime(player.currentTime()) }) {
            let ahead = range.end.seconds - t
            if ahead >= 2 || (duration > 0 && range.end.seconds >= duration - 0.5) {
                player.playImmediately(atRate: rate)
                stuckSince = nil
                return
            }
        }

        // Nothing arrives at all: open the recording again where the user wanted to be.
        // Exact seeks on cameras with few keyframes can take seven seconds; stay above that.
        let limit = Double(ready ? 10 : 12) + Double(reloads) * 5
        guard stuck >= limit else { return }
        guard reloads < 3 else {
            error = L("Playback failed")
            return
        }
        let attempts = reloads + 1
        replaceItem(HLSProxy.shared.refreshed(url), startAt: currentTime, autoplay: wantsToPlay)
        reloads = attempts
    }

    /// After a failure, the next play or seek opens the recording again.
    private func reloadIfFailed(at seconds: Double, autoplay: Bool) -> Bool {
        guard error != nil, let url else { return false }
        load(HLSProxy.shared.refreshed(url), startAt: seconds, autoplay: autoplay)
        return true
    }

    /// Whether the user wants playback running. A stall must not count as pausing.
    private(set) var wantsToPlay = false

    func play() {
        if reloadIfFailed(at: currentTime, autoplay: true) { return }
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

    /// `earlier`: how far before `seconds` the player may land, on a keyframe, to start
    /// sooner; it never lands later than asked.
    func seek(to seconds: Double, precise: Bool = false, earlier: Double = 0) {
        let t = max(0, duration > 0 ? min(seconds, duration) : seconds)
        if reloadIfFailed(at: t, autoplay: wantsToPlay) { return }
        currentTime = t
        seeksInFlight += 1
        let tol = precise ? CMTime.zero : CMTime(seconds: 0.5, preferredTimescale: 600)
        let before = earlier > 0 ? CMTime(seconds: earlier, preferredTimescale: 600) : tol
        let after = earlier > 0 ? CMTime.zero : tol
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: before, toleranceAfter: after) { [weak self] done in
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


    /// Position for a playhead that moves every frame: the player's own clock while it
    /// plays, `currentTime` (updated four times a second) otherwise.
    var liveTime: Double {
        guard isPlaying, !isScrubbing, pendingStart == nil, seeksInFlight == 0 else { return currentTime }
        let t = player.currentTime().seconds
        return t.isFinite ? t : currentTime
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
        watchdog?.cancel()
        watchdog = nil
        wantsToPlay = false
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect
    /// Called with whether the layer has a frame to show. The player's clock can run
    /// while the layer is still (or again, after the app was in the background) empty.
    var onReadyForDisplay: ((Bool) -> Void)? = nil
    /// Clear lets what is underneath (a thumbnail) show until the player has a frame.
    var background: UIColor = .black

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.backgroundColor = background
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
        v.onReady = onReadyForDisplay
        return v
    }

    func updateUIView(_ v: PlayerUIView, context: Context) {
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
        v.onReady = onReadyForDisplay
    }

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        private var observation: NSKeyValueObservation?
        var onReady: ((Bool) -> Void)? {
            didSet {
                guard (onReady == nil) != (observation == nil) else { return }
                observation = onReady == nil ? nil : playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                    let ready = layer.isReadyForDisplay
                    DispatchQueue.main.async { self?.onReady?(ready) }
                }
            }
        }
    }
}

/// The playback controls drawn over a recording: back 10 s, play/pause, forward 10 s and the
/// speed. Shared by the playback and event screens so both look and work the same.
struct PlaybackOverlayControls: View {
    let player: RecordingPlayer
    /// Bigger on iPad and Mac, where the video is big.
    var large = false
    /// Play/pause; the playback screen also jumps over gaps.
    var togglePlay: (() -> Void)? = nil
    /// Called on every use, to keep the controls on screen a while longer.
    var onUse: () -> Void = {}

    static let rates: [Float] = [0.5, 1, 2]
    static func rateTitle(_ r: Float) -> String { r == 0.5 ? "½x" : "\(Int(r))x" }

    var body: some View {
        let size: CGFloat = large ? 56 : 44
        HStack(spacing: large ? 16 : 10) {
            OverlayButton(systemImage: "gobackward.10", size: size, label: "Back 10 seconds") { player.skip(-10); onUse() }
            OverlayButton(systemImage: player.wantsToPlay ? "pause.fill" : "play.fill", size: large ? 64 : 44,
                          label: player.wantsToPlay ? "Pause" : "Play") { (togglePlay ?? player.toggle)(); onUse() }
            OverlayButton(systemImage: "goforward.10", size: size, label: "Forward 10 seconds") { player.skip(10); onUse() }
            Menu {
                ForEach(Self.rates, id: \.self) { r in
                    Button { player.setRate(r); onUse() } label: {
                        if player.rate == r { Label(Self.rateTitle(r), systemImage: "checkmark") } else { Text(Self.rateTitle(r)) }
                    }
                }
            } label: {
                Text(Self.rateTitle(player.rate))
                    .font(.system(size: large ? 16 : 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(.black.opacity(0.6), in: Circle())
            }
            .accessibilityLabel("Playback speed")
        }
        .padding(large ? 16 : 10)
    }
}

/// Enters or leaves full screen over a video; Escape leaves it on the Mac.
struct FullscreenButton: View {
    let isOn: Bool
    var size: CGFloat = 36
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.black.opacity(0.6), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Exit full screen" : "Full screen")
        .help(Text(isOn ? "Exit full screen" : "Full screen"))
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
