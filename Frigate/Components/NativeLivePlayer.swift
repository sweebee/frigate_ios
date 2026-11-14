import AVFoundation
import AVKit
import SwiftUI
import VideoToolbox

/// Plays go2rtc's MSE stream without a web view: the fragmented MP4 that arrives over the
/// websocket is split into samples here and shown with AVSampleBufferDisplayLayer. Web views
/// in apps on the Mac have no MediaSource or WebRTC, so this is the only way to get real
/// video there; on iPhone and iPad it also skips the web view's overhead.
struct NativeLivePlayer: UIViewRepresentable {
    let client: FrigateClient
    let stream: String
    let state: LivePlayerState
    var fill = false
    var pip = false
    /// Called once when the stream cannot play natively (no data, unsupported codec).
    let onFailure: (String) -> Void

    func makeUIView(context: Context) -> SampleView {
        let view = SampleView()
        view.backgroundColor = .black
        view.displayLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        context.coordinator.view = view
        if pip { context.coordinator.setUpPiP() }
        context.coordinator.start(client: client, stream: stream)
        return view
    }

    func updateUIView(_ view: SampleView, context: Context) {
        view.displayLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        context.coordinator.onFailure = onFailure
        context.coordinator.setMuted(state.muted)
        if context.coordinator.stream != stream { context.coordinator.start(client: client, stream: stream) }
    }

    static func dismantleUIView(_ view: SampleView, coordinator: Coordinator) {
        coordinator.stop()
        coordinator.tearDownPiP()
    }

    func makeCoordinator() -> Coordinator { Coordinator(state: state, onFailure: onFailure) }

