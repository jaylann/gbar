import AppKit
import SwiftUI

/// A circular user/org avatar. Loads from a URL, shimmers while loading, and falls
/// back to the login's initial on a color derived deterministically from the login —
/// so a missing image is still identifiable and stable across refreshes.
struct Avatar: View {
    let login: String
    var url: URL?
    var size: Size = .small

    enum Size {
        case small
        case medium
        case large

        var diameter: CGFloat {
            switch self {
            case .small: 20
            case .medium: 28
            case .large: 32
            }
        }
    }

    /// The loaded image once fetched. A cache hit is read synchronously in `body` (below), so this
    /// only matters for the async miss path — the `LazyVStack` recycles rows constantly while
    /// scrolling, and re-decoding a fresh `NSImage` per recycle is the classic avatar scroll-jank.
    @State private var loaded: NSImage?

    var body: some View {
        // Prefer the async-loaded image, else a synchronous cache hit — reading the decoded image
        // straight from the shared cache avoids a one-frame placeholder flash when a recycled row
        // rebinds to an already-seen avatar.
        let image = loaded ?? url.flatMap { AvatarImageCache.shared.cached($0) }
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else if url != nil {
                fallback.redacted(reason: .placeholder)
            } else {
                fallback
            }
        }
        .frame(width: size.diameter, height: size.diameter)
        .clipShape(Circle())
        // Re-run when the row recycles onto a different avatar; cancels the previous load.
        .task(id: url) {
            guard let url else {
                loaded = nil
                return
            }
            if let hit = AvatarImageCache.shared.cached(url) {
                loaded = hit
                return
            }
            loaded = await AvatarImageCache.shared.image(for: url)
        }
    }

    private var fallback: some View {
        generatedColor
            .overlay {
                Text(initial)
                    .font(.system(size: size.diameter * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }

    private var initial: String {
        guard let first = login.first else { return "?" }
        return String(first).uppercased()
    }

    /// Stable hue from the login so the same user always gets the same swatch.
    private var generatedColor: Color {
        let hash = login.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $0 &+ $1.value }
        let hue = Double(hash % 360) / 360
        return Color(hue: hue, saturation: 0.55, brightness: 0.65)
    }
}

/// Process-wide cache of decoded avatar images. Keyed by URL, it holds the already-decoded
/// `NSImage` so a recycled `LazyVStack` row rebinding to a seen avatar renders synchronously
/// instead of re-fetching and re-decoding (which `AsyncImage` does on every mount). Concurrent
/// loads of the same URL are coalesced onto one in-flight task. `@MainActor`-isolated so the
/// non-`Sendable` `NSImage`s never cross an actor boundary — only `Data` is fetched off-actor.
@MainActor
final class AvatarImageCache {
    static let shared = AvatarImageCache()

    /// Soft cap on distinct cached avatars. A menu-bar session rarely sees this many, but bound it
    /// so a long-lived agent process can't grow the cache unboundedly; the oldest-inserted entry is
    /// evicted past the cap.
    private static let capacity = 256

    private var images: [URL: NSImage] = [:]
    private var order: [URL] = []
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    /// A synchronous cache hit, if the image is already decoded and resident.
    func cached(_ url: URL) -> NSImage? {
        images[url]
    }

    /// Return the decoded image, fetching and caching it on a miss. Coalesces concurrent callers
    /// for the same URL onto a single download+decode.
    func image(for url: URL) async -> NSImage? {
        if let hit = images[url] { return hit }
        if let existing = inFlight[url] { return await existing.value }
        let task = Task { [weak self] () -> NSImage? in
            let data = await Self.fetchData(url)
            let image = data.flatMap { NSImage(data: $0) }
            self?.store(image, for: url)
            self?.inFlight[url] = nil
            return image
        }
        inFlight[url] = task
        return await task.value
    }

    /// Insert a freshly decoded image, evicting the oldest entry once past `capacity`.
    private func store(_ image: NSImage?, for url: URL) {
        guard let image else { return }
        if images[url] == nil { order.append(url) }
        images[url] = image
        if order.count > Self.capacity {
            let evicted = order.removeFirst()
            images[evicted] = nil
        }
    }

    /// Fetch the raw bytes off the main actor. Returns only `Sendable` `Data` so the `NSImage`
    /// decode happens back on the main actor; a non-2xx response or transport error yields `nil`.
    private static func fetchData(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        return data
    }
}

#if DEBUG
#Preview("Avatar") {
    HStack(spacing: Theme.Spacing.md) {
        Avatar(login: "jaylann", size: .small)
        Avatar(login: "octocat", size: .medium)
        Avatar(login: "github", size: .large)
    }
    .padding(Theme.Spacing.xl)
}
#endif
