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
                case .chat: ChatView()
                case .settings: ServersView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Mac: the hidden title bar keeps 28 pt at the top. The window buttons sit over
            // the rail, so the screens move up into that room. Done with layout, not the safe
            // area: changing that made every newly opened screen jump once.
            .padding(.bottom, isMac ? -18 : 0)
            .offset(y: isMac ? -18 : 0)
        }
        .onAppear(perform: hideWindowTitle)
    }

    private var rail: some View {
        VStack(spacing: 10) {
            item(.live, "Live", "square.grid.2x2")
            item(.review, "Review", "eye", badge: model.unreviewedAlerts)
            item(.explore, "Explore", "magnifyingglass")
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

