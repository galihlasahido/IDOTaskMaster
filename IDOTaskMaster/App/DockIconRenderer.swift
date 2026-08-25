import AppKit
import Combine
import SwiftUI

/// Renders the Dock icon as a live graph, mirroring Activity Monitor's
/// View ▸ Dock Icon menu — PLAN.md §3's `DockIconRenderer.swift # Dock icon
/// live graph (NSApp.dockTile)` and §4 M8's fourth task: "Dock icon live
/// graph (View → Dock Icon: CPU history etc., like Activity Monitor)".
///
/// Reuses `MenuBarStatusModel`'s already-running `Sampler` and short
/// history buffers (`cpu.total`, `memory.usedPercent`) rather than starting
/// a second one — the Dock icon needs exactly the same "live while the main
/// window is closed" guarantee the menu bar extra already has (both are
/// owned by `AppDelegate` for the whole process lifetime), and at Dock icon
/// size a second, independently-ticking sampler would just be duplicate
/// work for data nobody could tell apart from what's already flowing.
///
/// `SettingsStore.dockIconMode` (View ▸ Dock Icon in `AppCommands`) picks
/// what gets drawn. `.applicationIcon` (the default) restores the bundle's
/// real icon by setting `NSApp.applicationIconImage = nil` — AppKit's own
/// documented way to undo a custom Dock image — rather than this class
/// caching and reapplying the original artwork itself. The other four
/// modes pair CPU/Memory with a scrolling history graph or a single big
/// numeric reading, all drawn from data `MenuBarStatusModel` already
/// samples — no new provider needed for this task.
///
/// Drawing is AppKit (`NSBezierPath`/`NSAttributedString`) rather than the
/// SwiftUI `Canvas` `HistoryGraph` uses: `NSApp.applicationIconImage` wants
/// an `NSImage`, and `NSImage(size:flipped:drawingHandler:)` draws with a
/// plain `NSGraphicsContext`, not a `GraphicsContext`. The history-run
/// splitting below intentionally mirrors `HistoryGraph.drawSeries`'s own
/// logic — a gap left by a degraded provider tick breaks the line instead
/// of being bridged by a guessed segment, the same "honest degradation"
/// contract every other graph in this app follows.
@MainActor
final class DockIconRenderer {
    private let settings: SettingsStore
    private let status: MenuBarStatusModel
    private var cancellable: AnyCancellable?

    /// Square canvas rendered at; the Dock scales it to whatever pixel size
    /// (including Retina) the actual icon needs, same as AppKit does for
    /// the bundled `.icns`.
    private static let canvasSize = NSSize(width: 128, height: 128)
    private static let cornerRadiusFraction: CGFloat = 0.22
    /// How many of `MenuBarStatusModel`'s most recent samples a history
    /// mode plots — shorter than that model's own 60-sample capacity since
    /// a Dock icon's history graph only needs to read as "just happened",
    /// the same reasoning `MenuBarStatusModel`'s own doc comment gives for
    /// keeping its buffers short in the first place.
    private static let historyPointCount = 40

    init(settings: SettingsStore, status: MenuBarStatusModel) {
        self.settings = settings
        self.status = status
    }

