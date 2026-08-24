import SwiftUI

/// System Info catalog — PLAN.md §1.1 "System Info (three-section
/// catalog, like System Profiler)" / §4 M5. Placeholder until M5 adds
/// `SystemInfoProvider` (`system_profiler -json`, cached with a Reload
/// action) and the Hardware/Network/Software catalog with its key-value
/// detail pane.
struct SystemInfoPage: View {
    var body: some View {
        PlaceholderPageView(
            page: .systemInfo,
            detail: "Hardware/Network/Software catalog sourced from system_profiler, with a key-value detail pane."
        )
    }
}

#Preview {
    SystemInfoPage()
}
