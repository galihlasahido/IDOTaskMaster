import SwiftUI

/// One shaded portion of a `CapacityBar` — e.g. Activity Monitor's Memory
/// tab splitting its usage bar into App Memory / Wired / Compressed rather
/// than one flat "used" fill, or a future Disk Space bar split by
/// file-type category (PLAN.md §1.1's "File Type legend breakdown").
struct CapacityBarSegment: Identifiable {
    let id: String
    /// Fraction of the bar's full length this segment occupies, 0...1.
    /// Segments are drawn in array order, filling from the bar's leading
    /// (horizontal) or bottom (vertical) edge. If the segments' fractions
    /// sum to more than 1, the overflow is clipped rather than drawn past
    /// the bar's edge — the same "clamp, don't guess" treatment
    /// `HistoryGraph` gives out-of-range values.
    var fraction: Double
    var color: Color
    /// Read into this segment's share of the accessibility value, e.g.
    /// "Wired 22%". Left empty for a single-segment bar, where the
    /// overall `accessibilityLabel` already says what the percentage is.
    var label: String

    init(id: String, fraction: Double, color: Color, label: String = "") {
        self.id = id
        self.fraction = fraction
        self.color = color
        self.label = label
    }
}

/// Native macOS usage/level bar — PLAN.md §2's standard capacity bar /
/// level indicator design ("Meters: standard capacity bars / level
/// indicators instead of LED segment strips"). A flat,
/// pill-shaped track with one or more solid-color fills; no bloom, no
/// discrete lit segments.
///
/// `HistoryGraph` is this component's sibling for *history over time*;
/// `CapacityBar` is for *right now* — reused wherever a page shows a
/// single current reading: Summary's compact CPU/Temp/GPU meters (a
/// vertical layout with values shown below, §1.1, "with values below"),
/// inline usage cells in process/disk tables, and standalone composite
/// meters like Memory's App/Wired/Compressed breakdown.
///
/// Like `HistoryGraph`, this view only knows how to draw whatever it's
/// given across its available space — it takes a cross-axis `thickness`
/// but leaves the main axis for the caller to size via `.frame(...)`.
struct CapacityBar: View {
    enum Orientation {
        case horizontal
        case vertical
    }

    let segments: [CapacityBarSegment]
    var orientation: Orientation = .horizontal
    /// The bar's cross-axis size — height for `.horizontal`, width for
    /// `.vertical`.
    var thickness: CGFloat = 8
    /// Text shown alongside the bar — trailing it when `.horizontal`,
    /// below it when `.vertical` (a vertical meter tower showing its
    /// value below the tower, per PLAN.md §1.1). `nil`
    /// omits the label entirely, e.g. for a compact bar inside a table
    /// cell where the numeric value already has its own column.
    var valueLabel: String? = nil
    /// Set instead of driving `segments` to zero when the metric this bar
    /// represents couldn't be sampled this tick. PLAN.md's "honest
    /// degradation" rule applies to instantaneous meters, not just
    /// `HistoryGraph`'s history gaps: a bar bound to a degraded provider
    /// must not render an empty/0% track, which would misleadingly read
    /// as "measured and idle" rather than "not measured". `true` dims the
    /// track, suppresses any fill regardless of `segments`, and reports
    /// "Unavailable" to accessibility instead of a percentage.
    var isUnavailable: Bool = false
    /// Read by VoiceOver in place of the (otherwise purely visual) bar,
    /// e.g. "CPU usage". Paired with a value derived from `segments` (or
    /// "Unavailable") to form the full accessibility readout.
    var accessibilityLabel: String

    /// Single-fill convenience — the common case of one current value out
    /// of a total, e.g. `CapacityBar(value: cpuPercent, color:
    /// DomainPalette.cpuUser, accessibilityLabel: "CPU usage")`.
    init(
        value: Double,
        total: Double = 100,
        color: Color,
        orientation: Orientation = .horizontal,
        thickness: CGFloat = 8,
        valueLabel: String? = nil,
        isUnavailable: Bool = false,
        accessibilityLabel: String
    ) {
        let fraction = total > 0 ? value / total : 0
        self.segments = [CapacityBarSegment(id: "value", fraction: fraction, color: color)]
        self.orientation = orientation
        self.thickness = thickness
        self.valueLabel = valueLabel
        self.isUnavailable = isUnavailable
        self.accessibilityLabel = accessibilityLabel
    }

