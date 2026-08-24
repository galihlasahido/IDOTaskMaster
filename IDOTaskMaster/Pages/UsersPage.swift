import SwiftUI

/// Users page — PLAN.md §1.1 "Users" / §4 M4. Placeholder until M4 adds
/// the per-user process grouping (status, process count, total CPU,
/// total Memory) built on `ProcessProvider` from the Processes page.
///
/// Carries the same `PageToolbar` process actions as `ProcessesPage` —
/// this page drills into "the same process detail pane" per PLAN.md, so
/// its rows are quit/inspect-able the same way once M4 lands.
struct UsersPage: View {
    @State private var searchText = ""

    var body: some View {
        PlaceholderPageView(
            page: .users,
            detail: "Per-user process grouping with rollups and the same process detail pane."
        )
        .pageToolbar(
            searchText: $searchText,
            searchPrompt: "Filter Users",
            showsProcessActions: true
        )
    }
}

#Preview {
    UsersPage()
}
