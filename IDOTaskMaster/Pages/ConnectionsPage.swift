import SwiftUI

/// Connections page — PLAN.md §1.1 "Connections" (a former [name removed] Pro
/// page, unlocked here per §2) / §4 M6. Placeholder until M6 adds
/// `ConnectionsProvider` (`proc_pidfdinfo`, `lsof` fallback) and the stat
/// tiles, filter chips, per-process socket table, and detail panel.
struct ConnectionsPage: View {
    @State private var searchText = ""

    var body: some View {
        PlaceholderPageView(
            page: .connections,
            detail: "Stat tiles, filter chips, and a per-process socket table with a detail panel."
        )
        .pageToolbar(searchText: $searchText, searchPrompt: "Filter Connections")
    }
}

#Preview {
    ConnectionsPage()
}