    final class SampleView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    }

    @MainActor
    final class Coordinator {
        let state: LivePlayerState
        var onFailure: (String) -> Void
        weak var view: SampleView?
        private(set) var stream = ""
        private var task: URLSessionWebSocketTask?
        private var parser = FMP4Parser()
        private var receiving: Task<Void, Never>?
        private var watchdog: Task<Void, Never>?
        private var lastSample = Date.distantPast
        private var gotKeyframe = false
        private var failed = false
        private var retries = 0
        /// Live audio: AAC from the stream through a renderer on its own clock. The picture
        /// shows each frame as it arrives, so the audio is not synced to it, as in any live view.
        private var audioRenderer: AVSampleBufferAudioRenderer?
        private var synchronizer: AVSampleBufferRenderSynchronizer?
        private var pip: LivePiP?
        /// This stream in the shared hub: samples go there, and a player that opens the same
        /// stream (a tile's camera opened full) starts from them instead of waiting.
        private var hubKey: String?
        private let hubID = UUID()
        /// Showing another player's samples until this one's own stream reaches a keyframe.
        private var borrowing = false
        /// Set the clock again from the next frame shown (a new stream, or a jump).
        private var needsClockSync = true
        /// How far behind the stream the picture runs, to even out the network's bursts.
        private static let latency = CMTime(value: 1, timescale: 4)

        /// Picture in picture for this player's video layer, where the device supports it.
        func setUpPiP() {
            guard pip == nil, let layer = view?.displayLayer, AVPictureInPictureController.isPictureInPictureSupported() else { return }
            pip = LivePiP(layer: layer, state: state)
        }

        func tearDownPiP() {
            pip?.stop()
            pip = nil
            state.pipPossible = false
            state.pipActive = false
            state.togglePiP = nil
        }

        init(state: LivePlayerState, onFailure: @escaping (String) -> Void) {
            self.state = state
            self.onFailure = onFailure
        }

        func start(client: FrigateClient, stream: String) {
            stop()
            needsClockSync = true
            self.stream = stream
            let key = LiveSampleHub.key(client: client, stream: stream)
            hubKey = key
            failed = false
            gotKeyframe = false
            parser = FMP4Parser()
            state.status = "Connecting"
            state.activeMode = "mse"
            state.playing = false
            state.hasAudio = false
            let task = client.session.webSocketTask(with: client.liveSocketURL(stream: stream, mode: "mse"))
            // A keyframe fragment of a high-resolution stream can exceed the 1 MB default.
            task.maximumMessageSize = 32 * 1024 * 1024
            self.task = task
            task.resume()
            task.send(.string(Self.request)) { _ in }
            // The same stream already plays elsewhere (the overview tile): show its picture
            // right away and follow it until this connection has a keyframe of its own.
            if let (gop, size) = LiveSampleHub.shared.subscribe(key, id: hubID, handler: { [weak self] sample in
                self?.enqueue(sample)
            }) {
                borrowing = true
                if size.width > 0 { state.videoSize = size }
                // Decode the frames since the keyframe, but show only the latest: shown one by
                // one they flashed by as a fast-forward.
                for (i, sample) in gop.enumerated() {
                    let last = i == gop.count - 1
                    enqueue(last ? sample : Self.hidden(sample) ?? sample, shown: last)
                }
            }
            let started = Date()
            receiving = Task { [weak self] in
                while !Task.isCancelled {
                    let message: URLSessionWebSocketTask.Message
                    do { message = try await task.receive() } catch {
                        // A socket closed by stop() (leaving the screen, reconnecting) also
                        // ends up here; only a failure of the current connection counts.
                        await MainActor.run {
                            guard let self, self.task === task else { return }
                            self.fail("connection closed: \(error.localizedDescription)")
                        }
                        return
                    }
                    guard let self, self.task === task else { return }
                    switch message {
                    case .data(let data): self.handle(data)
                    case .string(let text):
                        if text.contains("\"error\"") { self.fail(text) }
                    @unknown default: break
                    }
                }
            }
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, !Task.isCancelled else { return }
                    if !self.state.playing {
                        if Date().timeIntervalSince(started) > 10 { self.fail("no video"); return }
                    } else if Date().timeIntervalSince(self.lastSample) > 6 {
                        // Stalled: reconnect, a few times before giving up.
                        self.retries += 1
                        if self.retries > 3 { self.fail("stalled"); return }
                        self.state.status = "Reconnecting"
                        self.start(client: client, stream: stream)
                        return
                    }
                }
            }
        }

        func stop() {
            if let hubKey {
                LiveSampleHub.shared.unsubscribe(hubKey, id: hubID)
                LiveSampleHub.shared.publisherStopped(hubKey, id: hubID)
            }
            borrowing = false
            if let sync = synchronizer, let renderer = audioRenderer {
                sync.setRate(0, time: .zero)
                renderer.flush()
                sync.removeRenderer(renderer, at: .zero)
            }
            audioRenderer = nil
            synchronizer = nil
            receiving?.cancel()
            watchdog?.cancel()
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            view?.displayLayer.flushAndRemoveImage()
        }

        private func fail(_ reason: String) {
            guard !failed else { return }
            failed = true
            #if DEBUG
            NSLog("[native] %@ failed: %@", stream, reason)
            #endif
            stop()
            onFailure(reason)
        }

        private func handle(_ data: Data) {
            let output = parser.feed(data)
            for item in output {
                switch item {
                case .format(_, let size):
                    if size.width > 0 { state.videoSize = size }
                    if let hubKey { LiveSampleHub.shared.setSize(hubKey, size) }
                case .audioFormat:
                    setUpAudio()
                case .audio(let sample):
                    enqueueAudio(sample)
                case .sample(let sample, let keyframe):
                    if !gotKeyframe {
                        guard keyframe else { continue }
                        gotKeyframe = true
                        // Its own stream from here on.
                        if borrowing, let hubKey {
                            LiveSampleHub.shared.unsubscribe(hubKey, id: hubID)
                            borrowing = false
                            // Its own stream has its own timestamps.
                            needsClockSync = true
                        }
                    }
                    enqueue(sample)
                    if let hubKey { LiveSampleHub.shared.publish(hubKey, id: hubID, sample: sample, keyframe: keyframe) }
                }
            }
        }

        private func setUpAudio() {
            guard audioRenderer == nil else { return }
            let renderer = AVSampleBufferAudioRenderer()
            let sync = AVSampleBufferRenderSynchronizer()
            sync.addRenderer(renderer)
            renderer.isMuted = state.muted
            audioRenderer = renderer
            synchronizer = sync
            state.hasAudio = true
        }

        /// Follows the mute button; the audio session is set to playback on the first unmute.
        func setMuted(_ muted: Bool) {
            audioRenderer?.isMuted = muted
            if !muted {
                let session = AVAudioSession.sharedInstance()
                if session.category != .playAndRecord { try? session.setCategory(.playback, mode: .default) }
                try? session.setActive(true)
            }
        }

        private func enqueueAudio(_ sample: CMSampleBuffer) {
            guard let renderer = audioRenderer, let sync = synchronizer else { return }
            if renderer.status == .failed { audioRenderer = nil; synchronizer = nil; state.hasAudio = false; return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            // Start the clock at the first frame; restart it when the audio falls behind or
            // runs too far ahead (a stall), so the delay stays small.
            let now = sync.currentTime()
            if sync.rate == 0 || CMTimeGetSeconds(pts - now) > 1.0 || CMTimeGetSeconds(now - pts) > 0.5 {
                renderer.flush()
                sync.setRate(1, time: pts - CMTime(value: 1, timescale: 5))
            }
            if renderer.isReadyForMoreMediaData { renderer.enqueue(sample) }
        }

        /// `shown`: false for frames only decoded to catch up (they cannot set the clock).
        private func enqueue(_ sample: CMSampleBuffer, shown: Bool = true) {
            guard let layer = view?.displayLayer else { return }
            if layer.status == .failed {
                // A decoder error (e.g. an unsupported codec): try the web player instead.
                fail(layer.error?.localizedDescription ?? "decode failed")
                return
            }
            // Frames show on a clock running `latency` behind the stream, so they come at an
            // even pace. The clock is set again when frames would be late (a stall) or the
            // picture falls more than a second and a half behind.
            if layer.controlTimebase == nil {
                var timebase: CMTimebase?
                CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
                if let timebase {
                    CMTimebaseSetRate(timebase, rate: 1)
                    layer.controlTimebase = timebase
                }
                needsClockSync = true
            }
            if shown, let timebase = layer.controlTimebase {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let ahead = CMTimeGetSeconds(pts - CMTimebaseGetTime(timebase))
                if needsClockSync || ahead < -0.05 || ahead > 1.5 {
                    CMTimebaseSetTime(timebase, time: pts - Self.latency)
                    needsClockSync = false
                }
            }
            layer.enqueue(sample)
            lastSample = Date()
            if !state.playing {
                pip?.videoStarted()
                state.playing = true
                state.status = "Live"
                retries = 0
            }
        }

        /// A copy of `sample` that the layer decodes but does not show.
        private static func hidden(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
            var copy: CMSampleBuffer?
            guard CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleBufferOut: &copy) == noErr,
                  let copy, let attachments = CMSampleBufferGetSampleAttachmentsArray(copy, createIfNecessary: true),
                  CFArrayGetCount(attachments) > 0 else { return nil }
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanFalse).toOpaque())
            return copy
        }

        /// The codecs we can decode, as go2rtc expects them. Without audio codecs go2rtc
        /// sends video only.
        private static var request: String {
            var codecs = ["avc1.640029", "avc1.64002A", "avc1.640033"]
            // HEVC also decodes in software (the simulator); a decoder failure falls back to the web.
            codecs.append("hvc1.1.6.L153.B0")
            // AAC, the audio most cameras send; go2rtc adds an audio track when there is one.
            codecs += ["mp4a.40.2", "mp4a.40.5"]
            return #"{"type":"mse","value":"\#(codecs.joined(separator: ","))"}"#
        }
    }
}

