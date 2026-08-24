import SwiftUI

/// Power & Freq page — PLAN.md §1.1 "Power & Freq" (a former [name removed] Pro
/// page, unlocked here per §2) / §4 M6. Placeholder until M6 adds the
/// HWiNFO-style sensor tree (machine → CPU → Temperatures/Powers/
/// Utilization/Clocks; GPU; SSD) with Value/Min/Max columns.
struct PowerFreqPage: View {
    var body: some View {
        PlaceholderPageView(
            page: .powerFreq,
            detail: "HWiNFO-style sensor tree (CPU, GPU, SSD) with Value/Min/Max columns."
        )
    }
}

#Preview {
    PowerFreqPage()
}
