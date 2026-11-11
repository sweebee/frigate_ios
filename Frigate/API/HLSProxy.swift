import Foundation
import Network

/// AVPlayer only plays HEVC over HLS when the sample entry is tagged `hvc1`, while Frigate
/// passes through camera streams tagged `hev1`. This tiny localhost proxy forwards VOD
/// requests to the Frigate server and rewrites the tag in init segments.
///
/// Local URL layout: http://127.0.0.1:<port>/<hex encoded upstream origin>/vod/...
/// Segment URLs in the playlist are relative, so they resolve through the proxy too.
final class HLSProxy: @unchecked Sendable {
    static let shared = HLSProxy()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "hls-proxy")
    private var port: UInt16 = 0
    private let ready = DispatchSemaphore(value: 0)
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpCookieStorage = .shared
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    private init() {}

    /// Returns a URL that plays `upstream` through the proxy, or `upstream` itself if the proxy failed.
    func url(for upstream: URL) -> URL {
        guard startIfNeeded(), let scheme = upstream.scheme, let host = upstream.host else { return upstream }
        let origin = "\(scheme)://\(host)\(upstream.port.map { ":\($0)" } ?? "")"
        let hex = origin.utf8.map { String(format: "%02x", $0) }.joined()
        var comps = URLComponents(url: upstream, resolvingAgainstBaseURL: false)!
        comps.scheme = "http"
        comps.host = "127.0.0.1"
        comps.port = Int(port)
        comps.path = "/\(hex)\(comps.path)"
        return comps.url ?? upstream
    }

    private func startIfNeeded() -> Bool {
        queue.sync {
            if port != 0 { return true }
            do {
                let params = NWParameters.tcp
                params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
                let l = try NWListener(using: params)
                l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
                let sem = DispatchSemaphore(value: 0)
                l.stateUpdateHandler = { state in
                    switch state {
                    case .ready, .failed, .cancelled: sem.signal()
                    default: break
                    }
                }
                l.start(queue: DispatchQueue(label: "hls-proxy-listener"))
                _ = sem.wait(timeout: .now() + 2)
                guard let p = l.port?.rawValue, p != 0 else { l.cancel(); return false }
                listener = l
                port = p
                return true
            } catch {
                return false
            }
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn, buffer: Data())
    }

    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
                self.respond(conn, head: head)
            } else if done || error != nil || buf.count > 64 * 1024 {
                conn.cancel()
            } else {
                self.receiveRequest(conn, buffer: buf)
            }
        }
    }

    private func respond(_ conn: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, let upstream = upstreamURL(for: String(parts[1])) else {
            send(conn, status: "400 Bad Request", headers: [:], body: Data())
            return
        }
        var req = URLRequest(url: upstream)
        req.httpMethod = parts[0] == "HEAD" ? "HEAD" : "GET"
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0].caseInsensitiveCompare("Range") == .orderedSame { req.setValue(kv[1], forHTTPHeaderField: "Range") }
        }
        session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            guard let http = response as? HTTPURLResponse, var body = data, error == nil else {
                self.send(conn, status: "502 Bad Gateway", headers: [:], body: Data())
                return
            }
            let path = upstream.path
            if path.hasSuffix(".mp4") && path.contains("/init") {
                body = MP4Patch.hev1ToHvc1(body)
            } else if path.hasSuffix(".m3u8"), let text = String(data: body, encoding: .utf8) {
                // Only the small init segment needs patching. Point media segments straight at the
                // server so the player streams them without the proxy buffering each one.
                let base = upstream.deletingLastPathComponent()
                let lines = text.components(separatedBy: "\n").map { line -> String in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, !t.hasPrefix("#"), !t.contains("://"),
                          let abs = URL(string: t, relativeTo: base)?.absoluteURL else { return line }
                    return abs.absoluteString
                }
                body = Data(lines.joined(separator: "\n").utf8)
            }
            var headers: [String: String] = [:]
            for key in ["Content-Type", "Content-Range", "Accept-Ranges", "Cache-Control"] {
                if let v = http.value(forHTTPHeaderField: key) { headers[key] = v }
            }
            let reason = HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized
            self.send(conn, status: "\(http.statusCode) \(reason)", headers: headers, body: req.httpMethod == "HEAD" ? Data() : body,
                      contentLength: req.httpMethod == "HEAD" ? (http.expectedContentLength > 0 ? Int(http.expectedContentLength) : 0) : body.count)
        }.resume()
    }

    private func upstreamURL(for path: String) -> URL? {
        // "/<hex origin>/rest?query"
        let trimmed = path.dropFirst()
        guard let slash = trimmed.firstIndex(of: "/") else { return nil }
        let hex = trimmed[..<slash]
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        let origin = String(decoding: bytes, as: UTF8.self)
        return URL(string: origin + String(trimmed[slash...]))
    }

    private func send(_ conn: NWConnection, status: String, headers: [String: String], body: Data, contentLength: Int? = nil) {
        var head = "HTTP/1.1 \(status)\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(contentLength ?? body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}

enum MP4Patch {
    /// Renames `hev1` sample entries to `hvc1` inside the `moov` box. Frigate stores the
    /// parameter sets in `hvcC`, so the rename is enough for Apple players.
    static func hev1ToHvc1(_ data: Data) -> Data {
        guard let moov = topLevelBox("moov", in: data) else { return data }
        var out = data
        let needle = Data("hev1".utf8)
        var search = moov
        while let r = out.range(of: needle, in: search) {
            out.replaceSubrange(r, with: Data("hvc1".utf8))
            search = r.upperBound..<moov.upperBound
        }
        return out
    }

    private static func topLevelBox(_ type: String, in data: Data) -> Range<Data.Index>? {
        var offset = data.startIndex
        while offset + 8 <= data.endIndex {
            var size = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            let name = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            if size == 1, offset + 16 <= data.endIndex {
                size = (8..<16).reduce(0) { $0 << 8 | Int(data[offset + $1]) }
            } else if size == 0 {
                size = data.endIndex - offset
            }
            guard size >= 8 else { return nil }
            if name == type { return offset..<min(offset + size, data.endIndex) }
            offset += size
        }
        return nil
    }

    /// Patches a downloaded MP4 file in place.
    static func patchFile(at url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        let patched = hev1ToHvc1(data)
        if patched != data { try? patched.write(to: url) }
    }
}
