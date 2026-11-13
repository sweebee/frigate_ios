import SwiftUI

@main
struct FrigateApp: App {
    @State private var model = AppModel()
    private let network = NetworkStatus.shared

    init() {
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(red: 16 / 255, green: 18 / 255, blue: 21 / 255, alpha: 0.96)
        tab.shadowColor = UIColor(Theme.cardBorder)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.backgroundColor = UIColor(Theme.background)
        nav.titleTextAttributes = [.foregroundColor: UIColor(Theme.text)]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor(Theme.text)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                // Menus draw their own chips and buttons; on the Mac they would otherwise get a
                // bezel and extra arrows around them.
                .menuIndicator(.hidden)
                .menuStyle(PlainMenuStyle())
                .modifier(BorderlessButtonsOnMac())
        }
        .commands {
            // On the Mac, settings live in the app menu (⌘,) instead of the sidebar.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.tab = .settings }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        @Bindable var model = model
        Group {
            if model.servers.isEmpty {
                NavigationStack { ConnectView(isOnboarding: true) }
            } else if horizontalSizeClass == .regular {
                SidebarRoot()
            } else {
                TabView(selection: $model.tab) {
                    LiveView()
                        .tabItem { Label("Live", systemImage: "square.grid.2x2") }
                        .tag(AppModel.Tab.live)
                    ReviewView()
                        .tabItem { Label("Review", systemImage: "eye") }
                        .tag(AppModel.Tab.review)
                        .badge(model.unreviewedAlerts)
                    ExploreView()
                        .tabItem { Label("Explore", systemImage: "magnifyingglass") }
                        .tag(AppModel.Tab.explore)
                    if !model.chatConnections.isEmpty {
                        ChatView()
                            .tabItem { Label("Chat", systemImage: "bubble.left.and.text.bubble.right") }
                            .tag(AppModel.Tab.chat)
                    }
                    ServersView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(AppModel.Tab.settings)
                }
            }
        }
        .background(Theme.background)
        .sheet(isPresented: $model.showAddServer) {
            NavigationStack { ConnectView() }
        }
        .task {
            await model.connectAll()
            // Screenshots: `-ScreenshotRoute camera/carport` opens a screen without a URL prompt.
            if let route = UserDefaults.standard.string(forKey: "ScreenshotRoute"), let url = URL(string: "frigate://" + route) {
                try? await Task.sleep(for: .seconds(1))
                await model.handle(url)
            }
        }
        .onOpenURL { url in Task { await model.handle(url) } }
        .onChange(of: NetworkStatus.shared.changes) { _, _ in model.networkChanged() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshAll(reloadConfig: true) } }
            // The activity feed reopens on the next refresh.
            if phase == .background { model.orderedConnections.forEach { $0.stopActivityFeed() } }
        }
    }
}

/// Menus show their label as drawn (chips, icons) without a button bezel around it, which
/// the Mac adds by default; only the menu's own buttons are plain, not the rest of the app.
private struct PlainMenuStyle: MenuStyle {
    func makeBody(configuration: Configuration) -> some View {
        Menu(configuration)
            .menuStyle(.button)
            .buttonStyle(.plain)
    }
}

/// The Mac draws a bezel around buttons by default; text buttons here are plain accent text.
private struct BorderlessButtonsOnMac: ViewModifier {
    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content.buttonStyle(.borderless)
        #else
        content
        #endif
    }
}