// MARK: - Fragmented MP4

/// Splits a fragmented MP4 stream (an init segment, then moof+mdat fragments) into sample
/// buffers for one video track and, when go2rtc sends one, an AAC audio track.
struct FMP4Parser {
    enum Output {
        case format(CMVideoFormatDescription, CGSize)
        case sample(CMSampleBuffer, keyframe: Bool)
        case audioFormat(CMAudioFormatDescription)
        case audio(CMSampleBuffer)
    }

    /// Per-track sample defaults from the init segment's trex boxes.
    private struct TrackDefaults { var duration: UInt32 = 0; var size: UInt32 = 0; var flags: UInt32 = 0 }
    private var defaults: [UInt32: TrackDefaults] = [:]
    private var audioFormat: CMAudioFormatDescription?
    private var audioTrackID: UInt32?
    private var audioTimescale: UInt32 = 48000

    private var buffer = [UInt8]()
    private var format: CMVideoFormatDescription?
    private var timescale: UInt32 = 90000
    private var trackID: UInt32 = 1
    private var defaultDuration: UInt32 = 0
    private var defaultSize: UInt32 = 0
    private var defaultFlags: UInt32 = 0
    private var isHEVC = false
    private var nalLengthSize = 4
    /// Parameter sets the current HEVC format was built from.
    private var hevcParams: [[UInt8]] = []

