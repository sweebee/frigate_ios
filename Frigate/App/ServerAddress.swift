import Foundation

/// Turns whatever someone types as a server address into the URLs worth trying, best guess
/// first. "192.168.1.20", "frigate.local:5000", "HTTP//nvr.example.com/review" and a link
/// pasted from the browser all work: a missing scheme or port is filled in by trying the usual
/// ones, and Frigate's own pages after the host are dropped.
enum ServerAddress {
    /// Frigate's ports: 8971 with login, 5000 without.
    static let frigatePorts = [8971, 5000]

    static func candidates(_ raw: String) -> [URL] {
        guard let parsed = parse(raw) else { return [] }
        let local = isLocal(parsed.host)
        var schemes: [String]
        if let s = parsed.scheme { schemes = [s] }
        else if parsed.port == 443 { schemes = ["https"] }
        else if parsed.port == 80 { schemes = ["http"] }
        // At home Frigate usually serves plain http; a name on the internet usually sits behind https.
        else { schemes = local ? ["http", "https"] : ["https", "http"] }

        var list: [(scheme: String, port: Int?)] = []
        if let port = parsed.port {
            list = schemes.map { ($0, port) }
        } else if local && parsed.scheme == nil {
            // Frigate's own ports first, then the scheme's default (a proxy in front of it).
            // A typed scheme without a port more likely means that default, so it goes first then.
            for s in schemes { for p in frigatePorts where !(s == "https" && p == 5000) { list.append((s, p)) } }
            for s in schemes { list.append((s, nil)) }
        } else {
            for s in schemes { list.append((s, nil)) }
            for s in schemes { for p in frigatePorts where !(s == "https" && p == 5000) { list.append((s, p)) } }
        }

        var seen = Set<String>()
        return list.compactMap { item in
            var c = URLComponents()
            c.scheme = item.scheme
            c.host = parsed.host
            c.port = item.port
            c.path = parsed.path
            guard let url = c.url, seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }

    /// The first of `candidates` that answers like Frigate: with its version, or asking for a
    /// login (port 8971). All are tried at once. A better guess still wins over a faster one, but
    /// once one has answered the others get only `grace` more. Nil when none answered within
    /// `timeout` (a single candidate is returned untried: nothing to choose).
    static func firstReachable(_ candidates: [URL], timeout: TimeInterval = 4, grace: TimeInterval = 1) async -> URL? {
        guard candidates.count > 1 else { return candidates.first }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        return await withTaskGroup(of: (Int, Bool).self) { group in
            for (i, url) in candidates.enumerated() {
                group.addTask { (i, await answers(url, session: session)) }
            }
            var results = [Bool?](repeating: nil, count: candidates.count)
            var graceStarted = false
            for await (i, ok) in group {
                if i < 0 {
                    // Grace is over: the best that answered.
                    group.cancelAll()
                    return results.firstIndex(of: true).map { candidates[$0] }
                }
                results[i] = ok
                for (j, r) in results.enumerated() {
                    guard let r else { break }          // a better guess is still out
                    if r { group.cancelAll(); return candidates[j] }
                }
                if ok, !graceStarted {
                    graceStarted = true
                    group.addTask { try? await Task.sleep(for: .seconds(grace)); return (-1, false) }
                }
            }
            return nil
        }
    }

    private static func answers(_ base: URL, session: URLSession) async -> Bool {
        guard let (data, response) = try? await session.data(from: base.appendingPathComponent("api/version")),
              let http = response as? HTTPURLResponse else { return false }
        if http.statusCode == 401 { return true }
        guard http.statusCode == 200, let text = String(data: data, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).first?.isNumber == true
    }

    /// True when the address names the full URL, so there is nothing to guess.
    static func isComplete(_ raw: String) -> Bool {
        guard let p = parse(raw) else { return false }
        return p.scheme != nil && p.port != nil
    }

    // MARK: - Parsing

    struct Parsed: Equatable {
        var scheme: String?
        var host: String
        var port: Int?
        var path: String
    }

    /// The pages of Frigate's web app; a pasted link to one of them means the server root.
    private static let appPages: Set<String> = [
        "api", "review", "explore", "export", "exports", "settings", "system", "config", "logs",
        "faces", "classification", "chat", "live", "events", "recording", "login", "#",
    ]

    static func parse(_ raw: String) -> Parsed? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s.removeAll { $0 == " " }
        guard !s.isEmpty else { return nil }

        // The scheme, also when mistyped: "HTTP://", "http//", "https:/", "htps://".
        var scheme: String?
        if let r = s.range(of: #"^[hH]*[tT]+[pP]+[sS]*:?/{1,3}"#, options: .regularExpression) {
            scheme = s[r].lowercased().contains("s") ? "https" : "http"
            s = String(s[r.upperBound...])
        } else if let r = s.range(of: #"^https?:"#, options: [.regularExpression, .caseInsensitive]) {
            scheme = s[r].lowercased().hasPrefix("https") ? "https" : "http"
            s = String(s[r.upperBound...])
        }

        // Login details in the address belong in their own fields.
        if let at = s.firstIndex(of: "@"), !s[..<at].contains("/") { s = String(s[s.index(after: at)...]) }

        // Host[:port] and what comes after it.
        let hostEnd = s.firstIndex(where: { $0 == "/" || $0 == "#" || $0 == "?" }) ?? s.endIndex
        var hostPort = String(s[..<hostEnd])
        var rest = String(s[hostEnd...])

        // "192,168,1,20" from a keyboard with a comma.
        if hostPort.allSatisfy({ $0.isNumber || $0 == "," || $0 == ":" || $0 == "." }) {
            hostPort = hostPort.replacingOccurrences(of: ",", with: ".")
        }

        var host = hostPort
        var port: Int?
        if hostPort.hasPrefix("[") {
            // IPv6: [fe80::1]:8971
            guard let close = hostPort.firstIndex(of: "]") else { return nil }
            host = String(hostPort[...close])
            let after = hostPort[hostPort.index(after: close)...]
            if after.hasPrefix(":") { port = Int(after.dropFirst()) }
        } else if let colon = hostPort.lastIndex(of: ":") {
            host = String(hostPort[..<colon])
            let p = hostPort[hostPort.index(after: colon)...]
            if p.isEmpty { port = nil } else if let n = Int(p), (1...65535).contains(n) { port = n } else { return nil }
        }
        host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, host.range(of: #"^(\[[0-9a-f:.]+\]|[a-z0-9.-]+)$"#, options: .regularExpression) != nil else { return nil }

        // Keep a sub path (Frigate behind a proxy under /frigate), but not a page of Frigate itself.
        if let cut = rest.firstIndex(where: { $0 == "#" || $0 == "?" }) { rest = String(rest[..<cut]) }
        var parts = rest.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(where: { appPages.contains($0.lowercased()) }) { parts = Array(parts[..<i]) }
        let path = parts.isEmpty ? "" : "/" + parts.joined(separator: "/")

        return Parsed(scheme: scheme, host: host, port: port, path: path)
    }

    /// An address on the home network or a private VPN, where Frigate's own ports are likely.
    static func isLocal(_ host: String) -> Bool {
        if host.hasPrefix("[") { return true }
        if host.split(separator: ".").count == 4, host.allSatisfy({ $0.isNumber || $0 == "." }) { return true }
        if !host.contains(".") { return true }
        return [".local", ".lan", ".home", ".internal", ".home.arpa", ".localdomain", ".ts.net"]
            .contains { host.hasSuffix($0) }
    }
}
