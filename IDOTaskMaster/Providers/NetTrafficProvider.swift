import Darwin
import Foundation

/// One process's network throughput reading as of the most recently
/// completed sample — PLAN.md §3 `Providers/NetTrafficProvider.swift
/// "per-process send/receive rates (nettop-style)"` and §4 M9's fourth
/// task.
struct NetTrafficReading: Sendable, Equatable, Identifiable {
    var id: pid_t { pid }
    let pid: pid_t
    /// Process display name as `nettop` reports it (its own short name,
    /// not a full executable path) — `nil` on the rare row where the
    /// `name.pid` token couldn't be split (see `NetTrafficProvider
    /// .parseIdentifier`'s doc comment), an honest "Unavailable" rather
    /// than a guess.
    let processName: String?
    /// Bytes/sec sent (`bytes_out`) over the interval since the previous
    /// completed sample. `nil` on the very first sample this pid was
    /// seen in — `NetTrafficProvider`'s own first-ever block, or this
    /// pid's own first appearance in a later block — since there is no
    /// prior reading to diff against yet, the same "honest nil, no
    /// prior sample" rule `NetworkProvider`/`TopProcessesProvider` follow
    /// for their own first-tick rates.
    let sendBytesPerSecond: Double?
    /// Bytes/sec received (`bytes_in`), same first-sample-`nil` rule as
    /// `sendBytesPerSecond`.
    let receiveBytesPerSecond: Double?
    /// Cumulative bytes sent by this pid since `NetTrafficProvider`
    /// started watching it — seeded from `nettop`'s own lifetime total on
    /// this pid's first appearance, then built up by adding each
    /// subsequent interval's delta, so it tracks the process's real
    /// lifetime total from that point on (see `NetTrafficProvider`'s doc
    /// comment for the one case this drifts from truth: a recycled pid).
    let totalBytesSent: UInt64
    let totalBytesReceived: UInt64
}

/// One completed sample across every process `nettop -P` reported —
/// PLAN.md §4 M9's "sortable, with totals": `readings` backs the
/// sortable per-process table, `totalSendBytesPerSecond`/
/// `totalReceiveBytesPerSecond` back the page's totals.
struct NetTrafficSnapshot: Sendable, Equatable {
    let generatedAt: Date
    let readings: [NetTrafficReading]
    /// Sum of every reading's `sendBytesPerSecond` that had one to report
    /// this sample — `nil` only when *no* process had a prior reading to
    /// diff against yet (this provider's very first completed sample).
    let totalSendBytesPerSecond: Double?
    let totalReceiveBytesPerSecond: Double?
}

/// Failure modes for `NetTrafficProvider.sample()` — see `Provider`'s doc
/// comment for the throw-vs-`nil` split this follows.
enum NetTrafficProviderError: Error, LocalizedError, Sendable {
    /// `/usr/bin/nettop` isn't present on this Mac (a stripped-down
    /// install, or a future macOS release relocating/removing it) — the
    /// honest "this domain can't be read here" case, not guessed data.
    case binaryNotFound
    /// `Process.run()` itself threw before `nettop` ever started.
    case launchFailed(reason: String)
    /// The running `nettop` process exited — its stdout pipe closed —
    /// before this provider asked it to. `NetTrafficProvider` attempts a
    /// throttled relaunch (see that type's doc comment); until a fresh
    /// sample arrives, `sample()` keeps throwing this.
    case nettopExited(status: Int32)
    /// `nettop -d`'s first logged block is always a lifetime-totals
    /// baseline, not an interval delta (see `NetTrafficProvider`'s doc
    /// comment) — so there's no rate-bearing sample yet on a freshly
    /// launched provider. Resolves itself within roughly one `-s`
    /// interval.
    case stillCollectingFirstSample

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "/usr/bin/nettop not found"
        case .launchFailed(let reason):
            return "Couldn\u{2019}t launch nettop: \(reason)"
        case .nettopExited(let status):
            return "nettop exited unexpectedly (status \(status))"
        case .stillCollectingFirstSample:
            return "Collecting the first traffic sample\u{2026}"
        }
    }
}

