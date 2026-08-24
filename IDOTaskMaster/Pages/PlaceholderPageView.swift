import SwiftUI

/// Shared "not built yet" body for every `Pages/*Page.swift` view below —
/// PLAN.md §4 M1's "Native sidebar shell with all pages routed
/// (placeholder views allowed)."
///
/// Each page already has its own real `View` type from this milestone on
/// (`SummaryPage`, `PerformancePage`, ...) — matching PLAN.md §3's
/// `Pages/` listing, which already names every page a later milestone
/// will fill in — precisely so that milestone edits that one file's body
/// in place rather than needing to create a new file and wire it into
/// `AppShell`'s routing. `PlaceholderPageView` is just the body every one
/// of those files hands back today.
///
/// Deliberately styled distinctly from `StatTile`/`DetailPane`'s
/// "Unavailable" convention: that phrase is reserved for a live provider
/// failing to read real hardware data this tick (PLAN.md §2 "honest
/// degradation"). A page that simply hasn't been built yet is a
/// different, unalarming state — a calm work-in-progress notice instead,
/// using `.secondary`/`.tertiary` text rather than the dimmed-and-flagged
/// look those components use for a degraded reading.
struct PlaceholderPageView: View {
    let page: SidebarPage
    /// One line naming what this page will show, e.g. "Sparkline rail
    /// and per-domain detail stats (CPU, Memory, GPU, ...)." Sourced from
    /// PLAN.md §1.1's screen-by-screen inventory for the matching page.
    /// `page.buildMilestone` is appended automatically, so callers don't
    /// repeat it here.
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: page.systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(page.title)
                .font(.title2)
                .fontWeight(.semibold)
            Text("\(detail) Arrives in \(page.buildMilestone).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(page.title). Not yet implemented.")
        .accessibilityHint(detail)
    }
}

// MARK: - Preview

#Preview {
    PlaceholderPageView(
        page: .performance,
        detail: "Sparkline rail and per-domain detail stats (CPU, Memory, GPU, Disk, Network, Energy, Thermals, NPU)."
    )
    .frame(width: 520, height: 340)
}
