import AVFoundation
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
    /// Called once when the stream cannot play natively (no data, unsupported codec).
    let onFailure: (String) -> Void

    func makeUIView(context: Context) -> SampleView {
        let view = SampleView()
        view.backgroundColor = .black
        view.displayLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        context.coordinator.view = view
        context.coordinator.start(client: client, stream: stream)
        return view
    }

    func updateUIView(_ view: SampleView, context: Context) {
        view.displayLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        context.coordinator.onFailure = onFailure
        if context.coordinator.stream != stream { context.coordinator.start(client: client, stream: stream) }
    }

    static func dismantleUIView(_ view: SampleView, coordinator: Coordinator) {
        coordinator.stop()
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

        init(state: LivePlayerState, onFailure: @escaping (String) -> Void) {
            self.state = state
            self.onFailure = onFailure
        }

        func start(client: FrigateClient, stream: String) {
            stop()
            self.stream = stream
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
                case .format(let format, let size):
                    if size.width > 0 { state.videoSize = size }
                    let fcc = CMFormatDescriptionGetMediaSubType(format)
                case .sample(let sample, let keyframe):
                    if !gotKeyframe {
                        guard keyframe else { continue }
                        gotKeyframe = true
                    }
                    enqueue(sample)
                }
            }
        }

        private func enqueue(_ sample: CMSampleBuffer) {
            guard let layer = view?.displayLayer else { return }
            if layer.status == .failed {
                // A decoder error (e.g. an unsupported codec): try the web player instead.
                fail(layer.error?.localizedDescription ?? "decode failed")
                return
            }
            layer.enqueue(sample)
            lastSample = Date()
            if !state.playing {
                state.playing = true
                state.status = "Live"
                retries = 0
            }
        }

        /// The codecs we can decode, as go2rtc expects them. Without audio codecs go2rtc
        /// sends video only.
        private static var request: String {
            var codecs = ["avc1.640029", "avc1.64002A", "avc1.640033"]
            // HEVC also decodes in software (the simulator); a decoder failure falls back to the web.
            codecs.append("hvc1.1.6.L153.B0")
            return #"{"type":"mse","value":"\#(codecs.joined(separator: ","))"}"#
        }
    }
}

// MARK: - Fragmented MP4

/// Splits a fragmented MP4 stream (an init segment, then moof+mdat fragments) into sample
/// buffers for one video track.
struct FMP4Parser {
    enum Output {
        case format(CMVideoFormatDescription, CGSize)
        case sample(CMSampleBuffer, keyframe: Bool)
    }

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
                if type == "moov", let f = initSegment(at: offset + 8, end: offset + size) { out.append(f) }
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
        if let mvex = boxes.first(where: { $0.type == "mvex" }), let trex = child("trex", mvex.body, mvex.end) {
            // version/flags(4) track_ID(4) sample_description_index(4) duration size flags
            defaultDuration = u32(trex.body + 12)
            defaultSize = u32(trex.body + 16)
            defaultFlags = u32(trex.body + 20)
        }
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
            return .format(desc, CGSize(width: Int(width), height: Int(height)))
        }
        return nil
    }

    // MARK: Fragments

    private mutating func fragment(moofAt moof: Int, moofSize: Int, mdatEnd: Int) -> [Output] {
        guard var format else { return [] }
        var out = [Output]()
        for traf in children(moof + 8, moof + moofSize) where traf.type == "traf" {
            guard let tfhd = child("tfhd", traf.body, traf.end) else { continue }
            let flags = u32(tfhd.body) & 0xFFFFFF
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
            // Live: show each frame as soon as it is decoded instead of on a timeline.
            dict[kCMSampleAttachmentKey_DisplayImmediately] = true
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
