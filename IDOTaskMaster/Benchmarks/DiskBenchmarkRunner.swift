import Darwin
import Foundation

/// Real engine behind `.diskReadWrite` — PLAN.md §4 M7's second task's
/// "Disk R/W (chosen folder)". Writes a temporary test file into
/// `BenchmarkRunContext.diskTestFolderPath`, reads it back, and reports
/// each direction's throughput — the same user-chosen-directory shape
/// `DiskSpaceScanner.scan(rootPath:)` establishes for `DiskSpacePage`.
///
/// Opens the test file with `F_NOCACHE` (macOS's equivalent of Linux's
/// `O_DIRECT` — there is no `O_DIRECT` on macOS) so both directions measure
/// the storage device itself rather than round-tripping through the
/// unified buffer cache; without it, reading a file immediately after
/// writing it would mostly just read back RAM and report an implausibly
/// high number, especially on a Mac with plenty of free memory.
///
/// Mirrors `DiskSpaceScanner`'s own shape: the actual I/O runs on
/// `DispatchQueue.global`, never inside this `async`-shaped protocol's own
/// cooperative-pool `Task` (the identical "don't tie up the pool with
/// blocking I/O" reasoning `DiskSpaceScanner`'s own doc comment gives), and
/// cancellation is a `BenchmarkCancellationToken` checked between chunks.
final class DiskBenchmarkRunner: BenchmarkRunner {
    let kind: BenchmarkKind = .diskReadWrite
    private let tokenBox = BenchmarkTokenBox()

    private static let chunkSize = 4 * 1024 * 1024 // 4 MB
    private static let chunkCount = 64 // 256 MB total per direction
    private static let totalBytes = chunkSize * chunkCount

    func run(context: BenchmarkRunContext) -> AsyncStream<BenchmarkRunEvent> {
        let token = BenchmarkCancellationToken()
        tokenBox.set(token)
        let folderPath = context.diskTestFolderPath
        return AsyncStream { continuation in
            continuation.onTermination = { _ in token.cancel() }
            DispatchQueue.global(qos: .userInitiated).async {
                Self.performRun(folderPath: folderPath, token: token, continuation: continuation)
            }
        }
    }

    /// Mirrors `DiskSpaceScanner.cancelActiveScan()`: takes effect the next
    /// time the write/read loop checks `token.isCancelled` (at most one
    /// `chunkSize` write/read syscall of latency later).
    func cancelActiveRun() {
        tokenBox.current?.cancel()
    }

    /// One write-or-read phase's outcome — the same "any number of ticks,
    /// then exactly one terminal state" shape `BenchmarkRunEvent` itself
    /// uses, scoped down to what `performRun` needs from each phase.
    private enum PhaseOutcome {
        case completed(elapsed: TimeInterval)
        case cancelled
        case failed(String)
    }

