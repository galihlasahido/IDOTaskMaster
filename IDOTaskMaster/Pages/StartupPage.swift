import SwiftUI

/// Startup apps page — PLAN.md §1.1 "Startup apps" / §4 M5. Placeholder
/// until M5 adds `StartupProvider` (LaunchAgents/Daemons plist scan +
/// `launchctl` state) and the enabled-state table with its detail pane.
///
/// Search-only `PageToolbar`, same reasoning as `ServicesPage`: a filter
/// box per PLAN.md §1.1, no process-style quit/inspect actions.
struct StartupPage: View {
    @State private var searchText = ""

    var body: some View {
        PlaceholderPageView(
            page: .startup,
            detail: "Launch agent/daemon table with enabled state and a detail pane."
        )
        .pageToolbar(searchText: $searchText, searchPrompt: "Filter Startup Items")
    }
}

#Preview {
    StartupPage()
}