    mutating func feed(_ data: Data) -> [Output] {
        buffer.append(contentsOf: data)
        var out = [Output]()
        var offset = 0
        while true {
            guard let (type, size) = header(at: offset) else { break }
            if type == "moof" {
                // A fragment is moof followed by its mdat; wait until both are in.
                guard let (next, mdatSize) = header(at: offset + size), next == "mdat" else {
                    if header(at: offset + size) != nil { offset += size; continue } // stray moof
                    break
                }
                out += fragment(moofAt: offset, moofSize: size, mdatEnd: offset + size + mdatSize)
                offset += size + mdatSize
            } else {
                if type == "moov" {
                    if let f = initSegment(at: offset + 8, end: offset + size) { out.append(f) }
                    if let a = pendingAudio { out.append(.audioFormat(a)); pendingAudio = nil }
                }
                offset += size
            }
        }
        if offset > 0 { buffer.removeFirst(offset) }
        return out
    }

    /// Type and full size of the box at `offset`, when all of it has arrived.
    private func header(at offset: Int) -> (String, Int)? {
        guard offset + 8 <= buffer.count else { return nil }
        var size = Int(u32(offset))
        let type = String(bytes: buffer[offset + 4..<offset + 8], encoding: .ascii) ?? ""
        if size == 1 {
            guard offset + 16 <= buffer.count else { return nil }
            size = Int(u64(offset + 8))
        }
        guard size >= 8, offset + size <= buffer.count else { return nil }
        return (type, size)
    }

    /// Child boxes of a container between `start` and `end`.
    private func children(_ start: Int, _ end: Int) -> [(type: String, body: Int, end: Int)] {
        var list = [(String, Int, Int)]()
        var p = start
        while p + 8 <= end {
            let size = Int(u32(p))
            guard size >= 8, p + size <= end else { break }
            let type = String(bytes: buffer[p + 4..<p + 8], encoding: .ascii) ?? ""
            list.append((type, p + 8, p + size))
            p += size
        }
        return list
    }

    private func child(_ type: String, _ start: Int, _ end: Int) -> (body: Int, end: Int)? {
        children(start, end).first { $0.type == type }.map { ($0.body, $0.end) }
    }

    // MARK: Init segment

