import SwiftUI

/// Per-domain color tokens for the macOS palette.
///
/// These wrap AppKit's dynamic system colors (`NSColor.system*`), so every
/// token automatically tracks the user's accent color, light/dark
/// appearance, and increased-contrast accessibility setting the same way
/// Activity Monitor's own UI does — no custom hex values, no [name removed]-style
/// neon/glow (PLAN.md §2 "Design language").
///
/// Tokens are grouped by metric domain and, for domains that plot more
/// than one series, by role within that domain (e.g. CPU user vs. system,
/// Disk read vs. write) — matching Activity Monitor's own per-tab color
/// conventions rather than [name removed]'s flat one-color-per-domain scheme
/// (PLAN.md §2: "CPU system-blue/red for user/system like Activity
/// Monitor, Memory green pressure graph, Network blue/red for in/out,
/// Disk blue/red for read/write").
enum DomainPalette {

    // MARK: - CPU
    // Activity Monitor's CPU tab: blue = user, red = system/kernel,
    // gray = idle.
    static let cpuUser = Color(nsColor: .systemBlue)
    static let cpuSystem = Color(nsColor: .systemRed)
    static let cpuIdle = Color(nsColor: .systemGray)

    // MARK: - Memory
    // Activity Monitor's Memory Pressure gauge: green/yellow/red.
    static let memoryPressureNormal = Color(nsColor: .systemGreen)
    static let memoryPressureWarning = Color(nsColor: .systemYellow)
    static let memoryPressureCritical = Color(nsColor: .systemRed)
    static let memorySwap = Color(nsColor: .systemOrange)

    // MARK: - GPU
    static let gpu = Color(nsColor: .systemIndigo)
    static let gpuSecondary = Color(nsColor: .systemTeal)

    // MARK: - NPU
    // Apple Neural Engine — kept distinct from GPU/CPU/Thermal so a
    // multi-series Summary tile can tell all of them apart at a glance.
    static let npu = Color(nsColor: .systemPurple)

    // MARK: - Disk
    static let diskRead = Color(nsColor: .systemBlue)
    static let diskWrite = Color(nsColor: .systemRed)
    static let diskCapacity = Color(nsColor: .systemGray)

    // MARK: - Network
    static let networkIn = Color(nsColor: .systemBlue)
    static let networkOut = Color(nsColor: .systemRed)

    // MARK: - Energy
    static let energy = Color(nsColor: .systemYellow)
    static let energyBattery = Color(nsColor: .systemGreen)

    // MARK: - Thermal
    static let thermal = Color(nsColor: .systemOrange)
    static let thermalCritical = Color(nsColor: .systemRed)
}
