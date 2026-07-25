import SwiftUI

/// Brief, physical motion only. Springs for arrivals/settles, a short ease for
/// state flips. Nothing long or decorative.
enum Motion {
    /// Micro-interactions (selection, small state changes).
    static let micro = Animation.spring(response: 0.28, dampingFraction: 0.86)
    /// Content settling into place.
    static let settle = Animation.spring(response: 0.42, dampingFraction: 0.82)
    /// Quick opacity/state flips (e.g. streaming indicator).
    static let quick = Animation.easeOut(duration: 0.18)
}