    private mutating func initSegment(at start: Int, end: Int) -> Output? {
        let boxes = children(start, end)
        if let mvex = boxes.first(where: { $0.type == "mvex" }) {
            // version/flags(4) track_ID(4) sample_description_index(4) duration size flags
            for trex in children(mvex.body, mvex.end) where trex.type == "trex" {
                defaults[u32(trex.body + 4)] = TrackDefaults(duration: u32(trex.body + 12), size: u32(trex.body + 16),
                                                             flags: u32(trex.body + 20))
            }
        }
        var result: Output?
        for trak in boxes where trak.type == "trak" { if let a = audioTrack(trak.body, trak.end) { pendingAudio = a } }
        for trak in boxes where trak.type == "trak" {
            guard let mdia = child("mdia", trak.body, trak.end),
                  let hdlr = child("hdlr", mdia.body, mdia.end),
                  String(bytes: buffer[hdlr.body + 8..<hdlr.body + 12], encoding: .ascii) == "vide",
                  let mdhd = child("mdhd", mdia.body, mdia.end),
                  let minf = child("minf", mdia.body, mdia.end),
                  let stbl = child("stbl", minf.body, minf.end),
                  let stsd = child("stsd", stbl.body, stbl.end) else { continue }
            if let tkhd = child("tkhd", trak.body, trak.end) {
                trackID = buffer[tkhd.body] == 1 ? u32(tkhd.body + 20) : u32(tkhd.body + 12)
            }
            timescale = buffer[mdhd.body] == 1 ? u32(mdhd.body + 20) : u32(mdhd.body + 12)
            // stsd: version/flags(4) entry_count(4), then the sample entry box.
            let entry = stsd.body + 8
            guard entry + 8 + 78 <= stsd.end else { continue }
            let entrySize = Int(u32(entry))
            let codec = String(bytes: buffer[entry + 4..<entry + 8], encoding: .ascii) ?? ""
            let width = Int32(u16(entry + 8 + 24)), height = Int32(u16(entry + 8 + 26))
            let configType = codec.hasPrefix("hv") || codec.hasPrefix("hev") ? "hvcC" : "avcC"
            guard let config = child(configType, entry + 8 + 78, entry + entrySize) else { continue }
            let atoms = [configType: Data(buffer[config.body..<config.end])] as CFDictionary
            let extensions = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms] as CFDictionary
            var desc: CMVideoFormatDescription?
            let codecType = configType == "hvcC" ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
            CMVideoFormatDescriptionCreate(allocator: nil, codecType: codecType, width: width, height: height,
                                           extensions: extensions, formatDescriptionOut: &desc)
            guard let desc else { continue }
            isHEVC = configType == "hvcC"
            let config0 = config.body
            if isHEVC, config.end - config0 > 21 { nalLengthSize = Int(buffer[config0 + 21] & 3) + 1 }
            if !isHEVC, config.end - config0 > 4 { nalLengthSize = Int(buffer[config0 + 4] & 3) + 1 }
            format = desc
            if let d = defaults[trackID] { defaultDuration = d.duration; defaultSize = d.size; defaultFlags = d.flags }
            result = .format(desc, CGSize(width: Int(width), height: Int(height)))
            break
        }
        return result
    }

    /// An audio format found in the init segment, handed out with the next feed.
    private var pendingAudio: CMAudioFormatDescription?

    /// An AAC ("mp4a") track: its id, timescale and format. Other audio codecs are skipped.
    private mutating func audioTrack(_ start: Int, _ end: Int) -> CMAudioFormatDescription? {
        guard let mdia = child("mdia", start, end),
              let hdlr = child("hdlr", mdia.body, mdia.end),
              String(bytes: buffer[hdlr.body + 8..<hdlr.body + 12], encoding: .ascii) == "soun",
              let mdhd = child("mdhd", mdia.body, mdia.end),
              let minf = child("minf", mdia.body, mdia.end),
              let stbl = child("stbl", minf.body, minf.end),
              let stsd = child("stsd", stbl.body, stbl.end) else { return nil }
        let entry = stsd.body + 8
        // Sample entry header (8) + reserved/data ref (8) + audio fields (20), then child boxes.
        guard entry + 36 <= stsd.end else { return nil }
        let entrySize = Int(u32(entry))
        guard String(bytes: buffer[entry + 4..<entry + 8], encoding: .ascii) == "mp4a",
              let esds = child("esds", entry + 36, entry + entrySize), esds.end - esds.body > 4 else { return nil }
        let channels = UInt32(u16(entry + 8 + 16))
        let rate = Double(u32(entry + 8 + 24) >> 16)
        // The ES descriptor after esds' version and flags is the decoder's magic cookie.
        let cookie = Array(buffer[esds.body + 4..<esds.end])
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                                               mChannelsPerFrame: max(1, channels), mBitsPerChannel: 0, mReserved: 0)
        var desc: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: cookie.count, magicCookie: raw.baseAddress,
                                           extensions: nil, formatDescriptionOut: &desc)
        }
        guard status == noErr, let desc else { return nil }
        if let tkhd = child("tkhd", start, end) {
            audioTrackID = buffer[tkhd.body] == 1 ? u32(tkhd.body + 20) : u32(tkhd.body + 12)
        }
        audioTimescale = buffer[mdhd.body] == 1 ? u32(mdhd.body + 20) : u32(mdhd.body + 12)
        audioFormat = desc
        return desc
    }

    // MARK: Fragments

    private mutating func fragment(moofAt moof: Int, moofSize: Int, mdatEnd: Int) -> [Output] {
        guard var format else { return [] }
        var out = [Output]()
        for traf in children(moof + 8, moof + moofSize) where traf.type == "traf" {
            guard let tfhd = child("tfhd", traf.body, traf.end) else { continue }
            let flags = u32(tfhd.body) & 0xFFFFFF
            if let audioTrackID, u32(tfhd.body + 4) == audioTrackID {
                out += audioFragment(traf: traf, tfhd: tfhd, flags: flags, moof: moof, mdatEnd: mdatEnd)
                continue
            }
            guard u32(tfhd.body + 4) == trackID else { continue }
            var p = tfhd.body + 8
            var base = moof
            if flags & 0x01 != 0 { base = Int(u64(p)); p += 8 }
            if flags & 0x02 != 0 { p += 4 }
            var duration = defaultDuration, size = defaultSize, sampleFlags = defaultFlags
            if flags & 0x08 != 0 { duration = u32(p); p += 4 }
            if flags & 0x10 != 0 { size = u32(p); p += 4 }
            if flags & 0x20 != 0 { sampleFlags = u32(p); p += 4 }
            if flags & 0x01 == 0 { base = moof } // default-base-is-moof, or no base: moof start

            var decodeTime: UInt64 = 0
            if let tfdt = child("tfdt", traf.body, traf.end) {
                decodeTime = buffer[tfdt.body] == 1 ? u64(tfdt.body + 4) : UInt64(u32(tfdt.body + 4))
            }
            for trun in children(traf.body, traf.end) where trun.type == "trun" {
                let tf = u32(trun.body) & 0xFFFFFF
                let version = buffer[trun.body]
                let count = Int(u32(trun.body + 4))
                var q = trun.body + 8
                var dataStart = base
                if tf & 0x01 != 0 { dataStart = base + Int(Int32(bitPattern: u32(q))); q += 4 }
                var firstFlags: UInt32?
                if tf & 0x04 != 0 { firstFlags = u32(q); q += 4 }
                var at = dataStart
                for i in 0..<count {
                    var d = duration, s = size, f = (i == 0 ? firstFlags : nil) ?? sampleFlags
                    var cto: Int64 = 0
                    if tf & 0x100 != 0 { d = u32(q); q += 4 }
                    if tf & 0x200 != 0 { s = u32(q); q += 4 }
                    if tf & 0x400 != 0 { f = u32(q); q += 4 }
                    if tf & 0x800 != 0 {
                        cto = version == 0 ? Int64(u32(q)) : Int64(Int32(bitPattern: u32(q)))
                        q += 4
                    }
                    guard at >= 0, at + Int(s) <= mdatEnd else { break }
                    let keyframe = f & 0x10000 == 0
                    // go2rtc often sends HEVC parameter sets in the stream rather than in hvcC;
                    // without them the decoder shows nothing. Build the format from them.
                    if isHEVC && keyframe, let updated = hevcFormat(at: at, size: Int(s)) {
                        format = updated
                        self.format = updated
                        out.append(.format(updated, .zero))
                    }
                    if let sample = makeSample(at: at, size: Int(s), format: format, decodeTime: decodeTime,
                                               duration: d, offset: cto, keyframe: keyframe) {
                        out.append(.sample(sample, keyframe: keyframe))
                    }
                    at += Int(s)
                    decodeTime += UInt64(d)
                }
            }
        }
        return out
    }

    /// The AAC frames of an audio traf, one sample buffer each.
    private func audioFragment(traf: (type: String, body: Int, end: Int), tfhd: (body: Int, end: Int), flags: UInt32,
                               moof: Int, mdatEnd: Int) -> [Output] {
        guard let audioFormat, let audioTrackID else { return [] }
        let d = defaults[audioTrackID] ?? TrackDefaults()
        var p = tfhd.body + 8
        var base = moof
        if flags & 0x01 != 0 { base = Int(u64(p)); p += 8 }
        if flags & 0x02 != 0 { p += 4 }
        var duration = d.duration, size = d.size
        if flags & 0x08 != 0 { duration = u32(p); p += 4 }
        if flags & 0x10 != 0 { size = u32(p); p += 4 }
        if flags & 0x01 == 0 { base = moof }
        var decodeTime: UInt64 = 0
        if let tfdt = child("tfdt", traf.body, traf.end) {
            decodeTime = buffer[tfdt.body] == 1 ? u64(tfdt.body + 4) : UInt64(u32(tfdt.body + 4))
        }
        var out = [Output]()
        for trun in children(traf.body, traf.end) where trun.type == "trun" {
            let tf = u32(trun.body) & 0xFFFFFF
            let count = Int(u32(trun.body + 4))
            var q = trun.body + 8
            var at = base
            if tf & 0x01 != 0 { at = base + Int(Int32(bitPattern: u32(q))); q += 4 }
            if tf & 0x04 != 0 { q += 4 }
            for _ in 0..<count {
                var dur = duration, s = size
                if tf & 0x100 != 0 { dur = u32(q); q += 4 }
                if tf & 0x200 != 0 { s = u32(q); q += 4 }
                if tf & 0x400 != 0 { q += 4 }
                if tf & 0x800 != 0 { q += 4 }
                guard at >= 0, s > 0, at + Int(s) <= mdatEnd else { break }
                if let sample = makeAudioSample(at: at, size: Int(s), format: audioFormat, time: decodeTime) {
                    out.append(.audio(sample))
                }
                at += Int(s)
                decodeTime += UInt64(dur)
            }
        }
        return out
    }

    private func makeAudioSample(at offset: Int, size: Int, format: CMAudioFormatDescription, time: UInt64) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: size,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: size, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = buffer.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress! + offset, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: size)
        }
        guard copied == noErr else { return nil }
        var packet = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(size))
        var sample: CMSampleBuffer?
        let pts = CMTime(value: CMTimeValue(time), timescale: Int32(audioTimescale))
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            presentationTimeStamp: pts, packetDescriptions: &packet, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    /// A format from the VPS, SPS and PPS inside a keyframe, when they differ from the last ones.
    private mutating func hevcFormat(at start: Int, size: Int) -> CMVideoFormatDescription? {
        var sets: [UInt8: [UInt8]] = [:]
        var p = start
        let end = start + size
        while p + nalLengthSize <= end {
            var length = 0
            for i in 0..<nalLengthSize { length = length << 8 | Int(buffer[p + i]) }
            p += nalLengthSize
            guard length > 0, p + length <= end else { break }
            let type = (buffer[p] >> 1) & 0x3F
            if type == 32 || type == 33 || type == 34, sets[type] == nil { sets[type] = Array(buffer[p..<p + length]) }
            p += length
        }
        guard let vps = sets[32], let sps = sets[33], let pps = sets[34] else { return nil }
        let params = [vps, sps, pps]
        guard params != hevcParams else { return nil }
        var desc: CMFormatDescription?
        let status = vps.withUnsafeBufferPointer { v in sps.withUnsafeBufferPointer { s in pps.withUnsafeBufferPointer { q in
            let pointers = [v.baseAddress!, s.baseAddress!, q.baseAddress!]
            let sizes = [vps.count, sps.count, pps.count]
            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: nil, parameterSetCount: 3, parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: Int32(nalLengthSize), extensions: nil, formatDescriptionOut: &desc)
        } } }
        guard status == noErr, let desc else { return nil }
        hevcParams = params
        return desc
    }

    private func makeSample(at offset: Int, size: Int, format: CMVideoFormatDescription, decodeTime: UInt64,
                            duration: UInt32, offset cto: Int64, keyframe: Bool) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: size,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: size, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = buffer.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress! + offset, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: size)
        }
        guard copied == noErr else { return nil }
        let scale = Int32(timescale)
        var timing = CMSampleTimingInfo(duration: CMTime(value: CMTimeValue(duration), timescale: scale),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(Int64(decodeTime) + cto), timescale: scale),
                                        decodeTimeStamp: CMTime(value: CMTimeValue(decodeTime), timescale: scale))
        var sampleSize = size
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           let dict = (attachments as NSArray).firstObject as? NSMutableDictionary {
            // Shown on the player's clock (see `Coordinator.enqueue`), not as each one arrives:
            // frames come over the network in bursts, and shown on arrival a 25 fps camera
            // stuttered.
            if !keyframe { dict[kCMSampleAttachmentKey_NotSync] = true }
        }
        return sample
    }

    // MARK: Bytes

    private func u16(_ i: Int) -> UInt16 { UInt16(buffer[i]) << 8 | UInt16(buffer[i + 1]) }
    private func u32(_ i: Int) -> UInt32 {
        UInt32(buffer[i]) << 24 | UInt32(buffer[i + 1]) << 16 | UInt32(buffer[i + 2]) << 8 | UInt32(buffer[i + 3])
    }
    private func u64(_ i: Int) -> UInt64 { UInt64(u32(i)) << 32 | UInt64(u32(i + 4)) }
}

