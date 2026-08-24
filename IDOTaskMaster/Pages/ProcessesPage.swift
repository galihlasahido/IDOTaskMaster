import SwiftUI

/// Processes page — PLAN.md §1.1 "Processes" / §4 M4. Placeholder until
/// M4 adds `ProcessProvider` and the `NSOutlineView`-backed grouped tree
/// (Applications / Background processes) with its detail pane and
/// quit/force-quit actions.
///
/// Already wears M1's `PageToolbar` (search field + ⓧ Quit Process / ⓘ
/// Inspect), the exact pattern PLAN.md §4 M1 names Processes' own toolbar
/// after ("Activity Monitor's ⓧ quit-process, ⓘ inspect pattern"). Both
/// buttons pass `nil` actions — honestly disabled, matching
/// `PlaceholderPageView`'s "not built yet" body — until M4's
/// `ProcessProvider` and outline-view selection exist to drive them.
struct ProcessesPage: View {
    @State private var searchText = ""

    var body: some View {
        PlaceholderPageView(
            page: .processes,
            detail: "Grouped Applications/Background process tree with sortable columns and a detail pane."
        )
        .pageToolbar(
            searchText: $searchText,
            searchPrompt: "Filter Processes",
            showsProcessActions: true
        )
    }
}

#Preview {
    ProcessesPage()
}
