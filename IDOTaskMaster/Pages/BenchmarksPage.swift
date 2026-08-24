import SwiftUI

/// Benchmarks page — PLAN.md §1.1 "Benchmarks" (a former [name removed] Pro page,
/// unlocked here per §2) / §4 M7. Placeholder until M7 adds the CPU/GPU/
/// Disk/Internet benchmark runners, native run-progress UI, the results
/// history table, and the aggregate score page.
struct BenchmarksPage: View {
    var body: some View {
        PlaceholderPageView(
            page: .benchmarks,
            detail: "CPU/GPU/Disk/Internet benchmarks with native progress, a results history table, and an aggregate score."
        )
    }
}

#Preview {
    BenchmarksPage()
}
