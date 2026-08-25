import Darwin
import Foundation

/// One process's reading for the Summary dashboard's "Top CPU processes"
/// table — PLAN.md §1.1's "Top CPU processes table (PID, Name, CPU, GPU,
/// Memory) — top 12 of N, rows tinted by usage" and §4 M3's third task.
///
/// A deliberately narrow slice of what a process can report: just the four
/// columns this one table needs. M4's `ProcessProvider` (PLAN.md §3
/// `Providers/ProcessProvider.swift`, §4 M4) is the real, full-fidelity
/// process domain — the complete Applications/Background tree with
/// per-pid identity/lifetime/threads/disk-io for the Processes and Users
/// pages' detail panes. This type and `TopProcessesProvider` below exist
/// only so the Summary dashboard has real top-N data before that milestone
/// lands; both are intentionally small so M4 can introduce the fuller
/// process domain without this one being in the way.
struct TopProcessReading: Sendable, Equatable, Identifiable {
    var id: pid_t { pid }
    let pid: pid_t
    /// Process display name — the executable path's last component
    /// (`proc_pidpath`) when readable, else `proc_name`'s short
    /// (≤16-character) name. `nil` when neither syscall could read this
    /// pid — e.g. another user's process without permission — an honest
    /// "Unavailable" cell rather than a blank or guessed name.
    let name: String?
    /// Busy percentage over the interval since this pid was last sampled,
    /// following `top`/Activity Monitor's own convention: this process's
    /// CPU-time delta ÷ wall-clock delta × 100, *not* divided by core
    /// count — a process fully busy across two cores reads ~200%. `nil`
    /// the first tick a pid is seen (no prior sample to diff against yet,
    /// matching `CPUProvider`'s own first-tick convention) or when this
    /// tick's task info couldn't be read for it.
    let cpuPercent: Double?
    /// Per-process GPU usage. Always `nil`: no public macOS API exposes
    /// per-process GPU utilization (`GPUProvider`'s whole-GPU
    /// `AGXAccelerator` counters have no per-pid breakdown), so this reads
    /// an honest "Unavailable" in every row rather than a fabricated
    /// number. Kept as a field — not dropped — so the GPU column PLAN.md
    /// §1.1 lists for this table has something to honestly bind to.
    let gpuPercent: Double?
    /// Resident memory footprint in bytes (`proc_taskinfo.pti_resident_size`).
    /// `nil` when this tick's task info couldn't be read for this pid.
    let memoryBytes: UInt64?
}

