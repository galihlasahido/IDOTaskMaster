import Foundation
import IOKit

/// One tick's GPU reading — PLAN.md §4 M2's "utilization, VRAM, temperature
/// via IOKit AGXAccelerator", merged into `Snapshot.gpu`.
///
/// Every field but `deviceClassName` is independently `nil`-able: the
/// `PerformanceStatistics` dictionary `GPUProvider` reads this from is an
/// undocumented, driver-defined bag of keys that varies by chip generation
/// and, on Intel Macs, by GPU vendor — a key simply being absent is this
/// domain's normal "honest degradation" case (PLAN.md §2/§3), not a
/// failure. See `GPUProvider`'s doc comment for which keys back which
/// field and why VRAM in particular is a soft concept on Apple silicon.
struct GPUSnapshot: Sendable, Equatable {
    /// The matched IOKit service's `IOClass` (e.g. `"AGXAcceleratorG13X"`
    /// on Apple silicon, `"AMDRadeonX6000"`/`"IntelAccelerator"` on Intel
    /// Macs) — the closest thing to a model name this reading exposes.
    /// Always non-`nil` when `sample()` returns at all: `GPUProvider`
    /// throws instead of returning a snapshot with no matched device (see
    /// `GPUProviderError.noAcceleratorFound`).
    let deviceClassName: String
    /// Overall busy percentage, `PerformanceStatistics["Device
    /// Utilization %"]`, `0...100`. This is the headline "GPU %" figure
    /// (PLAN.md §1.1's Summary "GPU 0 (model, %)" tile).
    let utilizationPercent: Double?
    /// `PerformanceStatistics["Renderer Utilization %"]` — one of the two
    /// per-engine readings the future Performance-page GPU "Engines" tab
    /// wants (PLAN.md §1.1: "renderer & tiler %").
    let rendererUtilizationPercent: Double?
    /// `PerformanceStatistics["Tiler Utilization %"]` — Apple's
    /// tile-based deferred renderer publishes this; discrete GPUs on
    /// Intel Macs generally don't, so it's commonly `nil` there.
    let tilerUtilizationPercent: Double?
    /// Bytes currently resident in the accelerator's working set,
    /// `PerformanceStatistics["In use system memory"]`. On Apple silicon
    /// this is **not** dedicated video memory — there is none; it's a
    /// slice of the same unified physical RAM `MemoryProvider` already
    /// accounts for — but it is the closest reading IOKit exposes to
    /// [name removed]'s "VRAM/memory usage" panel (PLAN.md §1.1), so it's surfaced
    /// under that name with this disclaimer rather than omitted outright.
    let vramUsedBytes: UInt64?
    /// Bytes allocated to the accelerator's working set,
    /// `PerformanceStatistics["Alloc system memory"]`. Same unified-memory
    /// caveat as `vramUsedBytes`.
    let vramAllocatedBytes: UInt64?
    /// Total dedicated video memory, when the accelerator publishes one —
    /// true of Intel Macs' discrete GPUs (read from a `"VRAM,totalMB"`
    /// property, or `vramFreeBytes + vramUsedBytes` when only those are
    /// present). Always `nil` on Apple silicon: there is no dedicated
    /// VRAM to total, an honest "Unavailable" rather than a guess.
    let vramTotalBytes: UInt64?
    /// GPU die temperature in Celsius, `PerformanceStatistics["Temperature(C)"]`
    /// — published by some discrete accelerators on Intel Macs. Apple's
    /// AGX accelerator does not publish a temperature key in this
    /// dictionary, so this reads `nil` (honest "Unavailable") on every
    /// Apple silicon Mac; an SoC GPU temperature is only reachable via SMC
    /// keys, which is `ThermalProvider`'s separate task (PLAN.md §4 M2),
    /// not this one.
    let temperatureCelsius: Double?
}

/// Failure modes for `GPUProvider.sample()` — see `Provider`'s doc comment
/// for when a provider throws versus returning `nil` fields.
enum GPUProviderError: Error, LocalizedError {
    /// `IOServiceMatching` itself returned `nil` — shouldn't happen for a
    /// well-formed class name, but handled rather than force-unwrapped.
    case matchingDictionaryCreationFailed
    /// `IOServiceGetMatchingServices` failed at the kernel level — the
    /// whole domain is unreadable this tick.
    case serviceLookupFailed(kernReturn: kern_return_t)
    /// The lookup succeeded but the IORegistry has no `IOAccelerator`
    /// conformer at all — no GPU driver is loaded/attached. Treated as the
    /// domain being entirely unreadable this tick (there is nothing to
    /// report), matching `CPUProvider`/`MemoryProvider`'s "throw when the
    /// core read fails" rule.
    case noAcceleratorFound

    var errorDescription: String? {
        switch self {
        case .matchingDictionaryCreationFailed:
            return "IOServiceMatching(\"IOAccelerator\") returned nil"
        case .serviceLookupFailed(let kernReturn):
            return "IOServiceGetMatchingServices failed (kern_return_t \(kernReturn))"
        case .noAcceleratorFound:
            return "No IOAccelerator service found in the IORegistry"
        }
    }
}

