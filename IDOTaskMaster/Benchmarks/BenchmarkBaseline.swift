import Foundation

/// The fixed reference point PLAN.md §1.1's [name removed] description calls out for
/// its own Score page — "aggregate of all benchmark results, baselined to
/// a reference machine, versioned comparisons." Every `BenchmarkMetric`
/// this app's own runners produce is unit-different (pts, GFLOPS, GB/s,
/// MB/s, Mbps) and, per e.g. `CPUBenchmarkRunner`'s own doc comment, only
/// self-consistent on *this* Mac — "not calibrated against any published
/// benchmark suite... meaningful for comparing this same Mac's own runs
/// over time, not for comparing against a different app's numbers." So
/// this baseline doesn't claim to be a specific real machine's measured
/// results either: it's a fixed internal points scale this app defines
/// once and never silently changes, picked so a contemporary Apple
/// silicon Mac's own results land near 1,000 points on each test. That
/// fixed divisor is what lets `BenchmarkAggregateScore` add GFLOPS,
/// GB/s, MB/s, Mbps, and primes/sec together into one number at all.
///
/// `version` is PLAN.md's "versioned comparisons" — bumped only if these
/// reference numbers themselves are ever revised, so a `ScoreCard` (or a
/// future history of aggregate scores) can label which scale a given
/// points figure was computed under rather than silently mixing two
/// incompatible scales together.
enum BenchmarkBaseline {
    static let version = "1.0"

    /// Shown on `ScoreCard`'s footer as what "1,000 pts" per test means —
    /// deliberately not phrased as a specific machine model, since these
    /// numbers were chosen as a round internal anchor, not measured off
    /// real reference hardware.
    static let referenceLabel = "Baseline v\(version) \u{2014} 1,000 pts/test reference scale"

    /// Reference value per `(kind, metric label)`, in that metric's own
    /// unit — the divisor `points(for:kind:)` uses to turn a measured
    /// `BenchmarkMetric.value` into points on the shared scale. Every
    /// label a real `BenchmarkRunner` in `Benchmarks/*.swift` actually
    /// produces has an entry here (see each metric's own `BenchmarkMetric
    /// (label:...)` call site).
    private static let referenceValues: [BenchmarkKind: [String: Double]] = [
        .cpuSingleCore: ["Score": 2_800],
        .cpuMultiCore: ["Score": 18_000],
        .gpuCompute: ["Compute": 4_000, "Bandwidth": 150],
        .diskReadWrite: ["Read": 3_000, "Write": 2_500],
        .internetSpeed: ["Download": 300, "Upload": 30],
    ]

    /// `metric.value / reference * 1,000` — `nil` when this exact
    /// `(kind, label)` pair has no reference entry (never true for a
    /// label a real runner produces, but this stays a lookup rather than
    /// a force-unwrap so an unrecognized label degrades to "excluded from
    /// the score" instead of crashing) or when `metric.value` isn't
    /// finite.
    static func points(for metric: BenchmarkMetric, kind: BenchmarkKind) -> Double? {
        guard let reference = referenceValues[kind]?[metric.label], reference > 0, metric.value.isFinite else {
            return nil
        }
        return metric.value / reference * 1_000
    }

    /// One completed run's own points: the mean of every one of its
    /// metrics' individual points — a lone "Score" for the CPU kinds, the
    /// Compute/Bandwidth, Read/Write, or Download/Upload pair's average
    /// for the other three. `nil` only if none of `result.metrics` has a
    /// recognized label (shouldn't happen for a result a real runner
    /// produced).
    static func points(for result: BenchmarkResult) -> Double? {
        let values = result.metrics.compactMap { points(for: $0, kind: result.kind) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

// MARK: - Aggregate score

/// One `BenchmarkKind`'s contribution to a `BenchmarkAggregateScore` —
/// `points`/`result` are both `nil` together for a kind that has never
/// completed a run, the same "no result yet, not a guessed one" state
/// `BenchmarksViewModel.latestResult(for:)` already surfaces to
/// `BenchmarksPage`'s cards.
struct BenchmarkKindScore: Identifiable, Equatable {
    let kind: BenchmarkKind
    let points: Double?
    let result: BenchmarkResult?
    var id: BenchmarkKind { kind }
}

/// Every `BenchmarkKind`'s latest result folded onto
/// `BenchmarkBaseline`'s shared points scale — everything the Score
/// page's `ScoreCard` and per-test breakdown list need, computed fresh
/// from whatever `BenchmarksViewModel.latestResult(for:)` currently holds
/// rather than cached, so it always reflects the most recent run.
struct BenchmarkAggregateScore: Equatable {
    /// One entry per `BenchmarkKind`, in `BenchmarkKind.allCases` order.
    let perKind: [BenchmarkKindScore]

    /// The mean of every kind's own points among the kinds that have a
    /// result so far — PLAN.md's "aggregate of all benchmark results."
    /// `nil` until at least one kind has completed a run; never
    /// interpolates a fabricated number for the kinds still missing, the
    /// same "honest partial data over a guessed whole" rule every
    /// `Provider` in this app follows.
    var overallPoints: Double? {
        let values = perKind.compactMap(\.points)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    var completedCount: Int { perKind.filter { $0.result != nil }.count }
    var totalCount: Int { perKind.count }

    /// The most recent `generatedAt` among the results actually folded
    /// into `overallPoints` — the aggregate's own "as of" timestamp.
    /// `nil` alongside `overallPoints` being `nil`.
    var generatedAt: Date? {
        perKind.compactMap { $0.result?.generatedAt }.max()
    }

    /// Builds an aggregate from whatever `latestResult` reports for every
    /// `BenchmarkKind` right now — `latestResult` is normally
    /// `BenchmarksViewModel.latestResult(for:)`, kept as a plain closure
    /// parameter (rather than this type depending on `BenchmarksViewModel`
    /// directly) so this stays a pure, view-model-agnostic value type,
    /// the same separation `BenchmarkCard` keeps from `BenchmarksViewModel`
    /// itself.
    static func compute(latestResult: (BenchmarkKind) -> BenchmarkResult?) -> BenchmarkAggregateScore {
        let perKind = BenchmarkKind.allCases.map { kind -> BenchmarkKindScore in
            let result = latestResult(kind)
            let points = result.flatMap(BenchmarkBaseline.points(for:))
            return BenchmarkKindScore(kind: kind, points: points, result: result)
        }
        return BenchmarkAggregateScore(perKind: perKind)
    }
}
