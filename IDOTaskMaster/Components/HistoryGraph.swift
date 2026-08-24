import SwiftUI

/// One plotted line/fill within a `HistoryGraph`, e.g. the "user" and
/// "system" traces on Activity Monitor's CPU tab (PLAN.md §2: "Graphs:
/// Activity Monitor-style history charts — flat filled area over a light
/// grid, thin stroke, no glow/bloom ... CPU system-blue/red for
/// user/system like Activity Monitor, ... Network blue/red for in/out,
/// Disk blue/red for read/write").
///
/// `values` holds one entry per tick, oldest first, newest last — the same
/// order a ring buffer in the not-yet-built `Core/History.swift` will
/// produce once M2's providers exist. `HistoryGraph` itself takes plain
/// arrays rather than depending on that type so it can be built, previewed,
/// and reused (Summary tiles, Performance detail graphs, the future History
/// page) before any provider exists to feed it.
struct HistoryGraphSeries: Identifiable {
    let id: String
    let color: Color
    /// `nil` marks a tick a provider couldn't sample — a Sampler cycle
    /// where that domain's `ProviderHealth` was `.degraded` — leaving a gap
    /// in both the stroke and the fill rather than interpolating or
    /// guessing a value. This is `HistoryGraph`'s half of PLAN.md's
    /// "honest degradation" rule; the numeric "Unavailable" label a page
    /// pairs with the graph is that caller's responsibility.
    var values: [Double?]
    /// Whether the area under this series is filled. Activity Monitor
    /// fills a tab's primary trace solidly but sometimes only strokes a
    /// secondary reference line; defaults to `true`.
    var isFilled: Bool = true

    init(id: String, color: Color, values: [Double?], isFilled: Bool = true) {
        self.id = id
        self.color = color
        self.values = values
        self.isFilled = isFilled
    }
}

/// Activity Monitor-style filled-area history chart, drawn with `Canvas`
/// per PLAN.md §2/§3 ("`Canvas` for the history graphs (Activity
/// Monitor-style filled area charts)"). Renders one or more
/// `HistoryGraphSeries` over a light horizontal grid with a thin stroke and
/// a soft gradient fill — no glow/bloom, matching the native look PLAN.md
/// §2 calls for instead of [name removed]'s phosphor traces.
///
/// Pure and stateless: it only knows how to lay out whatever samples it is
/// given across its available width. Anything about *where* those samples
/// come from — a live `Sampler` stream, a `HistoryStore` 24h/7d query —
/// belongs to the caller; this view is reused unchanged by every page that
/// plots a metric over time (PLAN.md §3 `Components/HistoryGraph.swift`).
struct HistoryGraph: View {
    /// Backs Settings ▸ Graphs' "Compress Older History" option (PLAN.md
    /// §1.1: "Compress Older History (+ history multiplier, e.g. 15× with
    /// smooth time compression)"). The most recent `recentWindow` samples
    /// are laid out at full, uniform (1×) spacing; every older sample is
    /// laid out at `1 / multiplier` of that spacing, so long history
    /// compresses smoothly toward the left edge while recent activity —
    /// what a user is actually watching — keeps full resolution on the
    /// right. `nil` (the default, via `HistoryGraph.compression`) disables
    /// this and spaces every sample uniformly across the full width, which
    /// is the correct behavior for a graph that already only holds as much
    /// history as its width can show one-to-one (e.g. a live Performance
    /// detail graph before `HistoryStore` exists).
    struct HistoryCompression: Equatable {
        /// Newest samples kept at uniform, uncompressed spacing.
        var recentWindow: Int
        /// How many older samples' worth of horizontal space one
        /// compressed sample occupies. Values `<= 1` are treated as "no
        /// compression" (the linear layout is used).
        var multiplier: Double

        /// [name removed]'s own default, quoted in PLAN.md §1.1.
        static let standard = HistoryCompression(recentWindow: 60, multiplier: 15)
    }

