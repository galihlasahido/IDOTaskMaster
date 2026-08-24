import SwiftUI

/// History page — one of this app's own beyond-[name removed] additions (PLAN.md
/// §2: "persistent history (SQLite, 24h/7d views)") / §4 M9. Placeholder
/// until M9 adds `HistoryStore` (downsampled SQLite persistence) and the
/// 24h/7d per-domain browsing charts.
struct HistoryPage: View {
    var body: some View {
        PlaceholderPageView(
            page: .history,
            detail: "24h/7d charts per domain, backed by persistent SQLite history that survives app restarts."
        )
    }
}

#Preview {
    HistoryPage()
}
