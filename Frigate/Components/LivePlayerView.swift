import AVFoundation
import SwiftUI
import WebKit

/// State shared between the live player and its controls.
@Observable @MainActor
final class LivePlayerState {
    enum Mode: String, CaseIterable { case auto, mse, webrtc, mjpeg }

    var muted = true
    /// UserDefaults key: the user last turned the sound on in a camera's live view.
    static let soundKey = "liveSound"
    var status = "Connecting"
    var activeMode = ""
    var playing = false
    var videoSize: CGSize = .zero
    var hasAudio = false
    var preferred: Mode = .auto
    var stream: String = ""
    /// Bumped to force a reload.
    var reloadToken = 0
    /// While true no stream runs (screen hidden or app in the background).
    var suspended = false
    /// Two-way talk: WebRTC with the microphone sent to the camera's speaker.
    var talking = false
    /// Set when the microphone could not be used.
    var micError: String?
    /// The native player could not play this stream; the web player takes over without MSE.
    var nativeFailed = false
    /// A stream of the same camera that already plays (its overview tile): shown at once while
    /// `stream` connects, then replaced by it without the picture stopping.
    var bridgeStream: String?
    /// Picture in picture can start: the native player is showing video and the device supports it.
    var pipPossible = false
    /// The video is in the picture-in-picture window; the stream keeps running in the background.
    var pipActive = false
    /// The player offers picture in picture (the device supports it): the button stays, rather
    /// than coming and going as the system's "possible" flag changes while the stream connects.
    var pipSupported = false
    /// The player whose picture in picture the button drives: when the player view is rebuilt,
    /// the old one goes away after the new one came, and must not switch the button off.
    @ObservationIgnored var pipOwner: ObjectIdentifier?
    /// Why picture in picture did not start, to show the user.
    var pipError: String?
    /// Starts or stops picture in picture; set by the native player.
    @ObservationIgnored var togglePiP: (() -> Void)?

    fileprivate weak var webView: WKWebView?

    /// `status` as shown to the user; the web page reports it in English.
    var statusText: String {
        let unavailable = "Stream unavailable"
        if status.hasPrefix(unavailable) { return L("Stream unavailable") + status.dropFirst(unavailable.count) }
        switch status {
        case "Connecting": return L("Connecting…")
        case "Reconnecting": return L("Reconnecting…")
        case "Live": return L("Live")
        default: return status
        }
    }

    func setMuted(_ value: Bool) {
        muted = value
        webView?.evaluateJavaScript("setMuted(\(value ? "true" : "false"))")
    }
}

/// The camera's latest frame, refreshed every second while the live stream connects, so
/// there is a moving picture right away. The overview tile's smaller frame shows at once from
/// the cache until the sharper one arrives.
struct LivePoster: View {
    let client: FrigateClient
    let camera: String

    var body: some View {
        RemoteImage(url: client.latestImageURL(camera: camera, height: 720), session: client.session,
                    refresh: 1, contentMode: .fit, placeholder: client.latestImageURL(camera: camera, height: 270))
            .background(Color.black)
    }
}

/// Live video of a camera: the native player (MSE stream decoded in the app) first, and the
/// web player (WebRTC, then MJPEG snapshots) when that fails or a mode needs it.
struct LivePlayerView: View {
    let client: FrigateClient
    let camera: String
    @Bindable var state: LivePlayerState
    var fill: Bool = false
    /// Offer picture in picture (a camera's own screen, not the overview tiles).
    var pip = false

    private var stream: String { state.stream.isEmpty ? camera : state.stream }
    /// Native for MSE; talking needs WebRTC, and WebRTC or MJPEG picked by hand use the web.
    private var useNative: Bool {
        !state.suspended && !state.talking && !state.nativeFailed && (state.preferred == .auto || state.preferred == .mse)
    }

    var body: some View {
        if ScreenshotMode.liveTime != nil {
            // Screenshots: the poster (a recording frame) stays; no live video.
            Color.clear
        } else {
            livePlayer
        }
    }

    @ViewBuilder
    private var livePlayer: some View {
        Group {
            if useNative {
                NativeLivePlayer(client: client, stream: stream, state: state, fill: fill, pip: pip) { reason in
                    state.nativeFailed = true
                }
                .id("\(stream)|\(state.reloadToken)")
            } else {
                WebLivePlayerView(client: client, camera: camera, state: state, fill: fill)
            }
        }
        // A new stream or a retry gets another native attempt.
        .onChange(of: state.stream) { _, _ in state.nativeFailed = false }
        .onChange(of: state.reloadToken) { _, _ in state.nativeFailed = false }
        // Back on screen (or in the foreground): try native again.
        .onChange(of: state.suspended) { _, suspended in if !suspended { state.nativeFailed = false } }
    }
}

