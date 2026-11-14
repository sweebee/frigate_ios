import SwiftUI

struct ServersView: View {
    @Environment(AppModel.self) private var model
    @State private var webInterface: WebTarget?
    @State private var reordering = false

    struct WebTarget: Identifiable {
        let url: URL
        let title: String
        var id: String { url.absoluteString }
    }
    @State private var editing: ServerConfig?

    /// Inside another navigation stack (the phone's More tab): no stack of its own, and a
    /// back button.
    var embedded = false
    @Environment(\.dismiss) private var dismissEmbedded

    var body: some View {
        if embedded {
            VStack(spacing: 0) {
                HStack {
                    Button { dismissEmbedded() } label: { BackButtonLabel() }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Back")
                    Spacer()
                }
                .headerBarPadding()
                content
            }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
        } else {
            NavigationStack { content }
        }
    }

    @ViewBuilder
    private var content: some View {
        @Bindable var model = model
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        LargeTitle(text: L("Servers"))
                        Spacer()
                        Button { model.showAddServer = true } label: {
                            Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(Theme.card, in: Circle())
                                .overlay(Circle().stroke(Theme.controlBorder, lineWidth: 1))
                        }
                        .accessibilityLabel("Add server")
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                    SectionLabel(text: L("Show"))
                    Button {
                        model.scope = .all
                        model.tab = .live
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "server.rack").font(.system(size: 19))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 40, height: 40)
                                .background(Color(hex: 0x1F2329), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("All servers").font(.system(size: 16, weight: .semibold))
                                Text(allSummary).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            if model.scope == .all {
                                Image(systemName: "checkmark").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.accent)
                            }
                        }
                        .padding(14)
                        .card(border: model.scope == .all ? Theme.accent : Theme.cardBorder)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    HStack {
                        SectionLabel(text: L("Your servers"))
                        if model.servers.count > 1 {
                            Button { reordering = true } label: {
                                Image(systemName: "arrow.up.arrow.down")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(width: 32, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Reorder servers")
                        }
                    }
                    .padding(.top, 10)
                    ForEach(model.orderedConnections) { conn in
                        serverRow(conn)
                    }

                    SectionLabel(text: L("Settings")).padding(.top, 10)
                    NavigationLink {
                        LiveSettingsView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 32, height: 32)
                                .background(Theme.control, in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Live view").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                                Text("Live video, automatic live view, recent alerts")
                                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .card()
                    }
                    .buttonStyle(.plain)

                    Text("Tender for Frigate · connects directly to your Frigate NVR servers. Not affiliated with the Frigate project.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 20)
                    versionLine
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .refreshable { await model.refreshAll(reloadConfig: true) }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $reordering) { ReorderServersSheet() }
            .fullScreenCover(item: $webInterface) { WebInterfaceView(url: $0.url, title: $0.title) }
            .sheet(item: $editing) { server in
                NavigationStack { ConnectView(existing: server) }
            }
    }

    /// "Version 1.0 (202611121554) · fe23b90"; the commit links to it on GitHub.
    private var versionLine: some View {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let commit = (info["GitCommit"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return HStack(spacing: 4) {
            Text(L("Version \(version) (\(build))"))
            if let commit {
                Text("·")
                Link(commit, destination: URL(string: "https://github.com/sweebee/tender-for-frigate/commit/\(commit)")!)
                    .font(.system(size: 12).monospaced())
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.textSecondary)
        .frame(maxWidth: .infinity)
        .textSelection(.enabled)
    }

    private var allSummary: String {
        let online = model.onlineConnections
        let cams = online.reduce(0) { $0 + $1.cameras.count }
        return L("\(cams) cameras") + " " + L("from \(online.count) online servers")
    }

    private func serverRow(_ conn: ServerConnection) -> some View {
        let active = model.scope == .server(conn.server.id)
        return HStack(spacing: 4) {
            Button {
                model.scope = .server(conn.server.id)
                model.tab = .live
            } label: {
                HStack(spacing: 12) {
                    Text(conn.server.initial)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.onColor)
                        .frame(width: 40, height: 40)
                        .background(conn.server.tint, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(conn.server.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                            StatusDot(color: statusColor(conn))
                        }
                        Text(conn.metaLine).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        Text(ServerConfig.displayAddress(conn.usingRemote ? (conn.server.remoteURL ?? conn.server.url) : conn.server.url))
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if active {
                        Image(systemName: "checkmark").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.accent)
                            .accessibilityLabel("Active server")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Frigate's own web interface, at the address the app uses right now (local or remote).
            if let web = conn.client?.baseURL ?? ServerConfig.normalizedURL(conn.server.url) {
                Button { webInterface = WebTarget(url: web, title: conn.server.name) } label: {
                    Image(systemName: "safari").font(.system(size: 20)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 40, height: 44)
                }
                .accessibilityLabel(L("Open the web interface of \(conn.server.name)"))
            }
            Button { editing = conn.server } label: {
                Image(systemName: "info.circle").font(.system(size: 20)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 40, height: 44)
            }
            .accessibilityLabel("Edit \(conn.server.name)")
        }
        .padding(14)
        .card(border: active ? Theme.accent : Theme.cardBorder)
    }

    private func statusColor(_ conn: ServerConnection) -> Color {
        switch conn.status {
        case .online: return Theme.online
        case .connecting: return Theme.warning
        case .offline: return Theme.offline
        }
    }
}

/// Settings for the Live tab, in their own screen.
struct LiveSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Button { dismiss() } label: {
                        BackButtonLabel()
                    }
                    .accessibilityLabel("Back")
                    Text("Live view").font(.system(size: 28, weight: .bold)).kerning(-0.4)
                }
                .padding(.top, 8)
                .padding(.bottom, 4)

                SectionLabel(text: L("Camera tiles"))
                VStack(spacing: 0) {
                    row(ToggleRow(title: L("Live video in overview"),
                                  subtitle: L("Plays the low-resolution stream of every camera instead of refreshing snapshots. Uses more data and battery."),
                                  isOn: model.liveGrid) { on in withAnimation { model.liveGrid = on } })
                    if model.liveGrid {
                        divider
                        row(ToggleRow(title: L("Also on mobile data"), isOn: model.liveGridOnCellular) { model.liveGridOnCellular = $0 })
                    } else {
                        divider
                        row(ToggleRow(title: L("Automatic live view"),
                                      subtitle: L("Switches a camera to live video while it sees motion or a moving object, and back to snapshots when it is quiet."),
                                      isOn: model.autoLive) { model.autoLive = $0 })
                    }
                }
                .card()

                SectionLabel(text: L("Alerts")).padding(.top, 14)
                VStack(spacing: 0) {
                    row(ToggleRow(title: L("Show recent alerts"),
                                  subtitle: L("Shows unreviewed alerts of the last day at the top of Live."),
                                  isOn: model.showRecentAlerts) { on in withAnimation { model.showRecentAlerts = on } })
                    if model.showRecentAlerts {
                        divider
                        row(ToggleRow(title: L("Play alerts"),
                                      subtitle: L("Plays recent alerts as short looping clips. Turn off to show a still image."),
                                      isOn: model.playAlertPreviews) { model.playAlertPreviews = $0 })
                    }
                }
                .card()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
    }

    private var divider: some View { Rectangle().fill(Theme.cardBorder).frame(height: 1) }

    private func row(_ toggle: ToggleRow) -> some View {
        toggle
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 56)
    }
}

/// Drag servers into the order the tabs show them in.
struct ReorderServersSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.servers) { server in
                    HStack(spacing: 12) {
                        ServerBadge(initial: server.initial, tint: server.tint, size: 28)
                        Text(server.name).font(.system(size: 16, weight: .semibold))
                    }
                    .listRowBackground(Theme.card)
                }
                .onMove { model.moveServers(from: $0, to: $1) }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(L("Reorder servers"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
