import SwiftUI

/// Installed Apps page — PLAN.md §1.1 "Installed Apps" (a former [name removed]
/// Pro page, unlocked here per §2) / §4 M6. Placeholder until M6 adds
/// `InstalledAppsProvider` (/Applications scan, bundle metadata, sizes),
/// the Related Files finder, and the Uninstall action.
struct InstalledAppsPage: View {
    @State private var searchText = ""

    var body: some View {
        PlaceholderPageView(
            page: .installedApps,
            detail: "/Applications scan with sizes, bundle metadata, related files, and uninstall."
        )
        .pageToolbar(searchText: $searchText, searchPrompt: "Filter Installed Apps")
    }
}

#Preview {
    InstalledAppsPage()
}
