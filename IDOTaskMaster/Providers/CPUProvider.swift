import Darwin
import Foundation

/// One logical core's utilization as of a tick — PLAN.md §4 M2 "per-core
/// utilization". `id` is the core's index as reported by
/// `host_processor_info`, stable across ticks for the lifetime of the app
/// (macOS never hot-plugs CPUs), so it doubles as a `ForEach`/chart key.
///
/// Every reading is `nil` on the very first tick after launch (there is no
/// prior sample to diff against yet) rather than a guessed `0%` — see
/// `CPUProvider`'s doc comment.
struct CoreUtilization: Sendable, Equatable, Identifiable {
    let id: Int
    /// Busy percentage (user + system + nice), `0...100`.
    let totalUtilization: Double?
    let userUtilization: Double?
    let systemUtilization: Double?
    let idleUtilization: Double?
}

/// Static CPU topology — PLAN.md §4 M2 "core topology" and §1.1's Performance
/// CPU detail "static info (base speed, cores, sockets, ...)". Queried once
/// via `sysctlbyname` and cached by `CPUProvider` rather than re-read every
/// tick, since none of this changes while the app is running.
///
/// `performanceCoreCount`/`efficiencyCoreCount` are Apple silicon's P/E
/// split (`hw.perflevel0/1.physicalcpu`); Intel Macs don't expose those
/// sysctls, so both come back `nil` there — an honest "Unavailable" rather
/// than a guess, matching PLAN.md §2's "Apple silicon first, Intel
/// best-effort".
struct CPUTopology: Sendable, Equatable {
    let logicalCoreCount: Int?
    let physicalCoreCount: Int?
    let performanceCoreCount: Int?
    let efficiencyCoreCount: Int?
    /// Socket count (`hw.packages`) — always `1` on every Mac this app
    /// targets, but read rather than assumed.
    let packageCount: Int?
    /// `machdep.cpu.brand_string` (Intel, e.g. "Intel(R) Core(TM) i9...");
    /// falls back to `hw.model` (Apple silicon, e.g. "Mac15,6") since
    /// `machdep.cpu.brand_string` isn't populated there.
    let brandString: String?
}

/// One tick's CPU reading — PLAN.md §4 M2's "total + per-core utilization,
/// user/system split, uptime, core topology", merged into `Snapshot.cpu`.
struct CPUSnapshot: Sendable, Equatable {
    /// Combined busy percentage across all logical cores, `0...100`.
    let totalUtilization: Double?
    let userUtilization: Double?
    let systemUtilization: Double?
    let idleUtilization: Double?
    /// One entry per logical core, ordered by `CoreUtilization.id`.
    let perCoreUtilization: [CoreUtilization]
    /// Seconds since boot (`ProcessInfo.systemUptime`) — always available,
    /// so this is the one field on this type that's never `nil`.
    let uptime: TimeInterval
    let topology: CPUTopology
}

/// Failure modes for `CPUProvider.sample()` — see `Provider`'s doc comment
/// for when a provider throws versus returning `nil` fields.
enum CPUProviderError: Error, LocalizedError {
    /// `host_processor_info` itself failed — the whole domain is
    /// unreadable this tick.
    case hostProcessorInfoFailed(kernReturn: kern_return_t)

    var errorDescription: String? {
        switch self {
        case .hostProcessorInfoFailed(let kernReturn):
            return "host_processor_info failed (kern_return_t \(kernReturn))"
        }
    }
}

/// Samples CPU utilization, uptime, and core topology — PLAN.md §3
/// `Providers/CPUProvider.swift "host_processor_info per-core ticks,
/// uptime, sysctl"` and §4 M2's first task.
///
/// A `final class`, not a `struct`: `host_processor_info` reports
/// cumulative tick counts since boot, not an instantaneous rate, so
/// computing a percentage needs the *previous* tick's raw counts to diff
/// against. `previousCoreTicks` is that carried-forward state. `Sampler`
/// owns one long-lived `CPUProvider` instance and calls `sample()` every
/// tick from its own actor-isolated `tick()`, so this mutable state is
/// never touched concurrently — no locking needed.
final class CPUProvider: Provider {
    static let providerID = "cpu"

