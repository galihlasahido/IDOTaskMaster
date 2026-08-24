import SwiftUI

/// Semantic status colors shared across every domain — not tied to any
/// one metric, but reused wherever the UI needs to say "this is fine /
/// this needs attention / this failed": provider health in the bottom
/// info bar, capacity-bar warning thresholds, and (later) the
/// `AlertsEngine`'s rule severities.
///
/// Kept separate from `DomainPalette` because these read the same
/// everywhere (a critical CPU reading and a critical disk-space warning
/// should look the same shade of red) rather than inheriting whatever
/// hue that domain happens to be tinted.
enum StatusPalette {
    /// Provider sampled successfully; metric within a normal range.
    static let healthy = Color(nsColor: .systemGreen)
    /// Elevated but not critical (e.g. a provider running on a stale
    /// sample, a metric approaching a threshold).
    static let warning = Color(nsColor: .systemYellow)
    /// Requires attention: a provider failed this tick, or a metric is
    /// past its critical threshold.
    static let critical = Color(nsColor: .systemRed)
    /// No data source available for this metric. Paired with an explicit
    /// "Unavailable" label per PLAN.md's honest-degradation rule —
    /// providers report this instead of a guessed value.
    static let unavailable = Color(nsColor: .tertiaryLabelColor)
}
