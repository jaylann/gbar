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
    /// The load finished without an image (transport error / non-2xx / decode failure). Kept
    /// distinct from "still loading" so a failed avatar falls back to the identifiable monogram
    /// rather than a permanent gray placeholder.
    @State private var failed = false

    var body: some View {
        // Prefer the async-loaded image, else a synchronous cache hit — reading the decoded image
        // straight from the shared cache avoids a one-frame placeholder flash when a recycled row
        // rebinds to an already-seen avatar.
        let image = loaded ?? url.flatMap { AvatarImageCache.shared.cached($0) }
        // Treat a URL the shared cache already knows failed as failed straight away, so a recycled
        // row for a broken avatar shows the monogram without a redacted-placeholder flash.
        let didFail = failed || (url.map { AvatarImageCache.shared.hasFailed($0) } ?? false)
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else if url == nil || didFail {
                fallback
            } else {
                fallback.redacted(reason: .placeholder)
            }
        }
        .frame(width: size.diameter, height: size.diameter)
        .clipShape(Circle())
        // Re-run when the row recycles onto a different avatar; cancels the previous load.
        .task(id: url) {
            failed = false
            guard let url else {
                loaded = nil
                return
            }
            if let hit = AvatarImageCache.shared.cached(url) {
                loaded = hit
                return
            }
            let result = await AvatarImageCache.shared.image(for: url)
            // The view identity may have rebound to a new URL while the shared fetch was in flight;
            // don't write a stale result over the newer load.
            guard !Task.isCancelled else { return }
            if let result {
                loaded = result
            } else {
                failed = true
            }
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
    /// URLs whose last load failed — a negative cache so scrolling past a broken avatar doesn't
    /// re-issue the doomed fetch on every row mount. Bounded like `images`.
    private var failedURLs: Set<URL> = []

    /// A synchronous cache hit, if the image is already decoded and resident.
    func cached(_ url: URL) -> NSImage? {
        images[url]
    }

    /// Whether this URL's last load failed (used to show the monogram fallback without retrying).
    func hasFailed(_ url: URL) -> Bool {
        failedURLs.contains(url)
    }

    /// Return the decoded image, fetching and caching it on a miss. Coalesces concurrent callers
    /// for the same URL onto a single download+decode; a previously failed URL returns `nil` fast.
    func image(for url: URL) async -> NSImage? {
        if let hit = images[url] { return hit }
        if failedURLs.contains(url) { return nil }
        if let existing = inFlight[url] { return await existing.value }
        let task = Task { [weak self] () -> NSImage? in
            let data = await Self.fetchData(url)
            let image = data.flatMap { NSImage(data: $0) }
            self?.finish(image, for: url)
            return image
        }
        inFlight[url] = task
        return await task.value
    }

    /// Record a completed load: clear the in-flight entry, then cache the image or mark the URL
    /// failed.
    private func finish(_ image: NSImage?, for url: URL) {
        inFlight[url] = nil
        guard let image else {
            failedURLs.insert(url)
            if failedURLs.count > Self.capacity { _ = failedURLs.popFirst() }
            return
        }
        failedURLs.remove(url)
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
