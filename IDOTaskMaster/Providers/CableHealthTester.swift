import Darwin
import Foundation

/// One cable-health run's measurements and verdict.
struct CableHealthResult: Sendable, Equatable {
    let writeMBps: Double
    /// Uncached sequential read throughput with 4 MB requests — the
    /// per-transfer-cost-sensitive measurement.
    let smallChunkReadMBps: Double
    /// The same read with 16 MB requests — amortizes any fixed per-transfer
    /// cost, so comparing it against `smallChunkReadMBps` is what separates
    /// "the link stalls between transfers" from "the drive is just slow".
    let largeChunkReadMBps: Double
    let verdict: CableHealthVerdict
}

/// What the two read measurements together indicate — see
/// `CableHealthTester`'s doc comment for the reasoning behind each case.
enum CableHealthVerdict: Sendable, Equatable {
    /// Small- and large-request throughput agree and are a healthy
    /// fraction of the negotiated link — no sign of link trouble.
    case healthy
    /// Large requests are much faster than small ones: each transfer pays
    /// a fixed stall, the signature of a link repeatedly falling into
    /// recovery — in practice, a marginal or damaged cable.
    case perTransferStalls
    /// Both measurements are low but agree — the bottleneck is steady,
    /// which points at the drive/enclosure itself rather than the link.
    case uniformlySlow

    var title: String {
        switch self {
        case .healthy: "Link looks healthy"
        case .perTransferStalls: "Per-transfer stalls detected"
        case .uniformlySlow: "Uniformly slow"
        }
    }

    var explanation: String {
        switch self {
        case .healthy:
            "Small and large transfers perform alike, at a healthy fraction of the link rate. No sign of cable trouble."
        case .perTransferStalls:
            "Large transfers run far faster than small ones \u{2014} each transfer is paying a fixed stall, the signature of a link that keeps dropping into recovery. In practice this usually means a marginal or damaged cable: try another one on the same drive and compare."
        case .uniformlySlow:
            "Both transfer sizes are equally slow \u{2014} a steady bottleneck, which points at the drive or enclosure itself rather than the cable."
        }
    }
}

enum CableHealthEvent: Sendable {
    case progress(phase: String, fraction: Double?)
    case completed(CableHealthResult)
    case failed(String)
    case cancelled
}

/// Explicit, user-triggered cable/link health test for the USB & Ports
/// page. **Never runs on its own** — it writes a temporary 512 MB file to
/// a volume the user chose, which is benchmark territory, not monitoring
/// territory (the same reason `DiskBenchmarkRunner` only runs from its
/// Run button).
///
/// The method comes from a real investigation on this project's dev
/// hardware: two cables that negotiated the *identical* 10 Gbps link on
/// the identical port and enclosure measured 846 vs 198 MB/s in uncached
/// 4 MB reads — and macOS exposes no link-error counter that could tell
/// them apart. What did separate them was the *shape* of the slowness:
/// on the bad cable, throughput scaled strongly with request size
/// (205 MB/s at 4 MB vs 617 MB/s at 16 MB), meaning each transfer paid a
/// fixed stall — consistent with the link repeatedly renegotiating —
/// while the good cable performed alike at every size. This tester
/// automates exactly that comparison: one uncached write pass, then the
/// same data read back uncached at 4 MB and again at 16 MB, and a
/// verdict from how the two reads compare (thresholds on the ratio, with
/// the negotiated link rate as context for "healthy").
///
/// I/O mechanics mirror `DiskBenchmarkRunner` deliberately: `F_NOCACHE`
/// both directions so the storage is measured rather than the page
/// cache, the blocking syscalls on `DispatchQueue.global` rather than a
/// cooperative-pool task, and a `BenchmarkCancellationToken` checked
/// between chunks.
final class CableHealthTester {
    private let tokenBox = BenchmarkTokenBox()

    private static let smallChunkSize = 4 * 1024 * 1024
    private static let largeChunkSize = 16 * 1024 * 1024
    private static let totalBytes = 512 * 1024 * 1024

    /// `linkGbps` (the port's negotiated rate, when known) only feeds the
    /// "healthy fraction of the link" part of the verdict — the
    /// stall-vs-uniform distinction needs no baseline at all.
    func run(folderPath: String, linkGbps: Double?) -> AsyncStream<CableHealthEvent> {
        let token = BenchmarkCancellationToken()
        tokenBox.set(token)
        return AsyncStream { continuation in
            continuation.onTermination = { _ in token.cancel() }
            DispatchQueue.global(qos: .userInitiated).async {
                Self.performRun(folderPath: folderPath, linkGbps: linkGbps, token: token, continuation: continuation)
            }
        }
    }

    func cancelActiveRun() {
        tokenBox.current?.cancel()
    }

    // MARK: - Run