    /// Multi-segment initializer for composite bars, e.g. Memory's
    /// App/Wired/Compressed breakdown.
    init(
        segments: [CapacityBarSegment],
        orientation: Orientation = .horizontal,
        thickness: CGFloat = 8,
        valueLabel: String? = nil,
        isUnavailable: Bool = false,
        accessibilityLabel: String
    ) {
        self.segments = segments
        self.orientation = orientation
        self.thickness = thickness
        self.valueLabel = valueLabel
        self.isUnavailable = isUnavailable
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        Group {
            switch orientation {
            case .horizontal:
                HStack(spacing: 6) {
                    bar.frame(height: thickness)
                    label
                }
            case .vertical:
                VStack(spacing: 4) {
                    bar.frame(width: thickness)
                    label
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValueText)
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    private var label: some View {
        if let valueLabel {
            Text(valueLabel)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    // MARK: - Bar drawing

    private var trackShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: thickness / 2, style: .continuous)
    }

    private var bar: some View {
        GeometryReader { geometry in
            ZStack(alignment: orientation == .horizontal ? .leading : .bottom) {
                // `NSColor.controlBackgroundColor` / `.separatorColor` are
                // the same dynamic, appearance-tracking tokens
                // `HistoryGraph` uses for its own track — no custom hex
                // values, matching native controls automatically in light,
                // dark, and increased-contrast.
                trackShape.fill(Color(nsColor: .controlBackgroundColor))
                if !isUnavailable {
                    fillLayer(in: geometry.size)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .clipShape(trackShape)
        .overlay(trackShape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        .opacity(isUnavailable ? 0.5 : 1)
    }

    @ViewBuilder
    private func fillLayer(in size: CGSize) -> some View {
        switch orientation {
        case .horizontal:
            HStack(spacing: 0) {
                ForEach(clampedSegments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: size.width * segment.fraction)
                }
                Spacer(minLength: 0)
            }
        case .vertical:
            // Reversed so the first segment in `segments` lands at the
            // bar's bottom edge and later segments stack upward — the
            // vertical equivalent of the horizontal case's leading-to-
            // trailing fill order.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ForEach(clampedSegments.reversed()) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(height: size.height * segment.fraction)
                }
            }
        }
    }

    /// `segments` with fractions clamped to a non-negative share of the
    /// remaining 0...1 budget, so a caller's overflow clips instead of
    /// spilling past the bar's edge.
    private var clampedSegments: [CapacityBarSegment] {
        var remaining = 1.0
        var result: [CapacityBarSegment] = []
        result.reserveCapacity(segments.count)
        for segment in segments {
            let fraction = max(0, min(segment.fraction, remaining))
            result.append(CapacityBarSegment(id: segment.id, fraction: fraction, color: segment.color, label: segment.label))
            remaining -= fraction
        }
        return result
    }

    private var accessibilityValueText: String {
        if isUnavailable { return "Unavailable" }
        let clamped = clampedSegments
        if clamped.count > 1 {
            return clamped.map { segment in
                let percent = Int((segment.fraction * 100).rounded())
                return segment.label.isEmpty ? "\(percent)%" : "\(segment.label) \(percent)%"
            }.joined(separator: ", ")
        }
        let totalPercent = Int((clamped.reduce(0) { $0 + $1.fraction } * 100).rounded())
        return "\(totalPercent)%"
    }
}

extension CapacityBar {
    /// Maps a 0...1 fraction to `StatusPalette`'s healthy/warning/critical
    /// colors using two thresholds — the pattern behind Activity Monitor's
    /// CPU/Memory bars turning yellow then red as load climbs. Callers
    /// with a fixed per-domain color identity (PLAN.md's CPU blue, Memory
    /// green, ...) should pass that `DomainPalette` color directly
    /// instead; this is for bars whose color should reflect *how
    /// concerning* the level is rather than *which domain* it's in.
    static func statusColor(forFraction fraction: Double, warningAt: Double = 0.7, criticalAt: Double = 0.9) -> Color {
        if fraction >= criticalAt { return StatusPalette.critical }
        if fraction >= warningAt { return StatusPalette.warning }
        return StatusPalette.healthy
    }
}

#Preview("Horizontal") {
    VStack(alignment: .leading, spacing: 16) {
        CapacityBar(
            value: 42,
            color: DomainPalette.cpuUser,
            valueLabel: "42%",
            accessibilityLabel: "CPU usage"
        )
        CapacityBar(
            value: 91,
            color: CapacityBar.statusColor(forFraction: 0.91),
            valueLabel: "91%",
            accessibilityLabel: "Disk capacity"
        )
        CapacityBar(
            segments: [
                CapacityBarSegment(id: "app", fraction: 0.4, color: DomainPalette.memoryPressureNormal, label: "App Memory"),
                CapacityBarSegment(id: "wired", fraction: 0.22, color: DomainPalette.memorySwap, label: "Wired"),
                CapacityBarSegment(id: "compressed", fraction: 0.1, color: DomainPalette.memoryPressureWarning, label: "Compressed"),
            ],
            valueLabel: "72%",
            accessibilityLabel: "Memory used"
        )
        CapacityBar(
            value: 0,
            color: DomainPalette.gpu,
            valueLabel: "—",
            isUnavailable: true,
            accessibilityLabel: "GPU usage"
        )
    }
    .frame(width: 280)
    .padding()
}

#Preview("Vertical towers") {
    HStack(alignment: .bottom, spacing: 20) {
        CapacityBar(
            value: 63,
            color: DomainPalette.cpuUser,
            orientation: .vertical,
            thickness: 14,
            valueLabel: "63%",
            accessibilityLabel: "CPU usage"
        )
        CapacityBar(
            value: 48,
            color: DomainPalette.thermal,
            orientation: .vertical,
            thickness: 14,
            valueLabel: "58°C",
            accessibilityLabel: "Temperature"
        )
        CapacityBar(
            value: 12,
            color: DomainPalette.gpu,
            orientation: .vertical,
            thickness: 14,
            valueLabel: "12%",
            isUnavailable: true,
            accessibilityLabel: "GPU usage"
        )
    }
    .frame(height: 160)
    .padding()
}
