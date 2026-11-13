import SwiftUI

/// Layout for wide screens (iPad full screen, the Mac): a sidebar with the sections and every
/// camera per server instead of a tab bar. Narrow windows keep the tab bar (RootView).
struct SidebarRoot: View {
    @Environment(AppModel.self) private var model
    /// Keep the sidebar visible, also with the iPad upright (the system would hide it).
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            // Plain buttons, no List selection: on iPad a selectable list ignored taps on the
            // camera rows, and picking the open item again must still go back to its start.
            List {
                Section {
                    row(.live, "Live", "square.grid.2x2")
                    row(.review, "Review", "eye", badge: model.unreviewedAlerts)
                    row(.explore, "Explore", "magnifyingglass")
                    if !model.chatConnections.isEmpty {
                        row(.chat, "Chat", "bubble.left.and.text.bubble.right")
                    }
                }
                ForEach(model.orderedConnections) { conn in
                    Section {
                        ForEach(conn.cameras, id: \.name) { camera in
                            cameraRow(conn: conn, camera: camera)
                        }
                    } header: {
                        // In line with the row titles.
                        Text(conn.server.name).padding(.leading, ProcessInfo.processInfo.isMacCatalystApp ? 10 : 0)
                    }
                }
                if !ProcessInfo.processInfo.isMacCatalystApp {
                    Section {
                        row(.settings, "Settings", "gearshape")
                    }
                }
            }
            .listStyle(.sidebar)
            // Room between the title bar and the first row (its highlight touched the bar).
            .contentMargins(.top, ProcessInfo.processInfo.isMacCatalystApp ? 28 : 12, for: .scrollContent)
            // No title: the app name only took room above the sections.
            .toolbar(.hidden, for: .navigationBar)
            // The detail screens hide their navigation bar, so a collapsed sidebar could not be
            // brought back: keep it always open.
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            switch model.tab {
            case .live: LiveView()
            case .review: ReviewView()
            case .explore: ExploreView()
            case .chat: ChatView()
            case .settings: ServersView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear(perform: hideWindowTitle)
    }

    /// On the Mac: no "Tender" in the window's title bar either.
    private func hideWindowTitle() {
        #if targetEnvironment(macCatalyst)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.titlebar?.titleVisibility = .hidden
        }
        #endif
    }

    private func row(_ tab: AppModel.Tab, _ title: LocalizedStringKey, _ icon: String, badge: Int = 0) -> some View {
        let selected = model.tab == tab && !(tab == .live && model.openCamera != nil)
        return Button {
            switch tab {
            case .live: model.livePath = NavigationPath()
            case .review: if model.tab == .review { model.reviewPath = NavigationPath() }
            case .explore: if model.tab == .explore { model.explorePath = NavigationPath() }
            default: break
            }
            model.tab = tab
        } label: {
            SidebarRowLabel(selected: selected) {
                // Fixed icon width so every title starts at the same x.
                Image(systemName: icon).font(.system(size: 16)).frame(width: 22)
                Text(title)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)").font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .sidebarRow()
    }

    private func cameraRow(conn: ServerConnection, camera: CameraConfig) -> some View {
        let active = conn.isCameraOnline(camera.name) && conn.activity[camera.name]?.motion == true
        let route = CameraRoute(serverID: conn.server.id, camera: camera.name)
        let open = model.tab == .live && model.openCamera == route
        return Button {
            model.tab = .live
            model.livePath = NavigationPath()
            model.livePath.append(route)
            model.openCamera = route
        } label: {
            SidebarRowLabel(selected: open) {
                Text(camera.displayName).lineLimit(1)
                Spacer(minLength: 4)
                if active { MotionDot() }
            }
        }
        .sidebarRow()
    }
}

/// One sidebar row: the same insets everywhere, and a rounded highlight with even room
/// around the content when selected.
private struct SidebarRowLabel<Content: View>: View {
    let selected: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .font(.system(size: 15))
            .foregroundStyle(selected ? Theme.accent : Theme.text)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.accent.opacity(0.16) : .clear))
            .contentShape(Rectangle())
    }
}

private extension View {
    /// Rows draw their own highlight; the list only places them with even insets.
    func sidebarRow() -> some View {
        buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