/// Samples per-process network send/receive rates — PLAN.md §3
/// `Providers/NetTrafficProvider.swift "per-process send/receive rates
/// (nettop-style)"` and §4 M9's fourth task, backing `NetworkUsagePage`.
///
/// **Why shell out to `nettop` rather than a syscall, unlike every other
/// provider in this app.** No public macOS API exposes per-process
/// network byte counts: `libproc`'s `proc_pid_rusage` has per-pid disk
/// I/O counters (`DiskProvider`'s neighbor, `ProcessProvider`, reads
/// those) but nothing for network; the real source of truth is the
/// kernel's `NSTAT` network-statistics facility, which has no public
/// header or stable wire format — it's reverse-engineered private API.
/// Apple's own `/usr/bin/nettop` (installed on every Mac, no elevated
/// privileges required — confirmed empirically: it reports totals for
/// other users' daemons run as a plain logged-in user, the same as
/// Activity Monitor's own Network tab) is a thin, stable CLI front end
/// onto exactly that facility, and its `-P` (per-process), `-x` (raw
/// integers, no "K"/"M" suffixes), `-d` (delta mode), `-L 0` (indefinite
/// CSV logging, one block per `-s` interval, flushed promptly even
/// though stdout isn't a tty) combination is the same "shell out to a
/// stable system CLI and parse its output" fallback this app's other
/// providers already lean on for private-API territory (`ConnectionsProvider`'s
/// `lsof` fallback, `StartupProvider`/`ServicesProvider`'s `launchctl`).
/// Here it's the *only* path rather than a fallback, since there's no
/// syscall alternative to fall back from.
///
/// **Delta mode's own baseline quirk.** `nettop -d`'s first logged block
/// reports each process's lifetime total-to-date (there's nothing yet to
/// diff against); every block after that reports the delta *since the
/// previous block*. This provider mirrors that per pid: a pid's first
/// appearance (this provider's very first completed block, or any later
/// block a pid shows up in for the first time) seeds `runningTotals` from
/// the raw value with no rate published that round; every block after
/// that computes `delta / elapsed` using this provider's own
/// wall-clock timestamps between completed blocks (rather than trusting
/// `-s`'s requested interval literally) and adds the delta onto the
/// running total — the same diff-two-cumulative-reads technique
/// `NetworkProvider`/`DiskProvider` use for their own rates, just fed by
/// `nettop`'s own already-computed deltas instead of a second raw
/// reading.
///
/// **The one honesty gap this can't close:** a recycled pid. If a
/// process exits and the kernel reuses its pid number for an unrelated
/// process before this provider's next block, `runningTotals[pid]` keeps
/// accumulating onto the *previous* occupant's total rather than
/// resetting — the same limitation `ConnectionsProvider.scanSynchronously`'s
/// doc comment already accepts for its own pid-keyed reads, for the same
/// reason (macOS recycles pids far sooner than this is likely to
/// matter in practice, and `nettop` itself gives this provider no
/// process-start-time field to detect the swap with).
///
/// An `actor`, like `ConnectionsProvider`/`TopProcessesProvider`: not
/// sampled from inside `Sampler`'s tick (a standing subprocess has no
/// business on that 2×/sec loop) but polled directly by
/// `NetworkUsagePage`'s own view model. Unlike those two, `sample()`
/// itself does no work — it just returns whatever `latestSnapshot` the
/// long-running `nettop` subprocess's output most recently produced
/// (parsed off its stdout pipe's `readabilityHandler` as it arrives, not
/// read synchronously inside `sample()`), so polling this actor is cheap
/// no matter how often the caller does it.
actor NetTrafficProvider: Provider {
    static let providerID = "netTraffic"

    private static let nettopPath = "/usr/bin/nettop"
    /// `-P` per-process summary, `-x` raw integers, `-d` delta mode,
    /// `-L 0` indefinite CSV logging (`0` samples means "forever" per
    /// `man nettop`), `-s 1` one-second interval, `-J bytes_in,bytes_out`
    /// restricting the row shape to just this provider's two columns
    /// (plus the implicit leading `name.pid` identifier column `nettop`
    /// always emits first).
    private static let arguments = ["-P", "-x", "-d", "-L", "0", "-s", "1", "-J", "bytes_in,bytes_out"]
    /// Minimum time between relaunch attempts after `nettop` exits
    /// unexpectedly — cheap insurance against a launch-storm if the
    /// binary is somehow present but consistently failing.
    private static let relaunchCooldown: TimeInterval = 5

    private var process: Process?
    private var lastLaunchAttempt: Date?
    /// Set only by a failure path (`launch()` couldn't start `nettop`, or
    /// it exited on its own); cleared only once a fresh block actually
    /// finalizes — see `sample()`'s doc comment for why a stale
    /// `latestSnapshot` is kept around rather than cleared alongside it.
    private var lastError: Error?

    /// Most recent completed sample. `nil` until this provider's very
    /// first block finishes parsing.
    private var latestSnapshot: NetTrafficSnapshot?

    // MARK: - Stdout parsing state

    /// Bytes read from `nettop`'s stdout pipe not yet resolved into a
    /// complete line.
    private var readBuffer = Data()
    /// Rows accumulated for the block currently being read — finalized
    /// (see `finalizeBlock`) the moment the *next* header line arrives,
    /// since a CSV block has no other end-of-block marker.
    private var pendingRows: [pid_t: RawRow] = [:]
    /// `false` until the first header line (`,bytes_in,bytes_out,`) has
    /// been seen — guards against finalizing a phantom empty block from
    /// data that arrives before parsing has synced to a block boundary.
    private var haveSeenFirstHeader = false
    /// Whether the *next* block to finalize is `nettop -d`'s own
    /// lifetime-totals baseline block rather than an interval delta —
    /// see this type's doc comment.
    private var isFirstDataBlock = true
    /// Wall-clock time the previously finalized block completed, used to
    /// measure the elapsed interval for the next block's rates — this
    /// provider's own measurement rather than trusting `-s 1` literally,
    /// the same reasoning `NetworkProvider`'s diff-based rates document.
    private var previousBlockCompletedAt: Date?
    /// Running cumulative bytes per pid since this provider first saw it
    /// — see this type's doc comment on how this is built up, and its
    /// one honesty gap (a recycled pid).
    private var runningTotals: [pid_t: (sent: UInt64, received: UInt64)] = [:]

    private struct RawRow {
        let name: String?
        let sentValue: UInt64
        let receivedValue: UInt64
    }

    /// Returns the most recent completed sample, launching (or, after a
    /// failure and `relaunchCooldown`, relaunching) the backing `nettop`
    /// subprocess as needed. Throws `.stillCollectingFirstSample` before
    /// this provider's first block has ever finalized, or the most
    /// recent launch/exit failure once one has occurred — checked
    /// *before* falling back to a possibly-stale `latestSnapshot`, so a
    /// caller always learns about a live problem even while it keeps
    /// showing last-known-good numbers (mirroring `ConnectionsViewModel`'s
    /// own "one bad poll doesn't blank an otherwise-good table" rule,
    /// just enforced from the provider side of that contract instead).
    func sample() async throws -> NetTrafficSnapshot {
        ensureRunning()
        if let lastError {
            throw lastError
        }
        guard let latestSnapshot else {
            throw NetTrafficProviderError.stillCollectingFirstSample
        }
        return latestSnapshot
    }

    /// Terminates the backing `nettop` subprocess and detaches its pipe
    /// handler. Callers that own this provider for a page's lifetime
    /// (`NetworkUsageViewModel`) call this from their own `stop()` so a
    /// standing child process doesn't keep running once the user
    /// navigates away — the same "own a private long-lived resource,
    /// tear it down on disappear" pattern `ConnectionsViewModel`'s
    /// `trafficSampler` follows for its private `Sampler`.
    func stop() {
        if let pipe = process?.standardOutput as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        process?.terminationHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
    }

    // MARK: - Process lifecycle

    private func ensureRunning() {
        if let process, process.isRunning { return }
        let now = Date()
        if let lastLaunchAttempt, now.timeIntervalSince(lastLaunchAttempt) < Self.relaunchCooldown {
            return
        }
        lastLaunchAttempt = now
        launch()
    }

    /// Starts a fresh `nettop` subprocess and resets every piece of
    /// parsing state that belongs to *this run* of it (`readBuffer`,
    /// `pendingRows`, the first-block/first-header flags,
    /// `previousBlockCompletedAt`). `runningTotals` is deliberately left
    /// alone across a relaunch — the next block's per-pid values will
    /// come back in as `nettop -d`'s own fresh baseline totals (this
    /// provider's `isFirstDataBlock` guard makes the *first* block after
    /// any launch a baseline seed regardless of what came before), which
    /// naturally overwrites each pid's entry with an accurate current
    /// total rather than compounding onto possibly-stale numbers from
    /// before the relaunch.
    private func launch() {
        guard FileManager.default.isExecutableFile(atPath: Self.nettopPath) else {
            lastError = NetTrafficProviderError.binaryNotFound
            return
        }

        readBuffer = Data()
        pendingRows = [:]
        haveSeenFirstHeader = false
        isFirstDataBlock = true
        previousBlockCompletedAt = nil

        let newProcess = Process()
        newProcess.executableURL = URL(fileURLWithPath: Self.nettopPath)
        newProcess.arguments = Self.arguments
        let stdoutPipe = Pipe()
        newProcess.standardOutput = stdoutPipe
        // Discarded rather than left `nil`: an unconsumed stderr pipe on
        // a long-running child can itself fill up and stall the child
        // once its OS pipe buffer backs up.
        newProcess.standardError = Pipe()

        // Runs on an internal dispatch queue, not this actor's own
        // executor — only `Data`/`weak self` (both `Sendable`) cross into
        // the `Task` that hops back onto the actor via `ingest(_:)`.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF: the pipe closed. `terminationHandler` below is the
                // authoritative "nettop exited" signal; this just stops
                // firing an empty-read handler on every subsequent runloop
                // pass while that's pending.
                handle.readabilityHandler = nil
                return
            }
            Task { await self?.ingest(data) }
        }

        newProcess.terminationHandler = { [weak self] finishedProcess in
            let status = finishedProcess.terminationStatus
            Task { await self?.handleTermination(status: status) }
        }

        do {
            try newProcess.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            lastError = NetTrafficProviderError.launchFailed(reason: error.localizedDescription)
            return
        }

        process = newProcess
        // `lastError` is deliberately *not* cleared here — only once a
        // fresh block actually finalizes (`finalizeBlock`) does this
        // provider consider itself genuinely recovered; until then
        // `sample()` keeps honestly reporting the previous failure rather
        // than silently going quiet the instant a new process exists.
    }

    private func handleTermination(status: Int32) {
        process = nil
        lastError = NetTrafficProviderError.nettopExited(status: status)
    }

    // MARK: - Stdout parsing

    private func ingest(_ data: Data) {
        readBuffer.append(data)
        while let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer[readBuffer.startIndex..<newlineIndex]
            let line = String(data: lineData, encoding: .utf8)
            readBuffer.removeSubrange(readBuffer.startIndex...newlineIndex)
            if let line {
                handleLine(line)
            }
        }
    }

    /// Parses one CSV line from `nettop -x -d -L 0 -J bytes_in,bytes_out`'s
    /// output. Every line — header or data row — splits into exactly four
    /// comma-separated fields: an identifier (empty on the header row),
    /// `bytes_in`, `bytes_out`, and a trailing empty field from the
    /// format's own trailing comma. A header line (empty first field)
    /// marks a block boundary: the block just finished accumulating in
    /// `pendingRows` is finalized (unless this is the very first header
    /// this run has seen, in which case there's no prior block to
    /// finalize yet).
    private func handleLine(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .newlines)
        guard !line.isEmpty else { return }

        let fields = line.components(separatedBy: ",")
        guard fields.count == 4 else { return }

        if fields[0].isEmpty {
            if haveSeenFirstHeader {
                finalizeBlock(pendingRows)
            }
            haveSeenFirstHeader = true
            pendingRows = [:]
            return
        }

        guard haveSeenFirstHeader else { return }
        guard let identifier = Self.parseIdentifier(fields[0]) else { return }
        guard let receivedValue = UInt64(fields[1]), let sentValue = UInt64(fields[2]) else { return }
        pendingRows[identifier.pid] = RawRow(name: identifier.name, sentValue: sentValue, receivedValue: receivedValue)
    }

    /// Turns one completed block's raw rows into a published
    /// `NetTrafficSnapshot` — see this type's doc comment for the
    /// baseline-vs-delta split (`isFirstDataBlock`, and per-pid via
    /// `runningTotals[pid] == nil`) and the elapsed-time measurement this
    /// derives rates from.
    private func finalizeBlock(_ rows: [pid_t: RawRow]) {
        let now = Date()
        var elapsedSeconds: Double?
        if let previousBlockCompletedAt {
            let delta = now.timeIntervalSince(previousBlockCompletedAt)
            if delta > 0 { elapsedSeconds = delta }
        }

        var readings: [NetTrafficReading] = []
        readings.reserveCapacity(rows.count)
        var totalSendRate: Double = 0
        var totalReceiveRate: Double = 0
        var haveAnyRate = false

        for (pid, row) in rows {
            let previousTotals = runningTotals[pid]
            var sendRate: Double?
            var receiveRate: Double?
            let newSentTotal: UInt64
            let newReceivedTotal: UInt64

            if isFirstDataBlock || previousTotals == nil {
                // This block is `nettop`'s own lifetime-totals baseline,
                // or this pid's own first appearance in any block — either
                // way, an honest "no rate yet" seed rather than a
                // fabricated one, matching `NetworkProvider`'s first-tick
                // rule for its own rates.
                newSentTotal = row.sentValue
                newReceivedTotal = row.receivedValue
            } else if let elapsedSeconds {
                let computedSendRate = Double(row.sentValue) / elapsedSeconds
                let computedReceiveRate = Double(row.receivedValue) / elapsedSeconds
                sendRate = computedSendRate
                receiveRate = computedReceiveRate
                totalSendRate += computedSendRate
                totalReceiveRate += computedReceiveRate
                haveAnyRate = true
                newSentTotal = previousTotals!.sent + row.sentValue
                newReceivedTotal = previousTotals!.received + row.receivedValue
            } else {
                // `previousBlockCompletedAt` was somehow unusable this
                // round (e.g. a non-positive elapsed reading) — keep the
                // totals honest by still adding the delta on, just without
                // a rate to divide it by this time.
                newSentTotal = previousTotals!.sent + row.sentValue
                newReceivedTotal = previousTotals!.received + row.receivedValue
            }

            runningTotals[pid] = (sent: newSentTotal, received: newReceivedTotal)

            readings.append(
                NetTrafficReading(
                    pid: pid,
                    processName: row.name,
                    sendBytesPerSecond: sendRate,
                    receiveBytesPerSecond: receiveRate,
                    totalBytesSent: newSentTotal,
                    totalBytesReceived: newReceivedTotal
                )
            )
        }

        latestSnapshot = NetTrafficSnapshot(
            generatedAt: now,
            readings: readings,
            totalSendBytesPerSecond: haveAnyRate ? totalSendRate : nil,
            totalReceiveBytesPerSecond: haveAnyRate ? totalReceiveRate : nil
        )
        lastError = nil
        previousBlockCompletedAt = now
        isFirstDataBlock = false
    }

    /// Splits a `nettop` row identifier of the form `"name.pid"` into its
    /// process name and pid. Process names can themselves legitimately
    /// contain dots (`"com.docker.back.69979"` is name `"com.docker.back"`,
    /// pid `69979`), so this splits on the *last* dot rather than the
    /// first, and only accepts it as a valid pid when everything after
    /// that dot is plain digits — the one part of the token `nettop`
    /// guarantees is numeric. Returns `nil` for the (unexpected) case
    /// where no such split exists, in which case the caller drops that
    /// row rather than fabricating a pid.
    private static func parseIdentifier(_ token: String) -> (name: String?, pid: pid_t)? {
        guard let lastDot = token.lastIndex(of: ".") else { return nil }
        let pidSlice = token[token.index(after: lastDot)...]
        guard !pidSlice.isEmpty, pidSlice.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard let pid = pid_t(pidSlice) else { return nil }
        let namePart = String(token[token.startIndex..<lastDot])
        return (namePart.isEmpty ? nil : namePart, pid)
    }
}
