import SwiftUI
import UIKit

/// Small in-memory cache for thumbnails.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, UIImage>()
    init() { cache.countLimit = 400 }
    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func set(_ image: UIImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}

/// Loads an image from a Frigate server. With `refresh` set it reloads periodically
/// while visible and keeps showing the previous frame until the next one arrives.
struct RemoteImage: View {
    let url: URL?
    var session: URLSession = .shared
    var refresh: TimeInterval? = nil
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Theme.placeholder
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if failed {
                Image(systemName: "photo").foregroundStyle(Theme.textSecondary.opacity(0.5))
            }
        }
        .clipped()
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { return }
        if refresh == nil, let cached = ImageCache.shared.image(for: url) {
            image = cached
            return
        }
        repeat {
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            if let (data, response) = try? await session.data(for: req),
               (response as? HTTPURLResponse)?.statusCode ?? 200 < 300,
               let img = await decode(data) {
                image = img
                failed = false
                if refresh == nil { ImageCache.shared.set(img, for: url) }
            } else if image == nil {
                failed = true
            }
            guard let refresh else { return }
            try? await Task.sleep(for: .seconds(refresh))
        } while !Task.isCancelled
    }

    private func decode(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            UIImage(data: data)?.preparingForDisplay()
        }.value
    }
}
