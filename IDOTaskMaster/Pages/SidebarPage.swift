import SwiftUI

/// Identifies one navigable page and its sidebar row — PLAN.md §3's
/// `AppShell.swift # sidebar nav, page routing` and §4 M1's "Native
/// sidebar shell with all pages routed."
///
/// Cases and order follow PLAN.md §1.1's researched sidebar inventory
/// ("Summary, Performance, Processes, System Info, Startup apps, Users,
/// Services — then a 'PRO' divider — Power & Freq, Connections,
/// Installed Apps, Disk Space, Benchmarks") plus this app's own
/// additions beyond that baseline from §2 ("menu bar extra ... persistent
/// history ... per-process network traffic" → History, Alerts, Network
/// Usage), placed in the architecture tree's §3 `Pages/` order (Network
/// Usage grouped with the formerly-paywalled tools rather than off on
/// its own).
///
/// Settings is intentionally not a case here — see `AppShell`'s doc
/// comment on why it gets its own fixed sidebar footer instead of a row
/// in this list.
enum SidebarPage: String, CaseIterable, Identifiable, Hashable {
    case summary
    case performance
    case processes
    case systemInfo
    case startup
    case users
    case services
    case powerFreq
    case connections
    case networkUsage
    case installedApps
    case diskSpace
    case cleanup
    case benchmarks
    case history
    case alerts

    var id: String { rawValue }

    /// Sidebar row / navigation-title label.
    var title: String {
        switch self {
        case .summary: "Summary"
        case .performance: "Performance"
        case .processes: "Processes"
        case .systemInfo: "System Info"
        case .startup: "Startup Apps"
        case .users: "Users"
        case .services: "Services"
        case .powerFreq: "Power & Freq"
        case .connections: "Connections"
        case .networkUsage: "Network Usage"
        case .installedApps: "Installed Apps"
        case .diskSpace: "Disk Space"
        case .cleanup: "Clean Up"
        case .benchmarks: "Benchmarks"
        case .history: "History"
        case .alerts: "Alerts"
        }
    }

    /// SF Symbol for the sidebar row. Plain monochrome glyphs, matching
    /// Activity Monitor's own sidebar/tab icons — `DomainPalette`'s
    /// per-domain colors are reserved for graphs and meters, not nav
    /// chrome (PLAN.md §2).
    var systemImage: String {
        switch self {
        case .summary: "gauge"
        case .performance: "chart.line.uptrend.xyaxis"
        case .processes: "list.bullet.rectangle"
        case .systemInfo: "info.circle"
        case .startup: "power"
        case .users: "person.2"
        case .services: "gearshape.2"
        case .powerFreq: "bolt"
        case .connections: "network"
        case .networkUsage: "arrow.up.arrow.down.circle"
        case .installedApps: "square.grid.2x2"
        case .diskSpace: "internaldrive"
        case .cleanup: "trash.circle"
        case .benchmarks: "speedometer"
        case .history: "clock.arrow.circlepath"
        case .alerts: "bell"
        }
    }

    /// The milestone that fills in this page's real content, e.g. "M2" —
    /// sourced from PLAN.md §4's checklist. Feeds `PlaceholderPageView`'s
    /// "arrives in M_" line so every placeholder cites the right
    /// milestone without each `Pages/*Page.swift` file hard-coding its
    /// own copy of this mapping.
    var buildMilestone: String {
        switch self {
        case .summary: "M3"
        case .performance: "M2"
        case .processes, .users: "M4"
        case .systemInfo, .startup, .services: "M5"
        case .powerFreq, .connections, .installedApps, .diskSpace: "M6"
        case .benchmarks: "M7"
        case .networkUsage, .history, .alerts: "M9"
        // Added after the original M0–M11 plan shipped, so there's no
        // matching milestone number — `PlaceholderPageView` (the only
        // consumer of this property) is itself unused now that every page
        // has real content, so this case only exists to keep the switch
        // exhaustive.
        case .cleanup: "post-1.0"
        }
    }

    /// The two sidebar groups, split by PLAN.md §2's neutral "Tools"
    /// divider — this app's flat-list, everything-unlocked take on a
    /// branded "PRO" divider (one flat nav list, or a neutral "Tools"
    /// divider for the same visual rhythm). `isToolsSection` pages are
    /// exactly the formerly-paywalled pages (Power & Freq, Connections,
    /// Installed Apps, Disk Space, Benchmarks) plus this app's own
    /// additions beyond that baseline that belong in the same second
    /// group (History, Alerts, Network Usage, Clean Up).
    var isToolsSection: Bool {
        switch self {
        case .powerFreq, .connections, .networkUsage, .installedApps, .diskSpace, .cleanup, .benchmarks, .history, .alerts:
            true
        case .summary, .performance, .processes, .systemInfo, .startup, .users, .services:
            false
        }
    }

    /// `allCases` before the "Tools" divider, in sidebar order.
    static var mainPages: [SidebarPage] { allCases.filter { !$0.isToolsSection } }

    /// `allCases` after the "Tools" divider, in sidebar order.
    static var toolPages: [SidebarPage] { allCases.filter(\.isToolsSection) }
}