    let series: [HistoryGraphSeries]
    /// The value range mapped to the chart's full height. Values outside
    /// this range are clamped rather than drawn off-canvas — callers with
    /// domains that can exceed a nominal range (e.g. CPU briefly reporting
    /// slightly over 100% across cores) should size this generously rather
    /// than rely on clamping to look right.
    var valueRange: ClosedRange<Double> = 0...100
    /// Horizontal grid lines to draw, including the top and bottom edges
    /// (so `4` draws 5 lines: 0%, 25%, 50%, 75%, 100%). `0` disables the
    /// grid entirely.
    var gridLineCount: Int = 4
    /// `nil` (default) lays every sample out at uniform spacing. See
    /// `HistoryCompression`.
    var compression: HistoryCompression? = nil
    /// Accessibility summary read in place of the (otherwise purely
    /// visual) chart, e.g. "CPU history, 42 percent user, 8 percent
    /// system". Callers should include the latest reading here since a
    /// screen-reader user cannot otherwise recover it from the drawing.
    var accessibilityLabel: String = "History graph"

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            drawGrid(context: context, rect: rect)
            for oneSeries in series {
                drawSeries(oneSeries, context: context, rect: rect)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Grid

    private func drawGrid(context: GraphicsContext, rect: CGRect) {
        guard gridLineCount > 0 else { return }
        var path = Path()
        for step in 0...gridLineCount {
            let y = rect.minY + rect.height * CGFloat(step) / CGFloat(gridLineCount)
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        // `NSColor.gridColor` is AppKit's own dynamic color for exactly
        // this purpose (table/outline view grid lines), so it already
        // tracks light/dark and increased-contrast the way the rest of
        // `DomainPalette`'s tokens do — no custom hex value needed here
        // either.
        context.stroke(path, with: .color(Color(nsColor: .gridColor)), lineWidth: 1)
    }

    // MARK: - Series

    private func drawSeries(_ oneSeries: HistoryGraphSeries, context: GraphicsContext, rect: CGRect) {
        let values = oneSeries.values
        guard values.count > 1 else { return }
        let xPositions = xFractions(count: values.count).map { rect.minX + $0 * rect.width }

        // Split into contiguous runs of non-nil samples so a gap left by a
        // degraded provider tick breaks the line instead of being bridged
        // by an interpolated (i.e. guessed) segment.
        var runStart: Int? = nil
        for index in 0...values.count {
            let isValid = index < values.count && values[index] != nil
            if isValid {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                drawRun(
                    oneSeries,
                    values: values,
                    xPositions: xPositions,
                    range: start..<index,
                    context: context,
                    rect: rect
                )
                runStart = nil
            }
        }
    }

    private func drawRun(
        _ oneSeries: HistoryGraphSeries,
        values: [Double?],
        xPositions: [CGFloat],
        range: Range<Int>,
        context: GraphicsContext,
        rect: CGRect
    ) {
        // A single isolated sample can't draw a line segment; skip it
        // rather than plotting a stray dot.
        guard range.count > 1 else { return }

        var linePath = Path()
        var fillPath = Path()
        var lastPoint: CGPoint? = nil
        for index in range {
            guard let value = values[index] else { continue }
            let point = CGPoint(x: xPositions[index], y: yPosition(for: value, in: rect))
            if lastPoint == nil {
                linePath.move(to: point)
                fillPath.move(to: CGPoint(x: point.x, y: rect.maxY))
                fillPath.addLine(to: point)
            } else {
                linePath.addLine(to: point)
                fillPath.addLine(to: point)
            }
            lastPoint = point
        }
        guard let lastPoint else { return }
        fillPath.addLine(to: CGPoint(x: lastPoint.x, y: rect.maxY))
        fillPath.closeSubpath()

        if oneSeries.isFilled {
            context.fill(
                fillPath,
                with: .linearGradient(
                    Gradient(colors: [oneSeries.color.opacity(0.35), oneSeries.color.opacity(0.05)]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                )
            )
        }
        context.stroke(
            linePath,
            with: .color(oneSeries.color),
            style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)
        )
    }

    private func yPosition(for value: Double, in rect: CGRect) -> CGFloat {
        let span = valueRange.upperBound - valueRange.lowerBound
        guard span > 0 else { return rect.maxY }
        let clamped = min(max(value, valueRange.lowerBound), valueRange.upperBound)
        let fraction = (clamped - valueRange.lowerBound) / span
        return rect.maxY - CGFloat(fraction) * rect.height
    }

    // MARK: - Time axis (optional older-history compression)

    /// Returns each sample's horizontal position as a 0...1 fraction of
    /// the chart's width, oldest first. With `compression` set and enough
    /// samples to compress, older samples are packed more tightly than
    /// recent ones (see `HistoryCompression`); otherwise every sample is
    /// spaced uniformly.
    private func xFractions(count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [1] }

        guard
            let compression,
            compression.multiplier > 1,
            count > compression.recentWindow
        else {
            return (0..<count).map { CGFloat($0) / CGFloat(count - 1) }
        }

        // Older samples (before `recentWindow`) each occupy 1/multiplier
        // of a recent sample's horizontal "width". Positioning every
        // sample at the *right* edge of its cumulative-weight slot keeps
        // the newest ("now") sample pinned to the chart's right edge,
        // matching Activity Monitor's live graphs, while the oldest
        // samples crowd toward — without needing to land exactly on —
        // the left edge, more tightly the higher the multiplier.
        let recentWindow = max(1, compression.recentWindow)
        let olderCount = count - recentWindow
        var rightEdges: [Double] = []
        rightEdges.reserveCapacity(count)
        var running = 0.0
        for index in 0..<count {
            let weight = index < olderCount ? (1.0 / compression.multiplier) : 1.0
            running += weight
            rightEdges.append(running)
        }
        let total = running
        return rightEdges.map { CGFloat($0 / total) }
    }
}

private func previewWave(count: Int, amplitude: Double, period: Double, phase: Double, midpoint: Double, gapAt: Int? = nil) -> [Double?] {
    var samples: [Double?] = []
    samples.reserveCapacity(count)
    for i in 0..<count {
        if let gapAt, i == gapAt {
            samples.append(nil)
        } else {
            let radians: Double = Double(i) / period + phase
            let sample: Double = midpoint + amplitude * sin(radians)
            samples.append(sample)
        }
    }
    return samples
}

#Preview("Uncompressed") {
    let userValues = previewWave(count: 120, amplitude: 30, period: 8, phase: 0, midpoint: 40, gapAt: 40)
    let systemValues = previewWave(count: 120, amplitude: 8, period: 5, phase: 2, midpoint: 10)
    HistoryGraph(
        series: [
            HistoryGraphSeries(id: "user", color: DomainPalette.cpuUser, values: userValues),
            HistoryGraphSeries(id: "system", color: DomainPalette.cpuSystem, values: systemValues),
        ],
        accessibilityLabel: "CPU history, 62 percent user, 14 percent system"
    )
    .frame(width: 480, height: 160)
    .padding()
}

#Preview("Compressed older history") {
    let combinedValues = previewWave(count: 600, amplitude: 15, period: 12, phase: 0, midpoint: 20)
    HistoryGraph(
        series: [
            HistoryGraphSeries(id: "combined", color: DomainPalette.networkIn, values: combinedValues)
        ],
        compression: .standard,
        accessibilityLabel: "Network history, compressed older samples"
    )
    .frame(width: 480, height: 160)
    .padding()
}
