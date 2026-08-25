import SwiftUI

/// Native-styled summary card — PLAN.md §4's `StatTile`, reused across two
/// different layouts described in §1.1:
///
/// - Summary's bottom tile grid: "mini LED-bar cards: Disks (R/W speed,
///   % active), Network (S/R rate), Energy (watts, thermal/power state),
///   GPU 0 (model, %), NPU 0 (status), Thermals (°C)" — static cards, one
///   per domain, each pairing a headline reading with an embedded
///   `CapacityBar`.
/// - Performance's master-detail left rail: "selectable mini-cards with
///   live sparkline thumbnails for CPU, Memory, GPU 0, NPU 0, Disks,
///   Network, Energy, Thermals; each shows current headline stats" — the
///   same card shape, made selectable and embedding a `HistoryGraph`
///   sparkline instead of a bar.
///
/// Like its siblings (`HistoryGraph`, `CapacityBar`, `DataTable`),
/// `StatTile` is pure: it only knows how to lay out a title, a headline
/// reading, and optional secondary text/embedded content across its
/// available width. Nothing about *where* the reading comes from —
/// `Sampler`'s live stream, a `HistoryStore` query — belongs here.
///
/// Generic over an embedded `Content` view the same way `DataTableColumn`
/// is generic over a cell view, so a Summary tile can embed a
/// `CapacityBar` and a Performance rail card can embed a `HistoryGraph`
/// without `StatTile` needing to know about either. Tiles with nothing to
/// embed (e.g. an NPU tile before `NPUProvider` exists) use the
/// `Content == EmptyView` convenience initializer below.
struct StatTile<Content: View>: View {
    var title: String
    /// SF Symbol name shown beside `title`, e.g. "cpu" or "memorychip".
    var systemImage: String
    /// Per-domain identity color (a `DomainPalette` token) tinting the
    /// icon — a native, non-glowing take on LED-style color coding
    /// (PLAN.md §2).
    var color: Color
    /// The tile's big headline reading, e.g. "42%" or "128 MB/s". Already
    /// formatted by the caller — `StatTile` does no numeric formatting of
    /// its own, matching `CapacityBar`'s `valueLabel` convention.
    var value: String
    /// A second, smaller line under `value`, e.g. "14 cores" or
    /// "Apple M4 · Auto". `nil` omits it.
    var secondaryText: String? = nil
    /// Set when this tile's provider is `.degraded` this tick. Per
    /// PLAN.md's "honest degradation" rule, `value`/`secondaryText` are
    /// replaced with an explicit "Unavailable" reading (dimmed, matching
    /// `CapacityBar.isUnavailable`) rather than showing a stale or zeroed
    /// number.
    var isUnavailable: Bool = false
    /// Highlights the tile as the current selection on Performance's rail
    /// (PLAN.md §1.1's "selectable mini-cards"). Summary's static grid
    /// tiles leave this `false`.
    var isSelected: Bool = false
    /// `nil` renders a static, non-interactive card (Summary's grid).
    /// Set to make the tile selectable (Performance's rail, which taps a
    /// card to change the detail view).
    var action: (() -> Void)? = nil
    /// Embedded per-tick visual: a `CapacityBar` on Summary, a
    /// `HistoryGraph` sparkline on Performance's rail, or nothing.
    let content: Content

    init(
        title: String,
        systemImage: String,
        color: Color,
        value: String,
        secondaryText: String? = nil,
        isUnavailable: Bool = false,
        isSelected: Bool = false,
        action: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
        self.value = value
        self.secondaryText = secondaryText
        self.isUnavailable = isUnavailable
        self.isSelected = isSelected
        self.action = action
        self.content = content()
    }

