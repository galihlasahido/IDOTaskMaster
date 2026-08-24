import SwiftUI

/// Network Usage page — one of this app's own beyond-[name removed] additions
/// (PLAN.md §2: "per-process network traffic") / §4 M9. Placeholder
/// until M9 adds `NetTrafficProvider` (nettop-style per-process
/// send/receive rates) and its sortable table with totals.
struct NetworkUsagePage: View {
    var body: some View {
        PlaceholderPageView(
            page: .networkUsage,
            detail: "Per-process send/receive rate table (nettop-style), sortable, with totals."
        )
    }
}

#Preview {
    NetworkUsagePage()
}
