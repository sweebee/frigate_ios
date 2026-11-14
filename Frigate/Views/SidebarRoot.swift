import SwiftUI

/// Layout for wide screens (iPad full screen, the Mac): a narrow rail of section icons on the
/// left, like Frigate's own web app, instead of a tab bar; cameras open from Live. Narrow
/// windows keep the tab bar (RootView).
struct SidebarRoot: View {
    @Environment(AppModel.self) private var model
    private let isMac = ProcessInfo.processInfo.isMacCatalystApp

    var body: some View {
        HStack(spacing: 0) {
            if !model.immersive {
                rail
                Divider().overlay(Theme.cardBorder)
            }
            Group {
                switch model.tab {
                case .live: LiveView()
                case .review: ReviewView()
                case .explore: ExploreView()
                case .exports: ExportsSection()
                case .chat: ChatView()
                case .settings: ServersView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Mac: a new section settles its top inset in its first frames (the title bar's
            // room, see hideWindowTitle); fading it in keeps that from showing as a jump.
            .modifier(NoTopEdgeEffect(enabled: isMac))
            .id(isMac ? model.tab : .live)
            .transition(.opacity.animation(.easeIn(duration: 0.16)))
        }
        .onAppear(perform: hideWindowTitle)
    }

    private var rail: some View {
        VStack(spacing: 10) {
            item(.live, "Live", "square.grid.2x2")
            item(.review, "Review", "eye", badge: model.unreviewedAlerts)
            item(.explore, "Explore", "magnifyingglass")
            item(.exports, "Exports", "film.stack")
            if !model.chatConnections.isEmpty {
                item(.chat, "Chat", "bubble.left.and.text.bubble.right")
            }
            Spacer(minLength: 0)
            item(.settings, "Settings", "gearshape")
        }
        // On the Mac the window buttons sit in the top-left corner, above the first icon.
        .padding(.top, isMac ? 28 : 16)
        .padding(.bottom, 16)
        .frame(width: isMac ? 76 : 72)
        .frame(maxHeight: .infinity)
        .background(Theme.card.opacity(0.5).ignoresSafeArea())
    }

    /// On the Mac: no "Tender" in the window's title bar either.
    private func hideWindowTitle() {
        #if targetEnvironment(macCatalyst)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.titlebar?.titleVisibility = .hidden
            // The hidden title bar still keeps its 28 pt at the top as safe area. The window
            // buttons sit over the rail, so give 18 of it back: screens start 10 pt down.
            for window in scene.windows { window.rootViewController?.additionalSafeAreaInsets.top = -18 }
        }
        #endif
    }

    private func item(_ tab: AppModel.Tab, _ title: LocalizedStringKey, _ icon: String, badge: Int = 0) -> some View {
        let selected = model.tab == tab
        return Button {
            // Picking the open section again goes back to its start.
            switch tab {
            case .live: if model.tab == .live { model.livePath = NavigationPath() }
            case .review: if model.tab == .review { model.reviewPath = NavigationPath() }
            case .explore: if model.tab == .explore { model.explorePath = NavigationPath() }
            case .exports: if model.tab == .exports { model.exportsPath = NavigationPath() }
            default: break
            }
            model.tab = tab
        } label: {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Theme.accent.opacity(0.16) : .clear))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                            .background(Theme.recording, in: Capsule())
                            .offset(x: 6, y: -4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }
}


/// Mac: no bar at the top edge when the pointer comes near the (hidden) title bar; macOS 26
/// draws its scroll edge effect there over content that runs under it.
private struct NoTopEdgeEffect: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), enabled {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}
