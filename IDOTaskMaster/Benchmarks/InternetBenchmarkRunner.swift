import Darwin
import Foundation

/// Real engine behind `.internetSpeed` — PLAN.md §3's `Benchmarks/`
/// "Internet (URLSession)" and §4 M7's second task's "Internet down/up".
/// Downloads, then uploads, a fixed-size payload against Cloudflare's
/// public speed-test endpoints (`speed.cloudflare.com/__down`/`__up` — no
/// account or API key, the same publicly documented HTTP endpoints
/// Cloudflare's own `speed.cloudflare.com` page and a number of open-source
/// speed-test CLIs use) and reports each direction's throughput in Mbps.
///
/// Unlike `CPUBenchmarkRunner`/`GPUBenchmarkRunner`/`DiskBenchmarkRunner`,
/// this runner's work is a plain `async` network request — nothing here
/// blocks a thread, so it runs as a genuine `Task` rather than being pushed
/// onto `DispatchQueue.global`, and cancellation is Swift Concurrency's own
/// `Task.cancel()` (tracked in a `BenchmarkTaskBox`) rather than a
/// `BenchmarkCancellationToken`. `URLSession`'s async APIs are
/// cancellation-aware: cancelling the wrapping `Task` cancels the in-flight
/// `URLSessionTask` too, so — unlike the other three runners, whose cancel
/// only takes effect between chunks/batches — this one can stop mid-request.
///
/// Progress is reported with `fraction: nil` (an indeterminate spinner) for
/// both phases: `BenchmarkProgress.fraction`'s own doc comment names this
/// exact case ("waiting for a server response" during an Internet test) as
/// the one honest use of "no fraction to report" — tracking live
/// bytes-transferred would need a delegate-based `URLSession` instead of
/// the plain `async` request/response calls used here, for a progress bar
/// that wouldn't add anything the final Mbps number doesn't already say.
final class InternetBenchmarkRunner: BenchmarkRunner {
    let kind: BenchmarkKind = .internetSpeed
    private let taskBox = BenchmarkTaskBox()

    /// Downloaded/uploaded payload sizes. Large enough that connection
    /// setup and TLS handshake overhead are a small fraction of the total
    /// transfer time (so the measured rate reflects sustained throughput,
    /// not just round-trip latency), small enough that the whole run stays
    /// well under a minute even on a slow connection.
    private static let downloadBytes = 25_000_000 // 25 MB
    private static let uploadBytes = 10_000_000 // 10 MB
    private static let downloadURL = URL(string: "https://speed.cloudflare.com/__down?bytes=\(downloadBytes)")!
    private static let uploadURL = URL(string: "https://speed.cloudflare.com/__up")!

    func run(context: BenchmarkRunContext) -> AsyncStream<BenchmarkRunEvent> {
        AsyncStream { continuation in
            let task = Task {
                await Self.performRun(continuation: continuation)
            }
            taskBox.set(task)
            continuation.onTermination = { [taskBox] _ in
                taskBox.current?.cancel()
            }
        }
    }

    /// Mirrors `DiskSpaceScanner.cancelActiveScan()`'s "takes effect
    /// immediately" guarantee: cancelling the underlying `Task` cancels
    /// whichever `URLSessionTask` is in flight right away, rather than
    /// waiting for the current chunk/batch to finish the way the other
    /// three runners' token-based cancellation does.
    func cancelActiveRun() {
        taskBox.current?.cancel()
    }

    private static func performRun(continuation: AsyncStream<BenchmarkRunEvent>.Continuation) async {
        continuation.yield(.progress(BenchmarkProgress(fraction: nil, phase: "Measuring download speed\u{2026}")))
        let downloadMbps: Double
        switch await measureDownload() {
        case .success(let mbps): downloadMbps = mbps
        case .cancelled: continuation.yield(.cancelled); continuation.finish(); return
        case .failed(let reason): continuation.yield(.failed(reason)); continuation.finish(); return
        }

        guard !Task.isCancelled else {
            continuation.yield(.cancelled)
            continuation.finish()
            return
        }

        continuation.yield(.progress(BenchmarkProgress(fraction: nil, phase: "Measuring upload speed\u{2026}")))
        let uploadMbps: Double
        switch await measureUpload() {
        case .success(let mbps): uploadMbps = mbps
        case .cancelled: continuation.yield(.cancelled); continuation.finish(); return
        case .failed(let reason): continuation.yield(.failed(reason)); continuation.finish(); return
        }

        let result = BenchmarkResult(
            id: UUID(),
            kind: .internetSpeed,
            generatedAt: Date(),
            metrics: [
                BenchmarkMetric(label: "Download", value: downloadMbps, unit: "Mbps"),
                BenchmarkMetric(label: "Upload", value: uploadMbps, unit: "Mbps"),
            ],
            detail: nil
        )
        continuation.yield(.completed(result))
        continuation.finish()
    }

    /// One direction's measurement outcome — mirrors `DiskBenchmarkRunner
    /// .PhaseOutcome`'s "completed / cancelled / failed" shape, with the
    /// already-computed Mbps figure in the completed case instead of a raw
    /// elapsed time (there's no second value to combine it with here).
    private enum MeasurementOutcome {
        case success(mbps: Double)
        case cancelled
        case failed(String)
    }

    private static func measureDownload() async -> MeasurementOutcome {
        var request = URLRequest(url: downloadURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = Date().timeIntervalSince(start)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .failed("The download speed test server didn\u{2019}t respond as expected.")
            }
            guard elapsed > 0, !data.isEmpty else {
                return .failed("The download speed test didn\u{2019}t measure a usable transfer.")
            }
            return .success(mbps: megabitsPerSecond(bytes: data.count, elapsed: elapsed))
        } catch {
            return outcome(for: error)
        }
    }

    private static func measureUpload() async -> MeasurementOutcome {
        var payload = Data(count: uploadBytes)
        let filled = payload.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            arc4random_buf(base, uploadBytes)
            return true
        }
        guard filled else {
            return .failed("Couldn\u{2019}t prepare the upload speed test payload.")
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.upload(for: request, from: payload)
            let elapsed = Date().timeIntervalSince(start)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .failed("The upload speed test server didn\u{2019}t respond as expected.")
            }
            guard elapsed > 0 else {
                return .failed("The upload speed test didn\u{2019}t measure a usable transfer.")
            }
            return .success(mbps: megabitsPerSecond(bytes: uploadBytes, elapsed: elapsed))
        } catch {
            return outcome(for: error)
        }
    }

    private static func megabitsPerSecond(bytes: Int, elapsed: TimeInterval) -> Double {
        Double(bytes) * 8 / elapsed / 1_000_000
    }

    /// Distinguishes a deliberate cancel (`CancellationError`, or the
    /// `URLError.cancelled` a cancelled `URLSessionTask` throws) from every
    /// other network failure, which is reported as `.failed` with an
    /// honest reason — never a fabricated Mbps figure, PLAN.md's
    /// "Unavailable instead of a guess" rule.
    private static func outcome(for error: Error) -> MeasurementOutcome {
        if error is CancellationError {
            return .cancelled
        }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled {
                return .cancelled
            }
            return .failed("No internet connection was available for the speed test (\(urlError.localizedDescription)).")
        }
        return .failed(error.localizedDescription)
    }
}
