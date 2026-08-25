import Foundation

/// The registry of one `BenchmarkRunner` per `BenchmarkKind` —
/// `BenchmarksPage`'s row list and `BenchmarksViewModel`'s dispatch table.
///
/// PLAN.md §4 M7's second task ("CPU benchmark (single/multi core), GPU
/// compute (Metal), Disk R/W (chosen folder), Internet down/up") backs
/// every kind with a real engine: `CPUBenchmarkRunner` (one instance per
/// CPU kind — see that type's own doc comment for why), `GPUBenchmarkRunner`,
/// `DiskBenchmarkRunner`, `InternetBenchmarkRunner`. None of them fabricate
/// a result when the underlying hardware/network isn't available — e.g.
/// `GPUBenchmarkRunner` reports `.failed("No Metal-capable GPU was found on
/// this Mac.")` rather than a guessed score, and `InternetBenchmarkRunner`
/// reports `.failed("No internet connection was available\u{2026}")` — the
/// same "Unavailable, not a guess" rule every `Providers/*.swift` type
/// follows, just surfaced through `BenchmarkRunEvent.failed` instead of a
/// `nil` field.
enum BenchmarkCatalog {
    /// One runner per `BenchmarkKind`, in `BenchmarkKind.allCases` order.
    static func makeRunners() -> [BenchmarkKind: BenchmarkRunner] {
        var runners: [BenchmarkKind: BenchmarkRunner] = [:]
        for kind in BenchmarkKind.allCases {
            runners[kind] = makeRunner(for: kind)
        }
        return runners
    }

    private static func makeRunner(for kind: BenchmarkKind) -> BenchmarkRunner {
        switch kind {
        case .cpuSingleCore, .cpuMultiCore:
            return CPUBenchmarkRunner(kind: kind)
        case .gpuCompute:
            return GPUBenchmarkRunner()
        case .diskReadWrite:
            return DiskBenchmarkRunner()
        case .internetSpeed:
            return InternetBenchmarkRunner()
        }
    }
}