    /// Subscribes to both the selected mode and the live data so the Dock
    /// icon redraws whenever either changes. Safe to call more than once;
    /// only the first call attaches the subscription. No `stop()`
    /// counterpart — same lifetime reasoning as `MenuBarStatusModel.start()`
    /// itself (this app's one `AppDelegate`-owned instance runs for the
    /// whole process).
    func start() {
        guard cancellable == nil else { return }
        cancellable = settings.$dockIconMode
            .combineLatest(status.$latest)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode, _ in
                self?.render(mode: mode)
            }
    }

    // MARK: - Rendering

    private func render(mode: SettingsStore.DockIconMode) {
        switch mode {
        case .applicationIcon:
            NSApp.applicationIconImage = nil
        case .cpuHistory:
            applyImage(.history(values: recentValues("cpu.total"), color: DomainPalette.cpuUser))
        case .cpuUsage:
            applyImage(.usage(percent: status.cpuPercent, label: "CPU", color: DomainPalette.cpuUser))
        case .memoryHistory:
            applyImage(.history(values: recentValues("memory.usedPercent"), color: DomainPalette.memoryPressureNormal))
        case .memoryUsage:
            applyImage(.usage(percent: status.memoryPercent, label: "MEM", color: DomainPalette.memoryPressureNormal))
        }
    }

    private func recentValues(_ seriesID: String) -> [Double?] {
        Array(status.history(seriesID).suffix(Self.historyPointCount))
    }

    /// Builds and applies the Dock image for one already-captured reading.
    /// `content` is a plain value (no reference to `self`/`status`/
    /// `settings`), so the drawing handler below never needs to touch
    /// `MainActor`-isolated state — safe regardless of which thread AppKit
    /// ends up invoking it from when it actually paints the Dock icon.
    private func applyImage(_ content: DockIconContent) {
        let image = NSImage(size: Self.canvasSize, flipped: false) { rect in
            Self.drawBackground(in: rect)
            Self.draw(content, in: rect)
            return true
        }
        NSApp.applicationIconImage = image
        NSApp.dockTile.display()
    }

    /// What one rendered Dock icon shows — either mode's data, already read
    /// out of `MenuBarStatusModel` before the drawing handler is built. See
    /// `applyImage(_:)`.
    private enum DockIconContent {
        case history(values: [Double?], color: Color)
        case usage(percent: Double?, label: String, color: Color)
    }

    // MARK: - Drawing (AppKit, no instance state)

    private static func drawBackground(in rect: NSRect) {
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: rect.width * cornerRadiusFraction,
            yRadius: rect.height * cornerRadiusFraction
        )
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        path.fill()
        path.addClip()
    }

    private static func draw(_ content: DockIconContent, in rect: NSRect) {
        switch content {
        case .history(let values, let color):
            drawHistory(values: values, color: color, in: rect)
        case .usage(let percent, let label, let color):
            drawUsage(percent: percent, label: label, color: color, in: rect)
        }
    }

    /// A filled-area history graph across the whole icon — the Dock-icon
    /// counterpart of `HistoryGraph`'s SwiftUI `Canvas` drawing, ported to
    /// `NSBezierPath` since this draws into an `NSImage`. Splits `values`
    /// into contiguous non-`nil` runs exactly like
    /// `HistoryGraph.drawSeries` does, so a gap breaks the line instead of
    /// being bridged.
    private static func drawHistory(values: [Double?], color: Color, in rect: NSRect) {
        guard values.count > 1, values.contains(where: { $0 != nil }) else {
            drawPlaceholderDash(in: rect)
            return
        }

        let count = values.count
        let maxValue = max(values.compactMap { $0 }.max() ?? 1, 1)
        let xPositions = (0..<count).map { rect.minX + rect.width * CGFloat($0) / CGFloat(count - 1) }
        // A little headroom at the top keeps a graph that briefly peaks at
        // its own max from touching the rounded top edge.
        func yPosition(_ value: Double) -> CGFloat {
            let fraction = CGFloat(min(max(value / maxValue, 0), 1))
            return rect.minY + fraction * rect.height * 0.92
        }

        let strokeColor = NSColor(color)
        let fillColor = NSColor(color).withAlphaComponent(0.45)

        var runStart: Int?
        for index in 0...count {
            let isValid = index < count && values[index] != nil
            if isValid {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                drawHistoryRun(
                    values: values,
                    xPositions: xPositions,
                    range: start..<index,
                    yPosition: yPosition,
                    fillColor: fillColor,
                    strokeColor: strokeColor,
                    rect: rect
                )
                runStart = nil
            }
        }
    }

    private static func drawHistoryRun(
        values: [Double?],
        xPositions: [CGFloat],
        range: Range<Int>,
        yPosition: (Double) -> CGFloat,
        fillColor: NSColor,
        strokeColor: NSColor,
        rect: NSRect
    ) {
        // A single isolated sample can't draw a line segment; skip it
        // rather than plotting a stray dot (matches `HistoryGraph.drawRun`).
        guard range.count > 1 else { return }

        let linePath = NSBezierPath()
        let fillPath = NSBezierPath()
        var lastPoint: NSPoint?
        for index in range {
            guard let value = values[index] else { continue }
            let point = NSPoint(x: xPositions[index], y: yPosition(value))
            if lastPoint == nil {
                linePath.move(to: point)
                fillPath.move(to: NSPoint(x: point.x, y: rect.minY))
                fillPath.line(to: point)
            } else {
                linePath.line(to: point)
                fillPath.line(to: point)
            }
            lastPoint = point
        }
        guard let lastPoint else { return }
        fillPath.line(to: NSPoint(x: lastPoint.x, y: rect.minY))
        fillPath.close()

        fillColor.setFill()
        fillPath.fill()

        linePath.lineWidth = 4
        linePath.lineCapStyle = .round
        linePath.lineJoinStyle = .round
        strokeColor.setStroke()
        linePath.stroke()
    }

    /// A big centered percentage with a short domain label beneath it —
    /// the Dock-icon-size counterpart of a `StatTile`'s headline reading,
    /// for the two "Usage" modes (as opposed to the scrolling "History"
    /// modes above). `nil`/non-finite reads as this app's usual honest
    /// "Unavailable" dash rather than a fabricated number.
    private static func drawUsage(percent: Double?, label: String, color: Color, in rect: NSRect) {
        guard let percent, percent.isFinite else {
            drawUnavailable(label: label, in: rect)
            return
        }

        let numberText = "\(Int(percent.rounded()))%"
        let text = twoLineAttributedString(
            headline: numberText,
            headlineColor: NSColor(color),
            label: label,
            in: rect
        )
        drawCentered(text, in: rect)
    }

    private static func drawPlaceholderDash(in rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let font = NSFont.systemFont(ofSize: rect.height * 0.3, weight: .semibold)
        let text = NSAttributedString(string: "—", attributes: [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        drawCentered(text, in: rect)
    }

    private static func drawUnavailable(label: String, in rect: NSRect) {
        let text = twoLineAttributedString(
            headline: "—",
            headlineColor: .tertiaryLabelColor,
            label: label,
            in: rect
        )
        drawCentered(text, in: rect)
    }

    private static func twoLineAttributedString(
        headline: String,
        headlineColor: NSColor,
        label: String,
        in rect: NSRect
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let headlineFont = NSFont.monospacedDigitSystemFont(ofSize: rect.height * 0.4, weight: .bold)
        let labelFont = NSFont.systemFont(ofSize: rect.height * 0.12, weight: .semibold)

        let combined = NSMutableAttributedString(
            string: "\(headline)\n\(label)",
            attributes: [.paragraphStyle: paragraph]
        )
        let headlineRange = NSRange(location: 0, length: (headline as NSString).length)
        combined.addAttributes([.font: headlineFont, .foregroundColor: headlineColor], range: headlineRange)
        let labelRange = NSRange(
            location: (headline as NSString).length + 1,
            length: (label as NSString).length
        )
        combined.addAttributes(
            [.font: labelFont, .foregroundColor: NSColor.white.withAlphaComponent(0.85)],
            range: labelRange
        )
        return combined
    }

    private static func drawCentered(_ text: NSAttributedString, in rect: NSRect) {
        let textSize = text.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin]).size
        let drawRect = NSRect(
            x: rect.minX,
            y: rect.minY + (rect.height - textSize.height) / 2,
            width: rect.width,
            height: textSize.height
        )
        text.draw(in: drawRect)
    }
}
