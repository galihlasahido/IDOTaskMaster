import SwiftUI

/// Performance master-detail page — PLAN.md §1.1 "Performance
/// (master-detail)" / §4 M2, the heart of the app. Placeholder until M2
/// adds the sparkline rail and per-domain detail layouts backed by
/// `CPUProvider`, `MemoryProvider`, `GPUProvider`, `DiskProvider`,
/// `NetworkProvider`, `EnergyProvider`, `ThermalProvider`, `NPUProvider`.
struct PerformancePage: View {
    var body: some View {
        PlaceholderPageView(
            page: .performance,
            detail: "Sparkline rail and per-domain detail stats (CPU, Memory, GPU, Disk, Network, Energy, Thermals, NPU)."
        )
    }
}

#Preview {
    PerformancePage()
}