// MARK: - Picture in picture

/// Picture in picture for the native live player: the same video layer moves into the system's
/// floating window. iPhone and iPad only: on the Mac (Catalyst) the system does not take a sample
/// buffer layer ("content source not supported"), so the button does not show there. Live: no
/// time range to seek in, and pausing is not offered.
@MainActor
final class LivePiP: NSObject, AVPictureInPictureControllerDelegate {
    private let controller: AVPictureInPictureController
    private weak var state: LivePlayerState?
    private var possibleObservation: NSKeyValueObservation?

    init(layer: AVSampleBufferDisplayLayer, state: LivePlayerState) {
        self.state = state
        // Picture in picture is only possible with a playback audio session in place.
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord { try? session.setCategory(.playback, mode: .moviePlayback) }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: PiPPlayback.shared)
        controller = AVPictureInPictureController(contentSource: source)
        super.init()
        controller.delegate = self
        controller.requiresLinearPlayback = true
        #if !targetEnvironment(macCatalyst)
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        #endif
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            let possible = c.isPictureInPicturePossible
            Task { @MainActor in self?.state?.pipPossible = possible }
        }
        state.togglePiP = { [weak self] in self?.toggle() }
    }

    func toggle() {
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            // The system needs an active playback session for the window to keep running.
            let session = AVAudioSession.sharedInstance()
            if session.category != .playAndRecord { try? session.setCategory(.playback, mode: .moviePlayback) }
            try? session.setActive(true)
            controller.startPictureInPicture()
        }
    }

    /// The first frame is on the layer: the system checks again whether the window can open.
    func videoStarted() {
        controller.invalidatePlaybackState()
    }

    func stop() {
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() }
        possibleObservation = nil
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in self.state?.pipActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in self.state?.pipActive = false }
    }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        NSLog("Tender PiP failed: \(error.localizedDescription)")
        Task { @MainActor in self.state?.pipActive = false }
    }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler done: @escaping (Bool) -> Void) {
        // The camera screen is still there underneath; the video goes back into it.
        done(true)
    }
}