/// Samples every running process's PID, name, resident memory, and
/// CPU-time delta since the previous tick — backs `SummaryPage`'s "Top CPU
/// Processes" table (PLAN.md §1.1, §4 M3). See `TopProcessReading`'s doc
/// comment for why this is a narrow, Summary-only slice rather than M4's
/// full `ProcessProvider`.
///
/// An `actor`, not a plain class like `CPUProvider`: unlike every other
/// M2 provider, this one isn't sampled from inside `Sampler`'s own actor
/// context — `SummaryPage.swift`'s `SummaryViewModel` polls it directly
/// from its own loop, and enumerating every process (`proc_listallpids`
/// plus two `proc_pidinfo`/`proc_pidpath` calls per pid) is real syscall
/// work that has no business running on the main actor each tick. Making
/// this type an actor gets that off-main-thread guarantee for free from
/// Swift's own actor-hop rule, with none of the manual locking
/// `CPUProvider`'s carried-forward `previousCoreTicks` would otherwise
/// need.
actor TopProcessesProvider: Provider {
    static let providerID = "topProcesses"

    private struct RawSample {
        let cpuTimeNanoseconds: UInt64
        let timestamp: Date
    }

    /// Previous tick's raw CPU-time reading per pid. Keyed by pid rather
    /// than array position so a process that exits between ticks simply
    /// drops out with no stale entry lingering, and a freshly-spawned
    /// process that reuses a just-exited pid number naturally reads as
    /// "first tick for this pid" (an honest `nil` `cpuPercent`) rather
    /// than diffing against the exited process's ticks.
    private var previousSamples: [pid_t: RawSample] = [:]

    enum TopProcessesError: Error, LocalizedError {
        /// `proc_listallpids` itself failed — the whole domain is
        /// unreadable this tick.
        case listPidsFailed

        var errorDescription: String? {
            switch self {
            case .listPidsFailed: return "proc_listallpids failed"
            }
        }
    }

    func sample() throws -> [TopProcessReading] {
        let pids = try Self.listAllPids()
        let now = Date()

        var currentSamples: [pid_t: RawSample] = [:]
        currentSamples.reserveCapacity(pids.count)

        var readings: [TopProcessReading] = []
        readings.reserveCapacity(pids.count)

        for pid in pids {
            guard let taskInfo = Self.readTaskInfo(pid: pid) else { continue }

            // `pti_total_user`/`pti_total_system` come back from the
            // kernel already converted to nanoseconds (libproc's own
            // implementation runs them through `absolutetime_to_nanoseconds`
            // before returning), so this is a plain sum — no
            // `mach_timebase_info` conversion needed here, unlike
            // `host_processor_info`'s raw tick counts in `CPUProvider`.
            let cpuTimeNanoseconds = taskInfo.pti_total_user + taskInfo.pti_total_system
            currentSamples[pid] = RawSample(cpuTimeNanoseconds: cpuTimeNanoseconds, timestamp: now)

            var cpuPercent: Double?
            if let previous = previousSamples[pid] {
                let elapsedSeconds = now.timeIntervalSince(previous.timestamp)
                if elapsedSeconds > 0, cpuTimeNanoseconds >= previous.cpuTimeNanoseconds {
                    let deltaSeconds = Double(cpuTimeNanoseconds - previous.cpuTimeNanoseconds) / 1_000_000_000
                    cpuPercent = (deltaSeconds / elapsedSeconds) * 100
                }
            }

            readings.append(
                TopProcessReading(
                    pid: pid,
                    name: Self.processName(pid: pid),
                    cpuPercent: cpuPercent,
                    gpuPercent: nil,
                    memoryBytes: taskInfo.pti_resident_size
                )
            )
        }

        previousSamples = currentSamples
        return readings
    }

    // MARK: - libproc

    /// Lists every currently-running pid via `proc_listallpids`. That
    /// call's own convention (used both to size and fill the buffer) is
    /// ambiguous between "PID count" and "byte count" across the
    /// documentation that's floated around over the years, so this pads
    /// generously past the first call's estimate rather than trusting
    /// either reading exactly — cheap insurance (a few extra KB) against a
    /// silently truncated list, correct either way the estimate is meant.
    private static func listAllPids() throws -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { throw TopProcessesError.listPidsFailed }

        let capacity = Int(estimate) + 256
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytesFilled = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard bytesFilled > 0 else { throw TopProcessesError.listPidsFailed }

        let filledCount = min(Int(bytesFilled) / MemoryLayout<pid_t>.size, pids.count)
        return Array(pids[0..<filledCount])
    }

    /// `nil` when `proc_pidinfo` can't read this pid's task info this tick
    /// — e.g. it exited between `listAllPids()` and this call, or (for
    /// some other-user processes) permission is denied — rather than a
    /// zeroed struct standing in for real data.
    private static func readTaskInfo(pid: pid_t) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        guard result == size else { return nil }
        return info
    }

    /// Process display name: the executable path's last component when
    /// readable, falling back to `proc_name`'s short name, and `nil` (an
    /// honest "Unavailable") when neither syscall can read this pid.
    private static func processName(pid: pid_t) -> String? {
        // `4 * MAXPATHLEN` — the same size `<libproc.h>` names
        // `PROC_PIDPATHINFO_MAXSIZE` as, spelled out rather than relying
        // on that macro importing cleanly into Swift.
        var pathBuffer = [CChar](repeating: 0, count: 4 * 1024)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        if pathLength > 0 {
            let path = String(cString: pathBuffer)
            let lastComponent = URL(fileURLWithPath: path).lastPathComponent
            if !lastComponent.isEmpty { return lastComponent }
        }

        // `proc_name`'s buffer only needs to hold `2 * MAXCOMLEN` (32)
        // bytes per its own header comment; 64 leaves headroom.
        var nameBuffer = [CChar](repeating: 0, count: 64)
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        guard nameLength > 0 else { return nil }
        return String(cString: nameBuffer)
    }
}