/// Samples GPU utilization, memory usage, and temperature via the IOKit
/// registry — PLAN.md §3 `Providers/GPUProvider.swift "IOKit AGXAccelerator
/// PerformanceStatistics"` and §4 M2's third task.
///
/// Apple doesn't publish a documented API for GPU telemetry; every macOS
/// system-monitor (Activity Monitor included) reads it the same
/// reverse-engineered way this provider does: the graphics driver
/// publishes an `IOAccelerator`-conforming IOKit service (`AGXAccelerator`
/// on Apple silicon; a vendor-specific class like `AMDRadeonX6000` or
/// `IntelAccelerator` on Intel Macs) whose registry entry carries a
/// `PerformanceStatistics` dictionary the driver refreshes continuously.
/// `GPUProvider` matches on the abstract `IOAccelerator` service class
/// (rather than hardcoding `"AGXAccelerator"`, whose exact suffix varies
/// per chip generation — `AGXAcceleratorG13X`, `...G14X`, etc.) so it keeps
/// working across generations, and prefers whichever matched service's
/// `IOClass` starts with `"AGXAccelerator"` when more than one is present,
/// falling back to the first other match otherwise — Apple silicon first,
/// Intel best-effort, per PLAN.md §2.
///
/// A `final class`, matching `CPUProvider`/`MemoryProvider`'s convention,
/// though this provider in fact carries no state across ticks: every field
/// here is an instantaneous reading straight out of the driver's own
/// dictionary, not something diffed against a previous tick.
final class GPUProvider: Provider {
    static let providerID = "gpu"

    func sample() throws -> GPUSnapshot {
        let (className, properties) = try Self.findAcceleratorProperties()
        let stats = properties["PerformanceStatistics"] as? [String: Any]

        return GPUSnapshot(
            deviceClassName: className,
            utilizationPercent: Self.doubleValue(stats?["Device Utilization %"]),
            rendererUtilizationPercent: Self.doubleValue(stats?["Renderer Utilization %"]),
            tilerUtilizationPercent: Self.doubleValue(stats?["Tiler Utilization %"]),
            vramUsedBytes: Self.uint64Value(stats?["In use system memory"]),
            vramAllocatedBytes: Self.uint64Value(stats?["Alloc system memory"]),
            vramTotalBytes: Self.readVRAMTotalBytes(stats: stats, properties: properties),
            temperatureCelsius: Self.doubleValue(stats?["Temperature(C)"])
        )
    }

    // MARK: - IORegistry lookup

    /// Iterates every `IOAccelerator`-conforming service in the IORegistry
    /// and returns the properties dictionary of the best match: an
    /// `AGXAccelerator*` class if one is present, otherwise the first
    /// match of any other class. Throws when the lookup itself fails at
    /// the kernel level, or when it succeeds but finds no accelerator at
    /// all — both are this domain's "entirely unreadable this tick" case
    /// (see `GPUProviderError`).
    private static func findAcceleratorProperties() throws -> (className: String, properties: [String: Any]) {
        guard let matching = IOServiceMatching("IOAccelerator") else {
            throw GPUProviderError.matchingDictionaryCreationFailed
        }

        var iterator: io_iterator_t = 0
        let lookupResult = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard lookupResult == KERN_SUCCESS else {
            throw GPUProviderError.serviceLookupFailed(kernReturn: lookupResult)
        }
        defer { IOObjectRelease(iterator) }

        var fallback: (className: String, properties: [String: Any])?

        var service = IOIteratorNext(iterator)
        while service != 0 {
            var propertiesUnmanaged: Unmanaged<CFMutableDictionary>?
            let propertiesResult = IORegistryEntryCreateCFProperties(service, &propertiesUnmanaged, kCFAllocatorDefault, 0)

            if propertiesResult == KERN_SUCCESS,
               let properties = propertiesUnmanaged?.takeRetainedValue() as? [String: Any] {
                let className = (properties["IOClass"] as? String) ?? "IOAccelerator"
                if className.hasPrefix("AGXAccelerator") {
                    IOObjectRelease(service)
                    return (className, properties)
                }
                if fallback == nil {
                    fallback = (className, properties)
                }
            }

            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        guard let fallback else {
            throw GPUProviderError.noAcceleratorFound
        }
        return fallback
    }

    /// Total dedicated video memory, when derivable. Tries a top-level
    /// `"VRAM,totalMB"` property first (seen on Intel Macs' discrete-GPU
    /// registry entries), then `vramFreeBytes + vramUsedBytes` inside
    /// `PerformanceStatistics` (seen on some vendor drivers that report
    /// free/used but no explicit total). Neither exists on Apple silicon,
    /// which has no dedicated VRAM — this correctly returns `nil` there.
    private static func readVRAMTotalBytes(stats: [String: Any]?, properties: [String: Any]) -> UInt64? {
        if let totalMB = doubleValue(properties["VRAM,totalMB"]) {
            return UInt64(totalMB * 1024 * 1024)
        }
        if let free = uint64Value(stats?["vramFreeBytes"]), let used = uint64Value(stats?["vramUsedBytes"]) {
            return free + used
        }
        return nil
    }

    // MARK: - CFDictionary value coercion

    /// IOKit registry properties come back from the `[String: Any]` bridge
    /// as `NSNumber` for every numeric key regardless of the driver's
    /// underlying C type (`UInt32`, `float`, ...); `NSNumber.doubleValue`
    /// coerces any of those uniformly. `nil` when the key is absent or its
    /// value isn't numeric.
    private static func doubleValue(_ any: Any?) -> Double? {
        (any as? NSNumber)?.doubleValue
    }

    /// Same coercion as `doubleValue`, for byte counts. Negative readings
    /// (shouldn't occur for a byte count, but a driver bug is not this
    /// provider's to paper over) come back `nil` rather than wrapping to
    /// a huge unsigned value.
    private static func uint64Value(_ any: Any?) -> UInt64? {
        guard let number = any as? NSNumber else { return nil }
        let raw = number.int64Value
        return raw >= 0 ? UInt64(raw) : nil
    }
}