/// Live playback as the picture-in-picture window sees it: always playing, no timeline.
final class PiPPlayback: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    static let shared = PiPPlayback()
    static let liveRange = CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)

    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange { Self.liveRange }
    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { false }
    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize size: CMVideoDimensions) {}
    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval interval: CMTime,
                                    completion: @escaping () -> Void) { completion() }
}

// MARK: - Sharing a stream between players

/// The video samples of each live stream that plays, since its last keyframe, so a second
/// player of the same stream (the camera opened from its overview tile) shows the picture at
/// once and follows along, instead of waiting a few seconds for the next keyframe.
@MainActor
final class LiveSampleHub {
    static let shared = LiveSampleHub()

    static func key(client: FrigateClient, stream: String) -> String {
        client.baseURL.absoluteString + "|" + stream
    }

    private final class Feed {
        var gop: [CMSampleBuffer] = []
        var size: CGSize = .zero
        var updated = Date.distantPast
        var publishers: Set<UUID> = []
        var subscribers: [UUID: (CMSampleBuffer) -> Void] = [:]
    }

    private var feeds: [String: Feed] = [:]

    private func feed(_ key: String) -> Feed {
        if let f = feeds[key] { return f }
        let f = Feed()
        feeds[key] = f
        return f
    }

    func publish(_ key: String, id: UUID, sample: CMSampleBuffer, keyframe: Bool) {
        let f = feed(key)
        f.publishers.insert(id)
        if keyframe { f.gop = [] }
        f.gop.append(sample)
        // A camera with a long keyframe interval: keep it bounded (about 10 s at 30 fps).
        if f.gop.count > 300 { f.gop = [] }
        f.updated = Date()
        for (sub, handler) in f.subscribers where sub != id { handler(sample) }
    }

