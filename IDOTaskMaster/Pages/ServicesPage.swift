import SwiftUI

/// Services page — PLAN.md §1.1 "Services" / §4 M5. Placeholder until
/// M5 adds `ServicesProvider` (`launchctl print` listing) and the
/// running-state table with its detail pane.
///
/// Search-only `PageToolbar` — PLAN.md §1.1 lists a "filter" box for this
/// page but no quit/inspect-style row actions, so `showsProcessActions`
/// stays at its default `false`.
struct ServicesPage: View {
    @State private var searchText = ""

    var body: some View {
        PlaceholderPageView(
            page: .services,
            detail: "LaunchDaemons/agents table with running state and a detail pane."
        )
        .pageToolbar(searchText: $searchText, searchPrompt: "Filter Services")
    }
}

#Preview {
    ServicesPage()
}