    /// Raw cumulative tick counts from the previous successful sample, one
    /// per logical core. `nil` before the first sample (nothing to diff
    /// against yet) and again after a failed sample (see `sample()`), so a
    /// stale prior count is never diffed against a fresh one across a gap.
    private var previousCoreTicks: [CoreTicks]?

    /// Topology never changes at runtime (macOS doesn't hot-plug CPUs) —
    /// read once via `sysctlbyname` on first access and reused for the
    /// life of this provider rather than re-queried every tick.
    private lazy var cachedTopology: CPUTopology = Self.readTopology()

    func sample() throws -> CPUSnapshot {
        let topology = cachedTopology
        let uptime = ProcessInfo.processInfo.systemUptime

        let currentTicks: [CoreTicks]
        do {
            currentTicks = try Self.readCoreTicks()
        } catch {
            // Whole domain unreadable this tick — clear any prior sample so
            // a later recovery doesn't diff against now-stale counts across
            // the gap, and propagate so `Sampler` marks CPU `.degraded`.
            previousCoreTicks = nil
            throw error
        }

        defer { previousCoreTicks = currentTicks }

        guard let previousCoreTicks, previousCoreTicks.count == currentTicks.count else {
            // First tick since launch (or, in principle, a core-count
            // change) — no prior counts to diff, so utilization is
            // honestly "Unavailable" this one tick rather than derived
            // from ticks-since-boot. Topology and uptime are still real.
            return CPUSnapshot(
                totalUtilization: nil,
                userUtilization: nil,
                systemUtilization: nil,
                idleUtilization: nil,
                perCoreUtilization: currentTicks.map {
                    CoreUtilization(id: $0.index, totalUtilization: nil, userUtilization: nil, systemUtilization: nil, idleUtilization: nil)
                },
                uptime: uptime,
                topology: topology
            )
        }

        let perCore: [CoreUtilization] = zip(previousCoreTicks, currentTicks).map { previous, current in
            let percentages = CoreTicks.percentages(from: previous, to: current)
            return CoreUtilization(
                id: current.index,
                totalUtilization: percentages?.total,
                userUtilization: percentages?.user,
                systemUtilization: percentages?.system,
                idleUtilization: percentages?.idle
            )
        }

        let aggregate = CoreTicks.aggregatePercentages(from: previousCoreTicks, to: currentTicks)

        return CPUSnapshot(
            totalUtilization: aggregate?.total,
            userUtilization: aggregate?.user,
            systemUtilization: aggregate?.system,
            idleUtilization: aggregate?.idle,
            perCoreUtilization: perCore,
            uptime: uptime,
            topology: topology
        )
    }

    // MARK: - host_processor_info

    /// Raw cumulative tick counts for one logical core, as reported by
    /// `host_processor_info(_:PROCESSOR_CPU_LOAD_INFO:...)`.
    private struct CoreTicks {
        let index: Int
        let user: UInt32
        let system: UInt32
        let idle: UInt32
        let nice: UInt32

        /// Percentages for one core between two samples, or `nil` if the
        /// combined tick delta is `0` (no time elapsed / a stalled clock —
        /// avoids a divide-by-zero rather than reporting a fabricated
        /// number).
        static func percentages(from previous: CoreTicks, to current: CoreTicks) -> (total: Double, user: Double, system: Double, idle: Double)? {
            deltasToPercentages(
                userDelta: wrappingDelta(current.user, previous.user),
                systemDelta: wrappingDelta(current.system, previous.system),
                idleDelta: wrappingDelta(current.idle, previous.idle),
                niceDelta: wrappingDelta(current.nice, previous.nice)
            )
        }

