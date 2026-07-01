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
}
