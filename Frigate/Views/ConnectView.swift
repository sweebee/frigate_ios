import SwiftUI

struct ConnectView: View {
    var isOnboarding = false
    var existing: ServerConfig? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var useRemote = false
    @State private var remoteURL = ""
    @State private var testing = false
    @State private var error: String?
    @State private var scanner = NetworkScanner()
    @State private var confirmDelete = false
    @FocusState private var focus: Field?

    enum Field { case name, url, user, password, remote }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(.system(size: 30, weight: .bold)).kerning(-0.4)
                    Text(intro).font(.system(size: 15)).foregroundStyle(Theme.textSecondary).lineSpacing(3)
                }
                .padding(.top, isOnboarding ? 24 : 0)

                if existing == nil { discovered }

                VStack(alignment: .leading, spacing: 14) {
                    field("Name", text: $name, placeholder: L("Home NVR"), field: .name)
                    field("Server URL", text: $url, placeholder: "http://192.168.1.20:8971", field: .url, keyboard: .URL)
                    field("Username", text: $username, placeholder: L("Optional"), field: .user)
                    field("Password", text: $password, placeholder: L("Optional"), field: .password, secure: true)
                    ToggleRow(title: L("Remote address"), subtitle: L("Fallback when not on home Wi-Fi"), isOn: useRemote) { on in
                        withAnimation { useRemote = on }
                    }
                    if useRemote {
                        field("Remote URL", text: $remoteURL, placeholder: "https://nvr.example.com", field: .remote, keyboard: .URL)
                    }
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.destructive)
                }

                VStack(spacing: 12) {
                    Button { Task { await testAndSave() } } label: {
                        HStack(spacing: 8) {
                            if testing { ProgressView().tint(Theme.onColor) }
                            Text(testing ? L("Testing…") : L("Test and save"))
                        }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.onColor)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(Theme.accent.opacity(canSave ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(!canSave || testing)
                    Text("Credentials are stored in the iOS Keychain")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    if existing != nil {
                        Button("Remove server", role: .destructive) { confirmDelete = true }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.destructive)
                            .frame(minHeight: 44)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 34)
        }
        .scrollDismissesKeyboard(.interactively)
        .screenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isOnboarding {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .confirmationDialog("Remove \(existing?.name ?? L("server"))?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let existing { model.delete(existing) }
                dismiss()
            }
        }
        .onAppear(perform: populate)
        .task { if existing == nil { await scanner.scan() } }
    }

    private var title: String {
        if isOnboarding { return L("Connect to Frigate") }
        return existing == nil ? L("Add server") : L("Edit server")
    }

    private var intro: String {
        if isOnboarding { return L("Enter the address of your Frigate NVR. Use the authenticated port (8971) when connecting from outside its network.") }
        if existing != nil { return L("Change how the app connects to this server. Use the authenticated port (8971) when connecting from outside its network.") }
        return L("Add another Frigate server. Use the authenticated port (8971) when connecting from outside its network.")
    }

    private var canSave: Bool { ServerConfig.normalizedURL(url) != nil }

    @ViewBuilder
    private var discovered: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("FOUND ON YOUR NETWORK").font(.system(size: 12, weight: .semibold)).kerning(0.4)
                    .foregroundStyle(Theme.textSecondary)
                if scanner.scanning { ProgressView().scaleEffect(0.7) }
                Spacer()
                if !scanner.scanning {
                    Button("Scan again") { Task { await scanner.scan() } }.font(.system(size: 13, weight: .medium))
                }
            }
            let known = Set(model.servers.compactMap { ServerConfig.normalizedURL($0.url)?.host })
            let found = scanner.found.filter { !known.contains($0.url.host ?? "") }
            if found.isEmpty {
                Text(scanner.scanning ? L("Looking for Frigate servers…") : L("No new servers found. Enter the address below."))
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 6)
            }
            ForEach(found) { server in
                let selected = ServerConfig.normalizedURL(url) == server.url
                Button {
                    url = server.url.absoluteString
                    if name.isEmpty { name = "Frigate" }
                } label: {
                    HStack(spacing: 12) {
                        StatusDot(color: Theme.online, size: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.url.host ?? "").font(.system(size: 15, weight: .semibold))
                            Text("\(ServerConfig.displayAddress(server.url.absoluteString)) · \(FrigateFormat.shortVersion(server.version))")
                                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        if selected {
                            Image(systemName: "checkmark").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(14)
                    .card(border: selected ? Theme.accent : Theme.cardBorder, radius: 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func field(_ label: LocalizedStringKey, text: Binding<String>, placeholder: String, field: Field,
                       keyboard: UIKeyboardType = .default, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            Group {
                if secure {
                    HStack(spacing: 8) {
                        Group {
                            if showPassword {
                                TextField("", text: text, prompt: Text(placeholder).foregroundStyle(Color(hex: 0x7C8591)))
                            } else {
                                SecureField("", text: text, prompt: Text(placeholder).foregroundStyle(Color(hex: 0x7C8591)))
                            }
                        }
                        .focused($focus, equals: field)
                        Button {
                            showPassword.toggle()
                            // The field is swapped for another view; focus it once that exists.
                            DispatchQueue.main.async { focus = field }
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                    }
                } else {
                    TextField("", text: text, prompt: Text(placeholder).foregroundStyle(Color(hex: 0x7C8591)))
                        .keyboardType(keyboard)
                }
            }
            .textInputAutocapitalization(field == .name ? .words : .never)
            .autocorrectionDisabled()
            .focused($focus, equals: field)
            .font(.system(size: 16))
            .padding(.horizontal, 14)
            .frame(height: 48)
            .contentShape(Rectangle())
            .onTapGesture { focus = field }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(focus == field ? Theme.accent : Theme.controlBorder, lineWidth: 1))
            .accessibilityLabel(label)
        }
    }

    private func populate() {
        guard let s = existing, url.isEmpty else { return }
        name = s.name
        url = s.url
        username = s.username ?? ""
        password = s.password ?? ""
        remoteURL = s.remoteURL ?? ""
        useRemote = !(s.remoteURL ?? "").isEmpty
    }

    private func testAndSave() async {
        focus = nil
        error = nil
        guard let base = ServerConfig.normalizedURL(url) else { error = FrigateError.invalidURL.localizedDescription; return }
        testing = true
        defer { testing = false }
        var server = existing ?? ServerConfig(name: "", url: "")
        server.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? (base.host ?? "Frigate") : name.trimmingCharacters(in: .whitespaces)
        server.url = base.absoluteString
        server.username = username.isEmpty ? nil : username
        server.remoteURL = useRemote && !remoteURL.isEmpty ? ServerConfig.normalizedURL(remoteURL)?.absoluteString : nil

        var reached = false
        var lastError: Error?
        var urls = [base]
        if let r = server.remoteURL.flatMap(ServerConfig.normalizedURL) { urls.append(r) }
        for u in urls {
            do {
                _ = try await ServerConnection.authenticate(client: FrigateClient(baseURL: u), server: server, password: password)
                reached = true
                break
            } catch {
                lastError = error
            }
        }
        guard reached else {
            error = (lastError as? LocalizedError)?.errorDescription ?? lastError?.localizedDescription ?? L("Could not reach the server.")
            return
        }
        model.save(server, password: password.isEmpty ? nil : password)
        if !isOnboarding { dismiss() }
    }
}

/// Finds Frigate servers on the local /24 network by probing /api/version.
@Observable @MainActor
final class NetworkScanner {
    struct Found: Identifiable, Hashable {
        let url: URL
        let version: String
        var id: String { url.absoluteString }
    }

    var found: [Found] = []
    var scanning = false

    func scan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let ports = [8971, 5000]
        var candidates: [URL] = ["frigate.local", "frigate"].flatMap { host in ports.compactMap { URL(string: "http://\(host):\($0)") } }
        for prefix in Self.localPrefixes() {
            for i in 1...254 {
                for p in ports { candidates.append(URL(string: "http://\(prefix).\(i):\(p)")!) }
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 2
        let session = URLSession(configuration: config)

        var results: [Found] = []
        await withTaskGroup(of: Found?.self) { group in
            var iterator = candidates.makeIterator()
            func addNext() -> Bool {
                guard let url = iterator.next() else { return false }
                group.addTask { await Self.probe(url, session: session) }
                return true
            }
            for _ in 0..<64 { if !addNext() { break } }
            while let result = await group.next() {
                if let result, !results.contains(where: { $0.url.host == result.url.host && $0.url.port == result.url.port }) {
                    results.append(result)
                    found = Self.dedupe(results)
                }
                _ = addNext()
            }
        }
        found = Self.dedupe(results)
    }

    /// Prefer port 8971 when a host answers on both.
    private static func dedupe(_ list: [Found]) -> [Found] {
        var byHost: [String: Found] = [:]
        for f in list {
            let host = f.url.host ?? ""
            if let existing = byHost[host], existing.url.port == 8971 { continue }
            byHost[host] = f
        }
        return byHost.values.sorted { $0.url.absoluteString < $1.url.absoluteString }
    }

    nonisolated private static func probe(_ url: URL, session: URLSession) async -> Found? {
        guard let (data, response) = try? await session.data(from: url.appendingPathComponent("api/version")),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.first?.isNumber == true, text.count < 40, text.contains(".") else { return nil }
        return Found(url: url, version: text)
    }

    /// First three octets of each private IPv4 interface address.
    nonisolated static func localPrefixes() -> [String] {
        var prefixes: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard !["lo", "utun", "bridge", "pdp", "awdl", "llw", "anpi"].contains(where: { name.hasPrefix($0) }) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            let parts = ip.split(separator: ".")
            guard parts.count == 4, ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || isPrivate172(parts) else { continue }
            let prefix = parts.prefix(3).joined(separator: ".")
            if !prefixes.contains(prefix) { prefixes.append(prefix) }
        }
        return prefixes
    }

    nonisolated private static func isPrivate172(_ parts: [Substring]) -> Bool {
        guard parts[0] == "172", let second = Int(parts[1]) else { return false }
        return (16...31).contains(second)
    }
}
