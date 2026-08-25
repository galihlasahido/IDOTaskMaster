import Foundation

/// One runnable benchmark test — PLAN.md §1.1 "Benchmarks" (unlocked
/// here with no paywall, per §2): "CPU (single/multi core), GPU
/// (compute/graphics), Disk (read/write, choose test folder), Internet
/// (download/upload)." Case order is `BenchmarksPage`'s row order.
///
/// GPU graphics and Internet download/upload aren't split into their own
/// cases: PLAN.md's own architecture tree (§3) lists exactly one runner
/// file per domain — "GPU (Metal compute)", "Internet (URLSession)" — so a
/// GPU run reports both its compute and graphics readings as two
/// `BenchmarkMetric`s under `.gpuCompute`, and an Internet run reports
/// download and upload the same way under `.internetSpeed`, the same
/// two-numbers-one-card shape `.diskReadWrite` already needs for its own
/// read/write pair.
enum BenchmarkKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case cpuSingleCore
    case cpuMultiCore
    case gpuCompute
    case diskReadWrite
    case internetSpeed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpuSingleCore: "CPU (Single-Core)"
        case .cpuMultiCore: "CPU (Multi-Core)"
        case .gpuCompute: "GPU (Compute)"
        case .diskReadWrite: "Disk (Read/Write)"
        case .internetSpeed: "Internet (Down/Up)"
        }
    }

    var systemImage: String {
        switch self {
        case .cpuSingleCore, .cpuMultiCore: "cpu"
        case .gpuCompute: "cube.transparent"
        case .diskReadWrite: "internaldrive"
        case .internetSpeed: "network"
        }
    }

    /// Per-domain identity color, per PLAN.md §2's "keep a subtle
    /// color-per-domain identity" rule — reuses `MetricDomain`'s existing
    /// `DomainPalette` mapping rather than inventing new tokens for this
    /// page.
    var domain: MetricDomain {
        switch self {
        case .cpuSingleCore, .cpuMultiCore: .cpu
        case .gpuCompute: .gpu
        case .diskReadWrite: .disk
        case .internetSpeed: .network
        }
    }
}

/// One headline number within a `BenchmarkResult` — PLAN.md §1.1's "large
/// numeric results," shown as native progress plus large numeric results
/// rather than a custom-drawn analog gauge (§2). A CPU/GPU compute run
/// reports one metric ("Score");
/// Disk and Internet report two (Read/Write, Download/Upload) — `label`
/// and `unit` are per-metric rather than per-result so `BenchmarksPage` can
/// lay out either shape without a kind-specific switch.
struct BenchmarkMetric: Sendable, Equatable, Codable, Identifiable {
    var id: String { label }
    /// e.g. "Score", "Read", "Write", "Download", "Upload".
    let label: String
    let value: Double
    /// e.g. "pts", "MB/s", "Mbps". Empty string for a unitless score.
    let unit: String
}

/// One completed (or historical) benchmark run — PLAN.md §1.1's "results
/// History table" row and, for whichever kind's run is most recent, the
/// big numeric readout on that kind's `BenchmarksPage` card.
///
/// `Codable` so `BenchmarkHistoryStore` can round-trip a whole run list
/// through `UserDefaults` as JSON, matching
/// `DiskSpaceScanHistoryEntry`'s own persistence scheme.
struct BenchmarkResult: Sendable, Equatable, Codable, Identifiable {
    let id: UUID
    let kind: BenchmarkKind
    let generatedAt: Date
    /// Always non-empty for a real result — see `BenchmarkMetric`'s own
    /// doc comment for which kinds report one vs. two.
    let metrics: [BenchmarkMetric]
    /// Free-form context a card/history row can show alongside `metrics`,
    /// e.g. the folder a Disk run tested against. `nil` when a kind has
    /// nothing extra to say.
    let detail: String?
}

/// A live tick from an in-progress `BenchmarkRunner.run(context:)` —
/// PLAN.md §4 M7's "native progress during runs," shown via a native
/// progress indicator rather than an animated gauge needle.
///
/// Unlike `DiskSpaceScanProgress` (which can never know a folder's total
/// item count up front and so stays permanently indeterminate),
/// `fraction` is `Double?` rather than always-`nil`: most benchmark
/// workloads know their own iteration/byte/sample target once running, so
/// a determinate bar is the normal case here. `nil` still covers a phase
/// with no honest fraction to report (e.g. "waiting for a server
/// response" during an Internet test) — the same "don't fabricate a
/// number you don't have" rule either way.
struct BenchmarkProgress: Sendable, Equatable {
    let fraction: Double?
    /// Short live caption, e.g. "Warming up\u{2026}", "Measuring writes\u{2026}".
    let phase: String
}

/// One event from `BenchmarkRunner.run(context:)`'s stream: any number of
/// `.progress` ticks, followed by exactly one terminal event, after which
/// the stream finishes — the same shape `DiskSpaceScanEvent` uses for
/// `DiskSpaceScanner.scan(rootPath:)`.
enum BenchmarkRunEvent: Sendable {
    case progress(BenchmarkProgress)
    case completed(BenchmarkResult)
    case failed(String)
    case cancelled
}

/// Inputs a run may need beyond "which kind" — PLAN.md's "Disk (read/write,
/// choose test folder)" is the only one today. Every other kind's runner
/// ignores this.
struct BenchmarkRunContext: Sendable, Equatable {
    var diskTestFolderPath: String
}

/// One benchmark kind's test engine. PLAN.md §3 lists one file per domain
/// under `Benchmarks/` (CPU, GPU, Disk, Internet) — each conforms to this
/// protocol so `BenchmarksPage`/`BenchmarksViewModel` stay engine-agnostic,
/// the same "page owns layout, a separate type owns the actual work" split
/// `DiskSpacePage`/`DiskSpaceScanner` already establish.
///
/// `Sendable` so a runner can be captured into the `Task` that consumes its
/// stream (`BenchmarksViewModel.start(_:context:)`) without a data-race
/// warning, matching `DiskSpaceScanner` being an `actor` for the same
/// reason.
protocol BenchmarkRunner: Sendable {
    var kind: BenchmarkKind { get }

    /// Starts one run, returning an `AsyncStream` of zero or more
    /// `.progress` ticks followed by exactly one terminal event, then
    /// finishing.
    func run(context: BenchmarkRunContext) -> AsyncStream<BenchmarkRunEvent>

    /// Cancels whichever run this runner currently has active, if any (a
    /// no-op otherwise) — mirrors `DiskSpaceScanner.cancelActiveScan()`.
    func cancelActiveRun()
}