        /// Combined percentages across every core, computed from summed
        /// tick deltas (not an average of per-core percentages) so a
        /// core with more elapsed ticks isn't under- or over-weighted.
        static func aggregatePercentages(from previous: [CoreTicks], to current: [CoreTicks]) -> (total: Double, user: Double, system: Double, idle: Double)? {
            var userDelta: UInt64 = 0
            var systemDelta: UInt64 = 0
            var idleDelta: UInt64 = 0
            var niceDelta: UInt64 = 0
            for (prev, curr) in zip(previous, current) {
                userDelta += wrappingDelta(curr.user, prev.user)
                systemDelta += wrappingDelta(curr.system, prev.system)
                idleDelta += wrappingDelta(curr.idle, prev.idle)
                niceDelta += wrappingDelta(curr.nice, prev.nice)
            }
            return deltasToPercentages(userDelta: userDelta, systemDelta: systemDelta, idleDelta: idleDelta, niceDelta: niceDelta)
        }

        /// `current - previous` as a wrapping subtraction: `host_processor_info`
        /// ticks are cumulative `UInt32` counters that (very rarely, after
        /// several hundred days of uptime) wrap back to `0`. Wrapping
        /// subtraction still yields the correct single-wrap delta rather
        /// than a huge or negative one.
        private static func wrappingDelta(_ current: UInt32, _ previous: UInt32) -> UInt64 {
            UInt64(current &- previous)
        }

        private static func deltasToPercentages(userDelta: UInt64, systemDelta: UInt64, idleDelta: UInt64, niceDelta: UInt64) -> (total: Double, user: Double, system: Double, idle: Double)? {
            let totalDelta = userDelta + systemDelta + idleDelta + niceDelta
            guard totalDelta > 0 else { return nil }
            let busyDelta = userDelta + systemDelta + niceDelta
            let scale = 100 / Double(totalDelta)
            return (
                total: Double(busyDelta) * scale,
                user: Double(userDelta) * scale,
                system: Double(systemDelta) * scale,
                idle: Double(idleDelta) * scale
            )
        }
    }

    /// Reads current cumulative tick counts for every logical core via
    /// `host_processor_info`. Throws `CPUProviderError` on any kernel
    /// failure rather than returning a partial/zeroed array.
    private static func readCoreTicks() throws -> [CoreTicks] {
        var processorCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &cpuInfo,
            &cpuInfoCount
        )

        guard result == KERN_SUCCESS, let info = cpuInfo else {
            throw CPUProviderError.hostProcessorInfoFailed(kernReturn: result)
        }
        defer {
            let size = vm_size_t(Int(cpuInfoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        var ticks: [CoreTicks] = []
        ticks.reserveCapacity(Int(processorCount))
        for index in 0..<Int(processorCount) {
            let base = index * Int(CPU_STATE_MAX)
            // Tick counts are always non-negative, but `integer_t` (Int32)
            // can in principle read back negative after a wrap; reinterpret
            // the bits as unsigned rather than trapping on a signed
            // conversion.
            ticks.append(
                CoreTicks(
                    index: index,
                    user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                    system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                    idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                    nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
                )
            )
        }
        return ticks
    }

    // MARK: - Topology (sysctl)

    private static func readTopology() -> CPUTopology {
        CPUTopology(
            logicalCoreCount: sysctlInt("hw.logicalcpu"),
            physicalCoreCount: sysctlInt("hw.physicalcpu"),
            performanceCoreCount: sysctlInt("hw.perflevel0.physicalcpu"),
            efficiencyCoreCount: sysctlInt("hw.perflevel1.physicalcpu"),
            packageCount: sysctlInt("hw.packages"),
            brandString: sysctlString("machdep.cpu.brand_string") ?? sysctlString("hw.model")
        )
    }

    /// Reads an integer `sysctlbyname` key, or `nil` when the key doesn't
    /// exist on this Mac (e.g. `hw.perflevel0.physicalcpu` on Intel) rather
    /// than a guessed value.
    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
