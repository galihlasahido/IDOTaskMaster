import Darwin
import Foundation

/// Physical memory pressure bucket, as classified by the kernel — PLAN.md
/// §4 M2's "... pressure" and §1.1's Memory detail "pressure". Read from
/// the `kern.memorystatus_vm_pressure_level` sysctl, the same counter that
/// backs `DispatchSource.makeMemoryPressureSource` and the `memory_pressure`
/// CLI tool; its raw values (`1`/`2`/`4`) line up with
/// `DISPATCH_MEMORYPRESSURE_NORMAL`/`_WARN`/`_CRITICAL`.
enum MemoryPressureLevel: Sendable, Equatable {
    case normal
    case warning
    case critical
}

/// One tick's memory reading — PLAN.md §4 M2's "used/cached/swap/pressure
/// via `vm_statistics64` + sysctl", merged into `Snapshot.memory`.
///
/// The byte breakdowns come straight from `vm_statistics64`'s page counts
/// (times the runtime page size), not a reverse-engineered match to
/// Activity Monitor's "App Memory" bucket — Apple has never published the
/// exact formula behind that number, and guessing at it would violate
/// PLAN.md's "honest degradation, never fake data". `usedBytes`,
/// `cachedBytes`, and `availableBytes` are simple, documented combinations
/// of the raw counts (see each field), not an attempt to reproduce Activity
/// Monitor's exact figures.
struct MemorySnapshot: Sendable, Equatable {
    /// Total installed physical memory (`hw.memsize`). `nil` only if that
    /// sysctl is unreadable, which doesn't happen on any real Mac.
    let totalBytes: UInt64?
    /// Pages holding nothing at all. `vm_statistics64`'s own header notes
    /// that `free_count` already includes speculative (unread readahead)
    /// pages, so this is `free_count - speculative_count` — truly idle
    /// memory, not merely-unused-so-far memory.
    let freeBytes: UInt64
    /// Resident, file-backed pages (`external_page_count`) — the closest
    /// analogue to Activity Monitor's "Cached Files": reclaimable without
    /// writing anything out, since their backing file already holds the
    /// data.
    let cachedBytes: UInt64
    /// `totalBytes - freeBytes`: every physical page that isn't
    /// immediately free (active + inactive + wired + compressed +
    /// speculative + purgeable, combined). `nil` when `totalBytes` is
    /// unavailable, since there's nothing to subtract it from.
    let usedBytes: UInt64?
    /// `freeBytes + cachedBytes` — memory the system could put to new use
    /// right now without touching swap.
    let availableBytes: UInt64
    let activeBytes: UInt64
    let inactiveBytes: UInt64
    let wiredBytes: UInt64
    /// Bytes the compressor currently holds compressed data in
    /// (`compressor_page_count` pages) — distinct from `swapUsedBytes`,
    /// which is compressor segments actually written out to disk.
    let compressedBytes: UInt64
    let purgeableBytes: UInt64

    /// Swap fields are read together from one `vm.swapusage` sysctl call
    /// (see `MemoryProvider.readSwapUsage()`), so all three are `nil`
    /// together when that sysctl is unreadable — never a partial mix of
    /// real and missing swap numbers.
    let swapTotalBytes: UInt64?
    let swapUsedBytes: UInt64?
    let swapFreeBytes: UInt64?

    /// `nil` when the pressure sysctl is unreadable, or reports a raw value
    /// this app doesn't recognize — an honest "Unavailable" rather than
    /// guessing which bucket an unrecognized value belongs in.
    let pressureLevel: MemoryPressureLevel?
}

/// Failure mode for `MemoryProvider.sample()` — see `Provider`'s doc
/// comment for when a provider throws versus returning `nil` fields.
///
/// Only `host_statistics64` failing throws: it's the one reading this
/// provider treats as "the domain is unreadable this tick", matching
/// `CPUProvider`'s `host_processor_info`. `hw.memsize`, `vm.swapusage`, and
/// the pressure sysctl are each read independently afterward and simply
/// come back `nil` on failure — one of them being unreadable doesn't make
/// the others untrustworthy.
enum MemoryProviderError: Error, LocalizedError {
    case hostStatisticsFailed(kernReturn: kern_return_t)

