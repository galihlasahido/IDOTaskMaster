import SwiftUI

/// Native replacement for [name removed]'s glowing instrument status bar — PLAN.md
/// §4 M1's `PageInfoBar`, anchored to the bottom of every page
/// (PLAN.md §3: `AppShell.swift # sidebar nav, page routing, bottom info
/// bar`). [name removed]'s version (§1.1: "Bottom status bar: provider health
/// ('1 provider degraded'), live process count, data 'Generation' counter,
/// record indicator + timecode (00:00:00.00) on the right") is trimmed per
/// §2's design decisions: the record light/timecode are dropped outright
/// ("Dropped from [name removed]: ... record light/timecode"), and what remains
/// stops being an instrument panel — "provider-health/generation info
/// moves to a subtle line there" — so this renders as one quiet
/// secondary-text line rather than a lit status strip.
///
/// Pure like its `Components/` siblings (`StatTile`, `DetailPane`,
/// `DataTable`, `CapacityBar`): it only knows how to lay out whatever
/// health/process-count/generation values it's given, with no dependency
/// on `Core`'s `Snapshot`/`ProviderHealth` types. Nothing about *where*
/// those numbers come from belongs here — today `AppShell` has no live
/// `Sampler` to read from (`SettingsStore`'s note: "no milestone has wired
/// a live `Sampler` instance into the app yet"), so it hands this view the
/// honest all-`nil`/zero defaults below; once a page owns a live snapshot
/// stream, it feeds the same view real numbers with no change needed here.
struct PageInfoBar: View {
    /// Providers reporting `.degraded` as of the most recent snapshot —
    /// `Snapshot.degradedProviderCount`. Meaningless while
    /// `totalProviderCount` is `0` (nothing has reported in yet).
    var degradedProviderCount: Int = 0
    /// Total providers known this tick — `Snapshot.providersHealth.count`.
    /// `0` is the honest M0/M1 state (`Sampler` publishes an always-empty
    /// `providersHealth` until M2's providers exist), read as "no
    /// providers active" rather than as "0 of 0 providers are healthy".
    var totalProviderCount: Int = 0
    /// Live process count, e.g. for "312 processes". `nil` reads as
    /// "Unavailable" (dimmed, matching every other honest-degradation
    /// reading in this app) rather than a guessed or zeroed count — the
    /// correct state until M4's `ProcessProvider` exists.
    var processCount: Int? = nil
    /// `Sampler`'s tick counter (PLAN.md §1.1's "data 'Generation'
    /// counter"). `nil` before any live snapshot has been observed.
    var generation: UInt64? = nil

    var body: some View {
        HStack(spacing: 12) {
            healthLabel
            fieldDivider
            processLabel
            Spacer(minLength: 8)
            generationLabel
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        // Same dynamic, appearance-tracking tokens `DataTable`'s header
        // and `HistoryGraph`'s frame use for their own chrome — no custom
        // hex values here either — with a top hairline separating the bar
        // from the page content above it, the same role `DataTable`'s
        // `Divider()` plays between its header and rows.
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) {
            Divider()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Health

    private var healthLabel: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(healthColor)
                .frame(width: 6, height: 6)
            Text(healthText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var healthColor: Color {
        guard totalProviderCount > 0 else { return StatusPalette.unavailable }
        return degradedProviderCount > 0 ? StatusPalette.warning : StatusPalette.healthy
    }

    private var healthText: String {
        guard totalProviderCount > 0 else { return "No providers active" }
        guard degradedProviderCount > 0 else { return "All providers OK" }
        return degradedProviderCount == 1 ? "1 provider degraded" : "\(degradedProviderCount) providers degraded"
    }

    // MARK: - Process count

    private var processLabel: some View {
        Text(processText)
            .foregroundStyle(processCount == nil ? Color(nsColor: .tertiaryLabelColor) : .secondary)
            .monospacedDigit()
            .lineLimit(1)
    }

    private var processText: String {
        guard let processCount else { return "Processes: Unavailable" }
        return processCount == 1 ? "1 process" : "\(processCount) processes"
    }

    // MARK: - Generation

    private var generationLabel: some View {
        Text(generationText)
            .foregroundStyle(generation == nil ? Color(nsColor: .tertiaryLabelColor) : .secondary)
            .monospacedDigit()
            .lineLimit(1)
    }

    private var generationText: String {
        guard let generation else { return "Generation —" }
        return "Generation \(generation)"
    }

    // MARK: - Shared

    private var fieldDivider: some View {
        Divider().frame(height: 10)
    }
}

// MARK: - Previews

#Preview("All OK") {
    PageInfoBar(
        degradedProviderCount: 0,
        totalProviderCount: 9,
        processCount: 312,
        generation: 4821
    )
    .frame(width: 520)
}

#Preview("Degraded provider") {
    PageInfoBar(
        degradedProviderCount: 1,
        totalProviderCount: 9,
        processCount: 312,
        generation: 4821
    )
    .frame(width: 520)
}

#Preview("No live data yet (M0/M1 default)") {
    PageInfoBar()
        .frame(width: 520)
}