/// Plays a go2rtc stream through Frigate's proxy in a web view: MSE over websocket first,
/// then WebRTC, then MJPEG from the Frigate API as the last fallback.
struct WebLivePlayerView: UIViewRepresentable {
    let client: FrigateClient
    let camera: String
    @Bindable var state: LivePlayerState
    /// Fill the frame (crop) and use MSE only, for small grid tiles.
    var fill: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(state: state, client: client, camera: camera) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(context.coordinator, name: "player")
        let web = WKWebView(frame: .zero, configuration: config)
        web.uiDelegate = context.coordinator
        context.coordinator.webView = web
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        // Touches go to SwiftUI (pinch to zoom); the page needs none.
        web.isUserInteractionEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        #if DEBUG
        if #available(iOS 16.4, *) { web.isInspectable = true }
        #endif
        state.webView = web
        load(web, coordinator: context.coordinator)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if context.coordinator.loadedKey != loadKey { load(web, coordinator: context.coordinator) }
    }

    private var loadKey: String {
        "\(state.stream)|\(state.preferred.rawValue)|\(state.reloadToken)|\(state.suspended)|\(state.talking)|\(state.nativeFailed)"
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.closeSignal()
        Coordinator.endTalkAudio()
        web.evaluateJavaScript("stopAll()")
        web.configuration.userContentController.removeScriptMessageHandler(forName: "player")
        web.loadHTMLString("", baseURL: nil)
    }

    private func load(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.loadedKey = loadKey
        coordinator.loadStarted = Date()
        coordinator.closeSignal()
        if state.talking { Coordinator.startTalkAudio() } else { Coordinator.endTalkAudio() }
        if state.suspended {
            // Close the stream; iOS does not resume a paused web video reliably.
            web.evaluateJavaScript("stopAll()")
            web.loadHTMLString("", baseURL: nil)
            state.playing = false
            return
        }
        let stream = state.stream.isEmpty ? camera : state.stream
        var modes: [String]
        switch state.preferred {
        case .auto: modes = ["mse", "webrtc", "mjpeg"]
        case .mse: modes = ["mse", "mjpeg"]
        case .webrtc: modes = ["webrtc", "mjpeg"]
        case .mjpeg: modes = ["mjpeg"]
        }
        if fill { modes = ["mse"] }
        // MSE already failed in the native player.
        if state.nativeFailed && modes.count > 1 { modes.removeAll { $0 == "mse" } }
        // Talking needs WebRTC (the only transport that sends audio back).
        if state.talking { modes = ["webrtc"] }
        let params: [String: Any] = [
            "mse": client.liveSocketURL(stream: stream, mode: "mse").absoluteString,
            "webrtc": client.liveSocketURL(stream: stream, mode: "webrtc").absoluteString,
            "mjpeg": client.mjpegURL(camera: camera, height: 720).absoluteString,
            "snapshot": client.latestImageURL(camera: camera, height: 720).absoluteString,
            "modes": modes,
            "muted": state.muted,
            "fit": fill ? "cover" : "contain",
            "talk": state.talking,
        ]
        let json = String(data: (try? JSONSerialization.data(withJSONObject: params)) ?? Data(), encoding: .utf8) ?? "{}"
        state.status = "Connecting"
        state.playing = false
        state.activeMode = ""
        // Share login cookies with the web view before loading.
        let store = web.configuration.websiteDataStore.httpCookieStore
        let cookies = HTTPCookieStorage.shared.cookies(for: client.baseURL) ?? []
        let html = Self.html.replacingOccurrences(of: "__PARAMS__", with: json)
        // The microphone needs a secure page, and a plain http:// server is not one; localhost is.
        // While talking the page runs from localhost and the WebRTC handshake goes through the
        // app (see Coordinator), so the page itself never talks to the server.
        let base = state.talking ? URL(string: "http://localhost/")! : client.baseURL
        Task { @MainActor in
            for c in cookies { await store.setCookie(c) }
            web.loadHTMLString(html, baseURL: base)
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate {
        let state: LivePlayerState
        let client: FrigateClient
        let camera: String
        var loadedKey = ""
        var loadStarted = Date()
        weak var webView: WKWebView?
        private var signal: URLSessionWebSocketTask?

        init(state: LivePlayerState, client: FrigateClient, camera: String) {
            self.state = state
            self.client = client
            self.camera = camera
        }

        // MARK: Talk

        /// Speaker output and echo cancellation while talking; the earpiece would be far too quiet.
        static func startTalkAudio() {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try? session.setActive(true)
        }

        static func endTalkAudio() {
            let session = AVAudioSession.sharedInstance()
            guard session.category == .playAndRecord else { return }
            try? session.setCategory(.playback, mode: .default)
        }

        /// The page asked for the microphone; the user already chose to talk.
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(type == .microphone ? .grant : .deny)
        }

        /// Relays the page's WebRTC handshake to go2rtc over a websocket opened by the app.
        @MainActor func sendSignal(_ message: [String: Any]) {
            if signal == nil {
                let stream = state.stream.isEmpty ? camera : state.stream
                let task = client.session.webSocketTask(with: client.liveSocketURL(stream: stream, mode: "webrtc"))
                signal = task
                task.resume()
                Task { @MainActor [weak self] in
                    while true {
                        guard let msg = try? await task.receive() else { break }
                        guard case .string(let text) = msg else { continue }
                        _ = try? await self?.webView?.evaluateJavaScript("onSignal(\(text))")
                    }
                    if self?.signal === task {
                        _ = try? await self?.webView?.evaluateJavaScript("onSignal({type:'error', value:'connection closed'})")
                    }
                }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: message),
                  let text = String(data: data, encoding: .utf8) else { return }
            signal?.send(.string(text)) { _ in }
        }

        func closeSignal() {
            signal?.cancel(with: .goingAway, reason: nil)
            signal = nil
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let s = body["signal"] as? [String: Any] {
                Task { @MainActor in sendSignal(s) }
                return
            }
            if let err = body["micError"] as? String {
                Task { @MainActor in state.micError = err }
            }
            Task { @MainActor in
                if let s = body["status"] as? String {
                    #if DEBUG
                    if s == "Live" && state.status != "Live" {
                        NSLog("[live] %@ %@ %@ playing after %.2fs, %d KB", camera, state.stream,
                              body["mode"] as? String ?? "", Date().timeIntervalSince(loadStarted),
                              (body["bytes"] as? Int ?? 0) / 1024)
                    }
                    #endif
                    state.status = s
                }
                if let m = body["mode"] as? String { state.activeMode = m }
                if let p = body["playing"] as? Bool { state.playing = p }
                if let a = body["audio"] as? Bool { state.hasAudio = a }
                if let w = body["width"] as? Double, let h = body["height"] as? Double, w > 0 {
                    state.videoSize = CGSize(width: w, height: h)
                }
            }
        }
    }

    // swiftlint:disable line_length
    static let html = #"""
<!doctype html>
<html><head>
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<style>
html,body{margin:0;padding:0;background:#000;width:100%;height:100%;overflow:hidden}
video,img{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;background:#000}
</style></head>
<body>
<video id="v" playsinline autoplay muted></video>
<script>
const P = __PARAMS__;
document.getElementById('v').style.objectFit = P.fit || 'contain';
const video = document.getElementById('v');
video.muted = P.muted;
let ws = null, pc = null, img = null, timer = null, stopped = false;
let snapTimer = null, retryTimer = null, snapFails = 0, rx = 0;
function post(o){ try { window.webkit.messageHandlers.player.postMessage(o); } catch(e){} }
function setMuted(m){ video.muted = m; if (!m) video.play().catch(()=>{}); }
function stopAll(){
  stopped = true;
  if (ws) { try { ws.close(); } catch(e){} ws = null; }
  if (pc) { try { pc.close(); } catch(e){} pc = null; }
  if (timer) clearTimeout(timer);
  video.removeAttribute('src'); video.srcObject = null;
  stopSnapshots();
}
// Stops the still-image fallback. Called once real video plays, so the last frame stays
// visible while a retry connects.
function stopSnapshots(){
  if (snapTimer) { clearTimeout(snapTimer); snapTimer = null; }
  if (retryTimer) { clearTimeout(retryTimer); retryTimer = null; }
  if (img) { img.remove(); img = null; }
}
function cleanupTransport(){
  // Detach every handler first: closing a socket that is still connecting fires 'error',
  // which would otherwise skip the next transport.
  if (ws) { ws.onclose = ws.onerror = ws.onmessage = ws.onopen = null; try { ws.close(); } catch(e){} ws = null; }
  if (pc) { try { pc.close(); } catch(e){} pc = null; }
  if (timer) { clearTimeout(timer); timer = null; }
  video.removeAttribute('src'); video.srcObject = null;
}
let idx = -1;
function next(reason){
  if (stopped) return;
  cleanupTransport();
  idx++;
  const mode = P.modes[idx];
  if (!mode) { post({status: 'Stream unavailable' + (reason ? ': ' + reason : ''), playing:false}); return; }
  post({status: 'Connecting', mode: mode});
  // Give each transport a few seconds to produce frames.
  timer = setTimeout(() => { if (!playingNow) next(mode + ' timed out'); }, mode === 'mse' ? 10000 : 8000);
  if (mode === 'mse') startMSE(); else if (mode === 'webrtc') startWebRTC(); else startMJPEG();
}
let playingNow = false;
function markPlaying(mode){
  if (timer) { clearTimeout(timer); timer = null; }
  playingNow = true;
  if (mode !== 'mjpeg') stopSnapshots();
  post({status:'Live', mode: mode, playing:true, bytes: rx, width: video.videoWidth || (img ? img.naturalWidth : 0), height: video.videoHeight || (img ? img.naturalHeight : 0)});
}
video.addEventListener('playing', () => markPlaying(P.modes[idx]));
// Watchdog: if the picture stops advancing while we think it plays, reconnect.
let lastTime = -1, stuckFor = 0;
setInterval(() => {
  if (stopped || !playingNow || img) return;
  if (video.paused && !video.ended) { video.play().catch(()=>{}); }
  if (video.currentTime === lastTime) { stuckFor += 2; } else { stuckFor = 0; lastTime = video.currentTime; }
  if (stuckFor >= 6) {
    stuckFor = 0; lastTime = -1; playingNow = false;
    post({status: 'Reconnecting', playing: false});
    idx--; next('stalled');
  }
}, 2000);
document.addEventListener('visibilitychange', () => { if (!document.hidden && playingNow) video.play().catch(()=>{}); });
video.addEventListener('resize', () => post({width: video.videoWidth, height: video.videoHeight}));

const CODECS = ['avc1.640029','avc1.64002A','avc1.640033','hvc1.1.6.L153.B0','mp4a.40.2','mp4a.40.5','flac','opus'];
function startMSE(){
  const MS = window.ManagedMediaSource || window.MediaSource;
  if (!MS) { next('MSE not supported'); return; }
  const ms = new MS();
  if (window.ManagedMediaSource && MS === window.ManagedMediaSource) {
    video.disableRemotePlayback = true;
    video.srcObject = ms;
  } else {
    video.src = URL.createObjectURL(ms);
  }
  ms.addEventListener('sourceopen', () => {
    ws = new WebSocket(P.mse);
    ws.binaryType = 'arraybuffer';
    let sb = null, queue = [];
    ws.onopen = () => {
      const codecs = CODECS.filter(c => MS.isTypeSupported('video/mp4; codecs="' + c + '"')).join();
      ws.send(JSON.stringify({type:'mse', value: codecs}));
    };
    ws.onmessage = (ev) => {
      if (typeof ev.data === 'string') {
        const msg = JSON.parse(ev.data);
        if (msg.type === 'mse') {
          post({audio: /mp4a|opus|flac/.test(msg.value)});
          try { sb = ms.addSourceBuffer(msg.value); } catch(e) { next('codec ' + msg.value); return; }
          sb.mode = 'segments';
          sb.addEventListener('updateend', () => {
            if (queue.length && !sb.updating) {
              try { sb.appendBuffer(queue.shift()); } catch(e) {}
              return;
            }
            if (!sb.updating && sb.buffered.length) {
              const end = sb.buffered.end(sb.buffered.length - 1);
              const start0 = sb.buffered.start(0);
              if (end - start0 > 10) { try { sb.remove(start0, end - 5); } catch(e) {} }
              if (ms.setLiveSeekableRange) { try { ms.setLiveSeekableRange(Math.max(start0, end - 5), end); } catch(e) {} }
              if (video.currentTime < end - 3 || video.currentTime > end) video.currentTime = Math.max(0, end - 0.3);
              const gap = end - video.currentTime;
              video.playbackRate = gap > 0.8 ? 1.1 : 1.0;
              if (video.paused) video.play().catch(()=>{});
            }
          });
        } else if (msg.type === 'error') {
          next(msg.value);
        }
      } else if (sb) {
        rx += ev.data.byteLength;
        if (sb.updating || queue.length) queue.push(ev.data);
        else { try { sb.appendBuffer(ev.data); } catch(e) { queue.push(ev.data); } }
      }
    };
    ws.onerror = () => next('websocket error');
    ws.onclose = () => { if (!stopped && playingNow) { post({status:'Reconnecting', playing:false}); playingNow = false; idx--; next(); } };
  }, {once: true});
  video.play().catch(()=>{});
}

async function onSignal(msg){
  if (!pc) return;
  if (msg.type === 'webrtc/answer') await pc.setRemoteDescription({type: 'answer', sdp: msg.value});
  else if (msg.type === 'webrtc/candidate' && msg.value) { try { await pc.addIceCandidate({candidate: msg.value, sdpMid: '0'}); } catch(e) {} }
  else if (msg.type === 'error') next(msg.value);
}
async function startWebRTC(){
  if (!window.RTCPeerConnection) { next('WebRTC not supported'); return; }
  pc = new RTCPeerConnection({bundlePolicy: 'max-bundle', iceServers: [{urls: 'stun:stun.l.google.com:19302'}]});
  // Talking: the microphone goes out first, like Frigate's web UI does.
  if (P.talk) {
    try {
      const mic = await navigator.mediaDevices.getUserMedia({audio: {echoCancellation: true, noiseSuppression: true}});
      mic.getTracks().forEach(t => pc.addTransceiver(t, {direction: 'sendonly'}));
    } catch (e) {
      post({micError: String(e && e.name || e)});
    }
  }
  pc.addTransceiver('video', {direction: 'recvonly'});
  pc.addTransceiver('audio', {direction: 'recvonly'});
  const stream = new MediaStream();
  pc.ontrack = (e) => {
    stream.addTrack(e.track);
    if (e.track.kind === 'audio') post({audio: true});
    video.srcObject = stream;
    video.play().catch(()=>{});
  };
  const send = (o) => {
    if (P.talk) post({signal: o});
    else if (ws && ws.readyState === 1) ws.send(JSON.stringify(o));
  };
  pc.onicecandidate = (e) => send({type: 'webrtc/candidate', value: e.candidate ? e.candidate.candidate : ''});
  const offer = async () => {
    const o = await pc.createOffer();
    await pc.setLocalDescription(o);
    send({type: 'webrtc/offer', value: o.sdp});
  };
  if (P.talk) { offer(); return; }
  ws = new WebSocket(P.webrtc);
  ws.onopen = offer;
  ws.onmessage = (ev) => onSignal(JSON.parse(ev.data));
  ws.onerror = () => next('websocket error');
}

// Last resort: refresh a still image every second. A failed request keeps the previous
// frame, so a flaky connection never shows a broken image.
function startMJPEG(){
  if (timer) { clearTimeout(timer); timer = null; }
  if (img) {
    // Still showing snapshots from before a retry: keep them and try video again later.
    playingNow = true;
    post({status: 'Live', mode: 'mjpeg', playing: true});
    if (P.modes.length > 1) retryTimer = setTimeout(() => { if (!stopped) { idx = -1; playingNow = false; next(); } }, 30000);
    return;
  }
  img = document.createElement('img');
  document.body.appendChild(img);
  post({audio: false});
  const tick = async () => {
    if (stopped || !img) return;
    try {
      const r = await fetch(P.snapshot + (P.snapshot.includes('?') ? '&' : '?') + 't=' + Date.now(), {cache: 'no-store', credentials: 'include'});
      if (!r.ok) throw new Error('http ' + r.status);
      const url = URL.createObjectURL(await r.blob());
      const old = img.src;
      img.onload = () => { if (old.startsWith('blob:')) URL.revokeObjectURL(old); if (!playingNow) markPlaying('mjpeg'); };
      img.src = url;
      snapFails = 0;
    } catch (e) {
      snapFails++;
      if (!playingNow && snapFails >= 5) { next('snapshots failed'); return; }
    }
    snapTimer = setTimeout(tick, 1000);
  };
  tick();
  // Keep trying to get real video back.
  if (P.modes.length > 1) retryTimer = setTimeout(() => { if (!stopped) { idx = -1; playingNow = false; next(); } }, 30000);
}
next();
</script>
</body></html>
"""#
}
