import SwiftUI

/// Motion tokens. The rule for a menu-bar tool: the only things that move are state
/// changes the user should notice (a row lighting under the pointer, CI going from
/// running to done, an item becoming seen). Everything else is instant. Every value
/// is ≤200ms and every helper collapses to a near-instant fade when Reduce Motion is
/// on, so the always-on utility stays calm for motion-sensitive users.
enum Motion {
    /// Row/control hover highlight. Fast enough to feel live, soft enough not to
    /// flicker while scanning a list.
    static let hover: Animation = .easeOut(duration: 0.13)

    /// Segment switches and row expand/collapse. One gentle bounce, no slow slide.
    static let spring: Animation = .spring(response: 0.28, dampingFraction: 0.85)

    /// Tab-content swap. A short easeOut (no spring settle tail) so switching feels immediate
    /// even into a long list — the flourish is over before the incoming list's build cost can
    /// read as lag.
    static let tabSwitch: Animation = .easeOut(duration: 0.18)

    /// Unseen-dot fade-out and other quiet acknowledgments.
    static let fade: Animation = .easeInOut(duration: 0.2)

    /// The gentle opacity pulse on a *running* CI indicator (autoreversed forever).
    static let pulse: Animation = .easeInOut(duration: 1.0).repeatForever(autoreverses: true)

    /// Reduce-Motion-aware variant: returns `animation` normally, or a near-instant
    /// opacity fade when the user has asked for less motion. Read the flag with
    /// `@Environment(\.accessibilityReduceMotion)` at the call site.
    static func respecting(_ reduceMotion: Bool, _ animation: Animation) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.08) : animation
    }

    /// How far tab content drifts as it slides in/out — small enough to read as a soft settle,
    /// not a full page turn (a menu-bar panel shouldn't feel like it's paging).
    static let slideDistance: CGFloat = 12

    /// Asymmetric soft slide for swapping tab content. `forward` == the new tab sits to the
    /// right of the old one: the incoming view slides in from the trailing edge while the
    /// outgoing view is pushed off toward the leading edge, both cross-fading. Collapses to a
    /// plain fade under Reduce Motion. Pair with `.id(tab)` on the content and
    /// `.animation(…, value: tab)` on the container so the identity swap drives it.
    static func softSlide(forward: Bool, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let insert: CGFloat = forward ? slideDistance : -slideDistance
        let remove: CGFloat = forward ? -slideDistance : slideDistance
        return .asymmetric(
            insertion: .offset(x: insert).combined(with: .opacity),
            removal: .offset(x: remove).combined(with: .opacity)
        )
    }
}