    func setSize(_ key: String, _ size: CGSize) {
        if size.width > 0 { feed(key).size = size }
    }

    /// The samples since the last keyframe and the picture size, when another player is
    /// showing this stream now; from then on `handler` gets each new sample.
    func subscribe(_ key: String, id: UUID, handler: @escaping (CMSampleBuffer) -> Void) -> ([CMSampleBuffer], CGSize)? {
        guard let f = feeds[key], !f.publishers.subtracting([id]).isEmpty, !f.gop.isEmpty,
              Date().timeIntervalSince(f.updated) < 1.5 else { return nil }
        f.subscribers[id] = handler
        return (f.gop, f.size)
    }

    /// Whether some player shows this stream right now.
    func isPlaying(_ key: String) -> Bool {
        guard let f = feeds[key] else { return false }
        return !f.publishers.isEmpty && !f.gop.isEmpty && Date().timeIntervalSince(f.updated) < 1.5
    }

    /// Whether another player follows this stream (a camera opened from its tile).
    func hasSubscribers(_ key: String) -> Bool { !(feeds[key]?.subscribers.isEmpty ?? true) }

    func unsubscribe(_ key: String, id: UUID) {
        feeds[key]?.subscribers[id] = nil
    }

    func publisherStopped(_ key: String, id: UUID) {
        guard let f = feeds[key] else { return }
        f.publishers.remove(id)
        if f.publishers.isEmpty && f.subscribers.isEmpty { feeds[key] = nil }
    }
}
