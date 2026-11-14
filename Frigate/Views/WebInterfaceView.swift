import SwiftUI
import WebKit

/// Frigate's own web interface inside the app. The app's login cookie is copied into the web
/// view first, so a server with a password opens already signed in (Safari keeps its own cookies).
struct WebInterfaceView: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            WebView(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { closePresented(dismiss) }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { openURL(url) } label: { Image(systemName: "safari") }
                            .accessibilityLabel("Open in Safari")
                    }
                }
        }
    }
}

private struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = UIColor(Theme.background)
        web.allowsBackForwardNavigationGestures = true
        let cookies = (HTTPCookieStorage.shared.cookies ?? []).filter { cookie in
            guard let host = url.host else { return false }
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return host == domain || host.hasSuffix("." + domain)
        }
        let store = config.websiteDataStore.httpCookieStore
        Task { @MainActor in
            for cookie in cookies { await store.setCookie(cookie) }
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}
}
