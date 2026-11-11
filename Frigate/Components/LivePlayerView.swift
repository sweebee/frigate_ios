import SwiftUI
import WebKit

/// State shared between the live player and its controls.
@Observable @MainActor
final class LivePlayerState {
    enum Mode: String, CaseIterable { case auto, mse, webrtc, mjpeg }

    var muted = true
    var status = "Connecting"
    var activeMode = ""
    var playing = false
    var videoSize: CGSize = .zero
    var hasAudio = false
    var preferred: Mode = .auto
    var stream: String = ""
    /// Bumped to force a reload.
    var reloadToken = 0

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

/// Plays a go2rtc stream through Frigate's proxy: MSE over websocket first, then WebRTC,
/// then MJPEG from the Frigate API as the last fallback.
struct LivePlayerView: UIViewRepresentable {
    let client: FrigateClient
    let camera: String
    @Bindable var state: LivePlayerState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(context.coordinator, name: "player")
        let web = WKWebView(frame: .zero, configuration: config)
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
        let key = "\(state.stream)|\(state.preferred.rawValue)|\(state.reloadToken)"
        if context.coordinator.loadedKey != key { load(web, coordinator: context.coordinator) }
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.evaluateJavaScript("stopAll()")
        web.configuration.userContentController.removeScriptMessageHandler(forName: "player")
        web.loadHTMLString("", baseURL: nil)
    }

    private func load(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.loadedKey = "\(state.stream)|\(state.preferred.rawValue)|\(state.reloadToken)"
        let stream = state.stream.isEmpty ? camera : state.stream
        let modes: [String]
        switch state.preferred {
        case .auto: modes = ["mse", "webrtc", "mjpeg"]
        case .mse: modes = ["mse", "mjpeg"]
        case .webrtc: modes = ["webrtc", "mjpeg"]
        case .mjpeg: modes = ["mjpeg"]
        }
        let params: [String: Any] = [
            "mse": client.liveSocketURL(stream: stream, mode: "mse").absoluteString,
            "webrtc": client.liveSocketURL(stream: stream, mode: "webrtc").absoluteString,
            "mjpeg": client.mjpegURL(camera: camera, height: 720).absoluteString,
            "modes": modes,
            "muted": state.muted,
        ]
        let json = String(data: (try? JSONSerialization.data(withJSONObject: params)) ?? Data(), encoding: .utf8) ?? "{}"
        state.status = "Connecting"
        state.playing = false
        state.activeMode = ""
        // Share login cookies with the web view before loading.
        let store = web.configuration.websiteDataStore.httpCookieStore
        let cookies = HTTPCookieStorage.shared.cookies(for: client.baseURL) ?? []
        let html = Self.html.replacingOccurrences(of: "__PARAMS__", with: json)
        let base = client.baseURL
        Task { @MainActor in
            for c in cookies { await store.setCookie(c) }
            web.loadHTMLString(html, baseURL: base)
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let state: LivePlayerState
        var loadedKey = ""
        init(state: LivePlayerState) { self.state = state }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            Task { @MainActor in
                if let s = body["status"] as? String { state.status = s }
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
const video = document.getElementById('v');
video.muted = P.muted;
let ws = null, pc = null, img = null, timer = null, stopped = false;
function post(o){ try { window.webkit.messageHandlers.player.postMessage(o); } catch(e){} }
function setMuted(m){ video.muted = m; if (!m) video.play().catch(()=>{}); }
function stopAll(){
  stopped = true;
  if (ws) { try { ws.close(); } catch(e){} ws = null; }
  if (pc) { try { pc.close(); } catch(e){} pc = null; }
  if (timer) clearTimeout(timer);
  video.removeAttribute('src'); video.srcObject = null;
  if (img) { img.src = ''; img.remove(); img = null; }
}
function cleanupTransport(){
  if (ws) { ws.onclose = null; try { ws.close(); } catch(e){} ws = null; }
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
  timer = setTimeout(() => { if (!playingNow) next(mode + ' timed out'); }, mode === 'mse' ? 15000 : (mode === 'webrtc' ? 12000 : 8000));
  if (mode === 'mse') startMSE(); else if (mode === 'webrtc') startWebRTC(); else startMJPEG();
}
let playingNow = false;
function markPlaying(mode){
  if (timer) { clearTimeout(timer); timer = null; }
  playingNow = true;
  post({status:'Live', mode: mode, playing:true, width: video.videoWidth || (img ? img.naturalWidth : 0), height: video.videoHeight || (img ? img.naturalHeight : 0)});
}
video.addEventListener('playing', () => markPlaying(P.modes[idx]));
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
        if (sb.updating || queue.length) queue.push(ev.data);
        else { try { sb.appendBuffer(ev.data); } catch(e) { queue.push(ev.data); } }
      }
    };
    ws.onerror = () => next('websocket error');
    ws.onclose = () => { if (!stopped && playingNow) { post({status:'Reconnecting', playing:false}); playingNow = false; idx--; next(); } };
  }, {once: true});
  video.play().catch(()=>{});
}

function startWebRTC(){
  if (!window.RTCPeerConnection) { next('WebRTC not supported'); return; }
  pc = new RTCPeerConnection({iceServers: [{urls: 'stun:stun.l.google.com:19302'}]});
  pc.addTransceiver('video', {direction: 'recvonly'});
  pc.addTransceiver('audio', {direction: 'recvonly'});
  const stream = new MediaStream();
  pc.ontrack = (e) => {
    stream.addTrack(e.track);
    if (e.track.kind === 'audio') post({audio: true});
    video.srcObject = stream;
    video.play().catch(()=>{});
  };
  ws = new WebSocket(P.webrtc);
  pc.onicecandidate = (e) => {
    if (ws && ws.readyState === 1) ws.send(JSON.stringify({type: 'webrtc/candidate', value: e.candidate ? e.candidate.candidate : ''}));
  };
  ws.onopen = async () => {
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    ws.send(JSON.stringify({type: 'webrtc/offer', value: offer.sdp}));
  };
  ws.onmessage = async (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.type === 'webrtc/answer') await pc.setRemoteDescription({type: 'answer', sdp: msg.value});
    else if (msg.type === 'webrtc/candidate' && msg.value) { try { await pc.addIceCandidate({candidate: msg.value, sdpMid: '0'}); } catch(e) {} }
    else if (msg.type === 'error') next(msg.value);
  };
  ws.onerror = () => next('websocket error');
}

function startMJPEG(){
  img = document.createElement('img');
  img.onload = () => markPlaying('mjpeg');
  img.onerror = () => next('mjpeg failed');
  img.src = P.mjpeg;
  document.body.appendChild(img);
  post({audio: false});
}
next();
</script>
</body></html>
"""#
}
