import SwiftUI

struct ServersView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: ServerConfig?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
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

                    SectionLabel(text: L("Your servers")).padding(.top, 10)
                    ForEach(model.orderedConnections) { conn in
                        serverRow(conn)
                    }

                    VStack(spacing: 0) {
                        ToggleRow(title: L("Live video in overview"),
                                  subtitle: L("Plays the low-resolution stream of every camera instead of refreshing snapshots. Uses more data and battery."),
                                  isOn: model.liveGrid) { on in withAnimation { model.liveGrid = on } }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(minHeight: 60)
                        if model.liveGrid {
                            Rectangle().fill(Theme.cardBorder).frame(height: 1)
                            ToggleRow(title: L("Also on mobile data"), isOn: model.liveGridOnCellular) { model.liveGridOnCellular = $0 }
                                .padding(.horizontal, 14)
                                .frame(minHeight: 52)
                        }
                    }
                    .card()
                    .padding(.top, 10)

                    Text("Frigate for iOS · connects directly to your Frigate NVR servers.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 20)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .refreshable { await model.refreshAll() }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $editing) { server in
                NavigationStack { ConnectView(existing: server) }
            }
        }
    }

    private var allSummary: String {
        let online = model.onlineConnections
        let cams = online.reduce(0) { $0 + $1.cameras.count }
        return L("\(cams) cameras") + " " + L("from \(online.count) online servers")
    }

    private func serverRow(_ conn: ServerConnection) -> some View {
        let active = model.scope == .server(conn.server.id)
        return HStack(spacing: 12) {
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
            Button { editing = conn.server } label: {
                Image(systemName: "info.circle").font(.system(size: 20)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 44, height: 44)
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