    private static func performRun(folderPath: String, token: BenchmarkCancellationToken, continuation: AsyncStream<BenchmarkRunEvent>.Continuation) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            continuation.yield(.failed("\u{201C}\(displayPath(folderPath))\u{201D} isn\u{2019}t a folder, or can\u{2019}t be read."))
            continuation.finish()
            return
        }

        let testFilePath = (folderPath as NSString).appendingPathComponent(".idotaskmaster_diskbench_\(UUID().uuidString).tmp")
        defer { _ = unlink(testFilePath) }

        var writeBuffer = [UInt8](repeating: 0, count: chunkSize)
        writeBuffer.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
                arc4random_buf(base, chunkSize)
            }
        }

        continuation.yield(.progress(BenchmarkProgress(fraction: 0, phase: "Writing test file\u{2026}")))
        let writeOutcome = writePhase(path: testFilePath, buffer: writeBuffer, token: token, continuation: continuation)
        let writeElapsed: TimeInterval
        switch writeOutcome {
        case .completed(let elapsed): writeElapsed = elapsed
        case .cancelled: continuation.yield(.cancelled); continuation.finish(); return
        case .failed(let reason): continuation.yield(.failed(reason)); continuation.finish(); return
        }

        continuation.yield(.progress(BenchmarkProgress(fraction: 0.5, phase: "Reading test file\u{2026}")))
        let readOutcome = readPhase(path: testFilePath, token: token, continuation: continuation)
        let readElapsed: TimeInterval
        switch readOutcome {
        case .completed(let elapsed): readElapsed = elapsed
        case .cancelled: continuation.yield(.cancelled); continuation.finish(); return
        case .failed(let reason): continuation.yield(.failed(reason)); continuation.finish(); return
        }

        guard writeElapsed > 0, readElapsed > 0 else {
            continuation.yield(.failed("The disk benchmark didn\u{2019}t measure a usable elapsed time."))
            continuation.finish()
            return
        }

        let megabyte = 1024.0 * 1024.0
        let writeMBps = Double(totalBytes) / writeElapsed / megabyte
        let readMBps = Double(totalBytes) / readElapsed / megabyte

        let result = BenchmarkResult(
            id: UUID(),
            kind: .diskReadWrite,
            generatedAt: Date(),
            metrics: [
                BenchmarkMetric(label: "Read", value: readMBps, unit: "MB/s"),
                BenchmarkMetric(label: "Write", value: writeMBps, unit: "MB/s"),
            ],
            detail: displayPath(folderPath)
        )
        continuation.yield(.completed(result))
        continuation.finish()
    }

    // MARK: - Phases

    private static func writePhase(path: String, buffer: [UInt8], token: BenchmarkCancellationToken, continuation: AsyncStream<BenchmarkRunEvent>.Continuation) -> PhaseOutcome {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else {
            return .failed("Couldn\u{2019}t create a test file there (\(posixErrorDescription())).")
        }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)

        let start = Date()
        var bytesWritten = 0
        for chunkIndex in 0..<chunkCount {
            guard !token.isCancelled else { return .cancelled }
            let written = buffer.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base, chunkSize)
            }
            guard written == chunkSize else {
                return .failed("Writing the disk test file failed (\(posixErrorDescription())).")
            }
            bytesWritten += written
            if chunkIndex % 4 == 0 || chunkIndex == chunkCount - 1 {
                let fraction = Double(bytesWritten) / Double(totalBytes) * 0.5
                continuation.yield(.progress(BenchmarkProgress(fraction: fraction, phase: "Writing test file\u{2026}")))
            }
        }
        guard fsync(fd) == 0 else {
            return .failed("Flushing the disk test file to storage failed (\(posixErrorDescription())).")
        }
        return .completed(elapsed: Date().timeIntervalSince(start))
    }

    private static func readPhase(path: String, token: BenchmarkCancellationToken, continuation: AsyncStream<BenchmarkRunEvent>.Continuation) -> PhaseOutcome {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            return .failed("Couldn\u{2019}t reopen the disk test file for reading (\(posixErrorDescription())).")
        }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)

        var readBuffer = [UInt8](repeating: 0, count: chunkSize)
        let start = Date()
        var bytesRead = 0
        for chunkIndex in 0..<chunkCount {
            guard !token.isCancelled else { return .cancelled }
            let n = readBuffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base, chunkSize)
            }
            guard n == chunkSize else {
                return .failed("Reading the disk test file back failed (\(posixErrorDescription())).")
            }
            bytesRead += n
            if chunkIndex % 4 == 0 || chunkIndex == chunkCount - 1 {
                let fraction = 0.5 + Double(bytesRead) / Double(totalBytes) * 0.5
                continuation.yield(.progress(BenchmarkProgress(fraction: fraction, phase: "Reading test file\u{2026}")))
            }
        }
        return .completed(elapsed: Date().timeIntervalSince(start))
    }

    // MARK: - Helpers

    private static func posixErrorDescription() -> String {
        String(cString: strerror(errno))
    }

    /// `folderPath` abbreviated with `~` for `BenchmarksPage`'s history
    /// "Detail" column and its failure messages — the same
    /// tilde-abbreviated presentation `BenchmarksPage`'s own toolbar
    /// button `.help()` text uses for the chosen folder.
    private static func displayPath(_ folderPath: String) -> String {
        (folderPath as NSString).abbreviatingWithTildeInPath
    }
}
