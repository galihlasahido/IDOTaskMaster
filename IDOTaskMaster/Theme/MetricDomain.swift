import SwiftUI

/// Identifies a metric domain covered by the app, mirroring the provider
/// list in PLAN.md §3 (`Providers/`). Later milestones key sidebar rows,
/// history-graph legends, and stat tiles off this enum so every domain's
/// color identity stays centralized in `Theme/` rather than scattered
/// across views.
enum MetricDomain: String, CaseIterable, Identifiable {
    case cpu
    case memory
    case gpu
    case npu
    case disk
    case network
    case energy
    case thermal

    var id: String { rawValue }

    /// Human-readable label, matching the page/section names in
    /// PLAN.md §1.1 (e.g. "Thermals", not "Thermal").
    var displayName: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .npu: "NPU"
        case .disk: "Disk"
        case .network: "Network"
        case .energy: "Energy"
        case .thermal: "Thermals"
        }
    }

    /// Single-value accent for contexts that show this domain as one
    /// series — sidebar icons, Performance-page sparkline thumbnails,
    /// Summary-page mini tiles. Domains with multiple series (e.g. CPU
    /// user/system, Disk read/write) expose those individually via
    /// `DomainPalette` and use this as their "at a glance" color.
    var accentColor: Color {
        switch self {
        case .cpu: DomainPalette.cpuUser
        case .memory: DomainPalette.memoryPressureNormal
        case .gpu: DomainPalette.gpu
        case .npu: DomainPalette.npu
        case .disk: DomainPalette.diskRead
        case .network: DomainPalette.networkIn
        case .energy: DomainPalette.energy
        case .thermal: DomainPalette.thermal
        }
    }
}