    var body: some View {
        Group {
            if let action {
                Button(action: action) { card }
                    .buttonStyle(.plain)
            } else {
                card
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValueText)
        .accessibilityAddTraits(accessibilityTraits)
    }

    private var accessibilityTraits: AccessibilityTraits {
        isSelected ? [.updatesFrequently, .isSelected] : [.updatesFrequently]
    }

    // MARK: - Card

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Text(isUnavailable ? "Unavailable" : value)
                .font(.title3)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(isUnavailable ? .secondary : .primary)
                .lineLimit(1)
            if let secondaryText, !isUnavailable {
                Text(secondaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // `NSColor.controlBackgroundColor` / `.separatorColor` match the
        // dynamic tokens `HistoryGraph` and `CapacityBar` use for their
        // own chrome — no custom hex values here either. Selection uses
        // the system accent color, the same visual language as a
        // selected `List`/`NSOutlineView` row.
        .background(shape.fill(isSelected ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor)))
        .overlay(shape.strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2 : 1))
        .opacity(isUnavailable ? 0.65 : 1)
        .clipShape(shape)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isUnavailable ? Color(nsColor: .tertiaryLabelColor) : color)
                .frame(width: 14)
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var accessibilityValueText: String {
        if isUnavailable { return "Unavailable" }
        if let secondaryText { return "\(value), \(secondaryText)" }
        return value
    }
}

extension StatTile where Content == EmptyView {
    /// Convenience for a tile with no embedded bar/sparkline — e.g. a
    /// domain whose provider only has a headline reading so far.
    init(
        title: String,
        systemImage: String,
        color: Color,
        value: String,
        secondaryText: String? = nil,
        isUnavailable: Bool = false,
        isSelected: Bool = false,
        action: (() -> Void)? = nil
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            color: color,
            value: value,
            secondaryText: secondaryText,
            isUnavailable: isUnavailable,
            isSelected: isSelected,
            action: action,
            content: { EmptyView() }
        )
    }
}

// MARK: - Previews

#Preview("Summary tile grid") {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
        StatTile(
            title: "Disks",
            systemImage: "internaldrive",
            color: DomainPalette.diskRead,
            value: "212 MB/s",
            secondaryText: "18% active"
        ) {
            CapacityBar(value: 18, color: DomainPalette.diskRead, accessibilityLabel: "Disk activity")
        }
        StatTile(
            title: "Network",
            systemImage: "network",
            color: DomainPalette.networkIn,
            value: "4.2 MB/s",
            secondaryText: "↓ 3.8 · ↑ 0.4 MB/s"
        ) {
            CapacityBar(value: 42, color: DomainPalette.networkIn, accessibilityLabel: "Network throughput")
        }
        StatTile(
            title: "Energy",
            systemImage: "bolt.fill",
            color: DomainPalette.energy,
            value: "12.4 W",
            secondaryText: "No thermal pressure"
        )
        StatTile(
            title: "NPU 0",
            systemImage: "cpu",
            color: DomainPalette.npu,
            value: "",
            isUnavailable: true
        )
    }
    .padding()
    .frame(width: 460)
}

private let statTilePreviewSparkline: [Double?] = (0..<40).map { i in 30 + 20 * sin(Double(i) / 4) }

private struct StatTileRailPreview: View {
    @State private var selectedID = "cpu"

    var body: some View {
        VStack(spacing: 8) {
            StatTile(
                title: "CPU",
                systemImage: "cpu",
                color: DomainPalette.cpuUser,
                value: "38%",
                secondaryText: "14 cores",
                isSelected: selectedID == "cpu",
                action: { selectedID = "cpu" }
            ) {
                HistoryGraph(
                    series: [HistoryGraphSeries(id: "cpu", color: DomainPalette.cpuUser, values: statTilePreviewSparkline)],
                    gridLineCount: 0,
                    accessibilityLabel: "CPU history"
                )
                .frame(height: 32)
            }
            StatTile(
                title: "Memory",
                systemImage: "memorychip",
                color: DomainPalette.memoryPressureNormal,
                value: "18.2 GB",
                secondaryText: "of 36 GB",
                isSelected: selectedID == "memory",
                action: { selectedID = "memory" }
            ) {
                HistoryGraph(
                    series: [HistoryGraphSeries(id: "mem", color: DomainPalette.memoryPressureNormal, values: statTilePreviewSparkline)],
                    gridLineCount: 0,
                    accessibilityLabel: "Memory history"
                )
                .frame(height: 32)
            }
        }
        .padding()
        .frame(width: 220)
    }
}

#Preview("Performance rail (selectable)") {
    StatTileRailPreview()
}