    var errorDescription: String? {
        switch self {
        case .hostStatisticsFailed(let kernReturn):
            return "host_statistics64 failed (kern_return_t \(kernReturn))"
        }
    }
}

/// Samples memory usage, cache, swap, and pressure — PLAN.md §3
/// `Providers/MemoryProvider.swift "vm_statistics64, sysctl swap, memory
/// pressure"` and §4 M2's second task.
///
/// Unlike `CPUProvider`, every field here is an instantaneous reading —
/// `vm_statistics64`'s page counts describe current state, not
/// cumulative ticks-since-boot — so this provider carries no state across
/// samples. Still a `final class` rather than a `struct`, for consistency
/// with the other `Provider`s and because `Sampler` holds one long-lived
/// instance of it regardless.
final class MemoryProvider: Provider {
    static let providerID = "memory"

    func sample() throws -> MemorySnapshot {
        let stats = try Self.readVMStatistics()
        // `vm_page_size` is a runtime global populated by the OS before
        // any code runs (<mach/vm_page_size.h>) — reading it directly is
        // simpler than the `host_page_size` Mach call and, unlike that
        // call, has no failure mode to handle.
        let pageSize = UInt64(vm_page_size)

        let freeCount = UInt64(stats.free_count)
        let speculativeCount = UInt64(stats.speculative_count)
        let trulyFreeCount = freeCount > speculativeCount ? freeCount - speculativeCount : 0

        let freeBytes = trulyFreeCount * pageSize
        let cachedBytes = UInt64(stats.external_page_count) * pageSize
        let activeBytes = UInt64(stats.active_count) * pageSize
        let inactiveBytes = UInt64(stats.inactive_count) * pageSize
        let wiredBytes = UInt64(stats.wire_count) * pageSize
        let compressedBytes = UInt64(stats.compressor_page_count) * pageSize
        let purgeableBytes = UInt64(stats.purgeable_count) * pageSize

        let totalBytes = Self.sysctlUInt64("hw.memsize")
        let usedBytes = totalBytes.map { $0 > freeBytes ? $0 - freeBytes : 0 }
        let swap = Self.readSwapUsage()

        return MemorySnapshot(
            totalBytes: totalBytes,
            freeBytes: freeBytes,
            cachedBytes: cachedBytes,
            usedBytes: usedBytes,
            availableBytes: freeBytes + cachedBytes,
            activeBytes: activeBytes,
            inactiveBytes: inactiveBytes,
            wiredBytes: wiredBytes,
            compressedBytes: compressedBytes,
            purgeableBytes: purgeableBytes,
            swapTotalBytes: swap?.total,
            swapUsedBytes: swap?.used,
            swapFreeBytes: swap?.free,
            pressureLevel: Self.readPressureLevel()
        )
    }

    // MARK: - vm_statistics64

    /// Reads current page-count statistics via
    /// `host_statistics64(_:HOST_VM_INFO64:...)`. Throws
    /// `MemoryProviderError` on any kernel failure rather than returning a
    /// zeroed struct.
    private static func readVMStatistics() throws -> vm_statistics64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { statsPointer -> kern_return_t in
            statsPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw MemoryProviderError.hostStatisticsFailed(kernReturn: result)
        }
        return stats
    }

    // MARK: - sysctl: swap

    /// Reads `vm.swapusage` (`struct xsw_usage`), whose three fields are
    /// already byte counts (no page-size conversion needed). `nil` on any
    /// read failure, so all three swap fields come back `nil` together.
    private static func readSwapUsage() -> (total: UInt64, used: UInt64, free: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (total: usage.xsu_total, used: usage.xsu_used, free: usage.xsu_avail)
    }

    // MARK: - sysctl: pressure

    private static func readPressureLevel() -> MemoryPressureLevel? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else {
            return nil
        }
        switch value {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return nil
        }
    }

    // MARK: - sysctl: scalar helper

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