    private static func performRun(
        folderPath: String,
        linkGbps: Double?,
        token: BenchmarkCancellationToken,
        continuation: AsyncStream<CableHealthEvent>.Continuation
    ) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            continuation.yield(.failed("\u{201C}\(folderPath)\u{201D} isn\u{2019}t a folder, or can\u{2019}t be read."))
            continuation.finish()
            return
        }

        let testFilePath = (folderPath as NSString).appendingPathComponent(".idotaskmaster_cablehealth_\(UUID().uuidString).tmp")
        defer { _ = unlink(testFilePath) }

        // Write pass
        continuation.yield(.progress(phase: "Writing test data\u{2026}", fraction: 0))
        let writeMBps: Double
        switch writePass(path: testFilePath, token: token, continuation: continuation) {
        case .completed(let mbps): writeMBps = mbps
        case .cancelled: continuation.yield(.cancelled); continuation.finish(); return
        case .failed(let reason): continuation.yield(.failed(reason)); continuation.finish(); return
        }

        // Small-request read pass
        continuation.yield(.progress(phase: "Reading with 4 MB requests\u{2026}", fraction: 0.4))
        let smallMBps: Double
        switch readPass(path: testFilePath, chunkSize: smallChunkSize, baseFraction: 0.4, token: token, continuation: continuation) {
        case .completed(let mbps): smallMBps = mbps
        case .cancelled: continuation.yield(.cancelled); continuation.finish(); return
        case .failed(let reason): continuation.yield(.failed(reason)); continuation.finish(); return
        }

        // Large-request read pass
        continuation.yield(.progress(phase: "Reading with 16 MB requests\u{2026}", fraction: 0.7))
        let largeMBps: Double
        switch readPass(path: testFilePath, chunkSize: largeChunkSize, baseFraction: 0.7, token: token, continuation: continuation) {
        case .completed(let mbps): largeMBps = mbps
        case .cancelled: continuation.yield(.cancelled); continuation.finish(); return
        case .failed(let reason): continuation.yield(.failed(reason)); continuation.finish(); return
        }

        let result = CableHealthResult(
            writeMBps: writeMBps,
            smallChunkReadMBps: smallMBps,
            largeChunkReadMBps: largeMBps,
            verdict: verdict(smallMBps: smallMBps, largeMBps: largeMBps, linkGbps: linkGbps)
        )
        continuation.yield(.completed(result))
        continuation.finish()
    }

    /// The thresholds, made explicit:
    ///
    /// - ratio ≥ 2 (large reads at least twice as fast as small) — a fixed
    ///   per-transfer cost is dominating; on the measured bad cable the
    ///   ratio was ~3, on the good one ~1.0. → `.perTransferStalls`
    /// - otherwise, small-request throughput at ≥ 40% of the link's
    ///   theoretical ceiling (or ≥ 400 MB/s when the link rate is
    ///   unknown) → `.healthy` — the measured good cable sat at ~77%.
    /// - otherwise → `.uniformlySlow` (slow but consistent = the drive).
    private static func verdict(smallMBps: Double, largeMBps: Double, linkGbps: Double?) -> CableHealthVerdict {
        if smallMBps > 0, largeMBps / smallMBps >= 2.0 {
            return .perTransferStalls
        }
        // ~MB/s ceiling for the link: gbps × 125, discounted ~12% for
        // encoding/protocol overhead.
        let healthyFloor: Double
        if let linkGbps {
            healthyFloor = linkGbps * 125 * 0.88 * 0.4
        } else {
            healthyFloor = 400
        }
        return smallMBps >= healthyFloor ? .healthy : .uniformlySlow
    }

    // MARK: - Passes

    private enum PassOutcome {
        case completed(mbps: Double)
        case cancelled
        case failed(String)
    }

    private static func writePass(
        path: String,
        token: BenchmarkCancellationToken,
        continuation: AsyncStream<CableHealthEvent>.Continuation
    ) -> PassOutcome {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else {
            return .failed("Couldn\u{2019}t create a test file there (\(String(cString: strerror(errno)))).")
        }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)

        var buffer = [UInt8](repeating: 0, count: smallChunkSize)
        buffer.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress { arc4random_buf(base, raw.count) }
        }

        let chunkCount = totalBytes / smallChunkSize
        let start = Date()
        for chunkIndex in 0..<chunkCount {
            guard !token.isCancelled else { return .cancelled }
            let written = buffer.withUnsafeBytes { raw in write(fd, raw.baseAddress, smallChunkSize) }
            guard written == smallChunkSize else {
                return .failed("Writing the test file failed (\(String(cString: strerror(errno)))).")
            }
            if chunkIndex % 8 == 0 {
                let fraction = Double(chunkIndex) / Double(chunkCount) * 0.4
                continuation.yield(.progress(phase: "Writing test data\u{2026}", fraction: fraction))
            }
        }
        guard fsync(fd) == 0 else {
            return .failed("Flushing the test file to storage failed (\(String(cString: strerror(errno)))).")
        }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else { return .failed("The write pass didn\u{2019}t measure a usable elapsed time.") }
        return .completed(mbps: Double(totalBytes) / elapsed / 1_048_576)
    }

    private static func readPass(
        path: String,
        chunkSize: Int,
        baseFraction: Double,
        token: BenchmarkCancellationToken,
        continuation: AsyncStream<CableHealthEvent>.Continuation
    ) -> PassOutcome {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            return .failed("Couldn\u{2019}t reopen the test file for reading (\(String(cString: strerror(errno)))).")
        }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)

        var buffer = [UInt8](repeating: 0, count: chunkSize)
        let start = Date()
        var totalRead = 0
        while totalRead < totalBytes {
            guard !token.isCancelled else { return .cancelled }
            let n = buffer.withUnsafeMutableBytes { raw in read(fd, raw.baseAddress, chunkSize) }
            guard n > 0 else {
                return .failed("Reading the test file back failed (\(String(cString: strerror(errno)))).")
            }
            totalRead += n
            if totalRead % (chunkSize * 4) == 0 {
                let fraction = baseFraction + Double(totalRead) / Double(totalBytes) * 0.3
                let phase = chunkSize >= largeChunkSize ? "Reading with 16 MB requests\u{2026}" : "Reading with 4 MB requests\u{2026}"
                continuation.yield(.progress(phase: phase, fraction: min(fraction, 1)))
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else { return .failed("The read pass didn\u{2019}t measure a usable elapsed time.") }
        return .completed(mbps: Double(totalRead) / elapsed / 1_048_576)
    }
}
