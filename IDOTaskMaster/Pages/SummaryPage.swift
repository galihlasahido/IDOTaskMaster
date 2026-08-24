import SwiftUI

/// Summary dashboard — PLAN.md §1.1 "Summary (dashboard)" / §4 M3.
/// Placeholder until M3 fills in the CPU/Temp/GPU meters, CPU Overview
/// card, top CPU processes table, and bottom tile grid.
struct SummaryPage: View {
    var body: some View {
        PlaceholderPageView(
            page: .summary,
            detail: "Compact CPU/Temp/GPU capacity bars, a CPU Overview card, the top CPU processes table, and the memory/tile grid."
        )
    }
}

#Preview {
    SummaryPage()
}
