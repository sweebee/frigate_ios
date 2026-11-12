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
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        Group {
            if model.servers.isEmpty {
                NavigationStack { ConnectView(isOnboarding: true) }
            } else {
                TabView(selection: $model.tab) {
                    LiveView()
                        .tabItem { Label("Live", systemImage: "square.grid.2x2") }
                        .tag(AppModel.Tab.live)
                    ReviewView()
                        .tabItem { Label("Review", systemImage: "eye") }
                        .tag(AppModel.Tab.review)
                        .badge(model.unreviewedAlerts)
                    HistoryOverviewView()
                        .tabItem { Label("History", systemImage: "clock") }
                        .tag(AppModel.Tab.history)
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshAll() } }
        }
    }
}
