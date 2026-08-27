import Foundation
import IOKit

/// One physical block-storage device's reading as of a tick — PLAN.md §4
/// M2's "% active, R/W rates, totals ... via IOBlockStorageDriver". `id` is
/// the device's BSD name (e.g. `"disk0"`), read from its whole-disk
/// `IOMedia` child and stable for the life of the app (macOS assigns BSD
/// names at attach time and doesn't renumber a still-attached disk), so it
/// doubles as a `ForEach`/chart key and as the dictionary key
/// `DiskProvider` diffs successive ticks against.
struct DiskUnitSnapshot: Sendable, Equatable, Identifiable {
    let id: String
    /// Best-effort friendly label for the device, read from the registry
    /// name of the `IOBlockStorageDriver`'s parent (the protocol-specific
    /// device nub, e.g. an NVMe or AHCI device object). This is often a
    /// driver class name rather than a marketing model string — IOKit
    /// doesn't publish one uniformly — so it's shown as a best-effort label,
    /// not asserted as the disk's product name. `nil` when even that lookup
    /// fails.
    let mediaName: String?
    /// Whether the device's `Device Characteristics` dictionary reports a
    /// `"Physical Interconnect Location"` of `"Internal"`. `nil` (honest
    /// "Unavailable", not a guess) when the driver doesn't publish that key
    /// — true of some external enclosures and virtual devices.
    let isInternal: Bool?
    /// Percentage of wall-clock time this device spent servicing I/O since
    /// the previous tick, derived from the delta of
    /// `IOBlockStorageDriver`'s cumulative `"Total Time (Read)"` +
    /// `"Total Time (Write)"` nanosecond counters against the elapsed
    /// wall-clock time — the same technique `iostat`-style tools use for
    /// "% active". Clamped to `0...100`: with multiple requests in flight
    /// the accumulated service time can in principle exceed elapsed time,
    /// and clamping is preferred over surfacing a number nobody could act
    /// on. `nil` on the first tick after launch (or the first tick after
    /// this device appeared) — there is no prior sample to diff against.
    let activePercent: Double?
    /// Bytes read since the previous tick, divided by the elapsed seconds.
    /// `nil` on the first tick after launch for the same reason as
    /// `activePercent`.
    let readBytesPerSecond: Double?
    let writeBytesPerSecond: Double?
    /// Cumulative bytes read/written since boot (`IOBlockStorageDriver`'s
    /// `"Bytes (Read)"`/`"Bytes (Write)"`), and cumulative operation counts
    /// (`"Operations (Read)"`/`"Operations (Write)"`) — always real values,
    /// never `nil`, since a unit with no `Statistics` dictionary at all is
    /// dropped before a `DiskUnitSnapshot` is built for it (see
    /// `DiskProvider.readUnit`).
    let totalBytesRead: UInt64
    let totalBytesWritten: UInt64
    let totalReadOperations: UInt64
    let totalWriteOperations: UInt64
}

/// One mounted volume's storage capacity — PLAN.md §4 M2's "capacity".
/// Read via `FileManager`/`URLResourceValues` rather than
/// `IOBlockStorageDriver`: free/used space is a filesystem-level concept
/// (and, on APFS, shared across every volume in a container), not something
/// the block-storage driver — which only sees raw device I/O — knows
/// anything about.
struct DiskCapacity: Sendable, Equatable, Identifiable {
    /// The volume's mount point path (e.g. `"/"`, `"/System/Volumes/Data"`)
    /// — stable for a given mount and a natural `Identifiable` key.
    let id: String
    let volumeName: String?
    /// `true` when this volume is mounted at `/` — the boot volume, i.e.
    /// PLAN.md §1.1's Disks detail "system-disk flag".
    let isSystemVolume: Bool
    /// `URLResourceKey.volumeTotalCapacityKey`. `nil` when this volume
    /// doesn't report one (some network/virtual mounts don't).
    let totalBytes: UInt64?
    /// `URLResourceKey.volumeAvailableCapacityForImportantUsageKey` — macOS's
    /// purgeable-aware "available" figure (what Finder's "available" tends
    /// to track on APFS, unlike the more conservative
    /// `volumeAvailableCapacityKey`). `nil` when unreadable.
    let availableBytes: UInt64?
    /// `totalBytes - availableBytes`. Not a true "occupied on disk" figure
    /// (APFS purgeable/snapshot space blurs that line), just the
    /// straightforward complement of the two fields above; `nil` whenever
    /// either input is `nil` or would underflow.
    var usedBytes: UInt64? {
        guard let totalBytes, let availableBytes, totalBytes >= availableBytes else { return nil }
        return totalBytes - availableBytes
    }
}

/// One tick's disk reading — PLAN.md §4 M2's "% active, R/W rates, totals,
/// capacity via IOBlockStorageDriver", merged into `Snapshot.disk`.
///
/// The top-level `activePercent`/`readBytesPerSecond`/`writeBytesPerSecond`
/// fields are a headline figure for the Summary/Performance pages' combined
/// "Disks" tile (PLAN.md §1.1): `activePercent` mirrors whichever unit in
/// `units` is the internal system disk (falling back to the first unit
/// found if none is known-internal — most Macs have exactly one physical
/// disk anyway), while the rate fields are the *sum* of every unit's rate
/// so a busy external drive still shows up in the combined throughput. Full
/// per-device detail lives in `units` for a future per-disk selector UI
/// (PLAN.md §1.1's Performance "Disks detail").
struct DiskSnapshot: Sendable, Equatable {
    /// See this type's doc comment — the internal/primary disk's
    /// `activePercent`, or `nil` on the first tick / if no unit could
    /// compute one yet.
    let activePercent: Double?
    /// Sum of every unit's `readBytesPerSecond` that had one to report;
    /// `nil` only when *no* unit had a prior sample to diff against yet
    /// (i.e. this is the very first tick).
    let readBytesPerSecond: Double?
    let writeBytesPerSecond: Double?
    /// Sum of every unit's cumulative bytes read/written since boot.
    let totalBytesRead: UInt64
    let totalBytesWritten: UInt64
    /// One entry per physical block-storage device found in the IORegistry
    /// this tick.
    let units: [DiskUnitSnapshot]
    /// One entry per mounted, non-hidden volume.
    let volumes: [DiskCapacity]
}

/// Failure modes for `DiskProvider.sample()` — see `Provider`'s doc comment
/// for when a provider throws versus returning `nil` fields.
enum DiskProviderError: Error, LocalizedError {
    case matchingDictionaryCreationFailed
    case serviceLookupFailed(kernReturn: kern_return_t)
    /// The lookup succeeded but found no `IOBlockStorageDriver` at all —
    /// shouldn't happen on real Mac hardware, but treated as the domain
    /// being entirely unreadable this tick, matching `GPUProvider`'s
    /// `noAcceleratorFound`.
    case noBlockStorageDriversFound

    var errorDescription: String? {
        switch self {
        case .matchingDictionaryCreationFailed:
            return "IOServiceMatching(\"IOBlockStorageDriver\") returned nil"
        case .serviceLookupFailed(let kernReturn):
            return "IOServiceGetMatchingServices failed (kern_return_t \(kernReturn))"
        case .noBlockStorageDriversFound:
            return "No IOBlockStorageDriver service found in the IORegistry"
        }
    }
}

/// Samples disk activity, transfer rates, and capacity — PLAN.md §3
/// `Providers/DiskProvider.swift "IOBlockStorageDriver statistics,
/// capacity"` and §4 M2's fourth task.
///
/// Every physical block device on macOS is fronted by an
/// `IOBlockStorageDriver` instance (one per protocol adapter — NVMe, AHCI,
/// a USB/Thunderbolt enclosure's bridge, ...), which continuously
/// republishes a `"Statistics"` property dictionary of cumulative
/// since-boot counters: bytes transferred, operation counts, and total
/// service time. This provider matches every such driver in the IORegistry,
/// reads that dictionary, and diffs it against the previous tick's reading
/// to derive rates and "% active" — the same technique `iostat` and
/// Activity Monitor's own Disk tab use, since Apple doesn't publish an
/// instantaneous-rate API. Capacity, a filesystem- not device-level
/// concept, comes from `FileManager`/`URLResourceValues` instead (see
/// `DiskCapacity`).
///
/// The `Statistics` dictionary's key strings (`"Bytes (Read)"`, `"Total
/// Time (Write)"`, ...) are `IOBlockStorageDriver.h`'s documented
/// `kIOBlockStorageDriverStatistics...Key` constants, hardcoded here as
/// literals rather than imported: that header lives under
/// `IOKit/storage/`, which isn't part of the umbrella `IOKit` Swift module
/// the way the core `IOKitLib.h` registry functions are.
///
/// A `final class`, matching `CPUProvider`'s convention and for the same
/// reason: `previousUnitStates` carries each device's raw cumulative
/// counters and a timestamp forward so the *next* tick can diff against
/// them. `Sampler` owns one long-lived instance and calls `sample()` every
/// tick from its own actor-isolated `tick()`, so this mutable state is
/// never touched concurrently — no locking needed.
final class DiskProvider: Provider {
    static let providerID = "disk"

    /// Raw cumulative counters from each device's previous successful
    /// sample, keyed by BSD name. Missing entries (a device seen for the
    /// first time, or a full reset after a domain-wide failure) simply
    /// produce `nil` rates/`activePercent` for that unit this tick — the
    /// same "no prior sample, honestly `nil`" rule `CPUProvider` follows.
    private var previousUnitStates: [String: DiskUnitRawState] = [:]

    func sample() throws -> DiskSnapshot {
        let rawUnits: [RawDiskUnit]
        do {
            rawUnits = try Self.readBlockStorageUnits()
        } catch {
            // Whole domain unreadable this tick — clear prior state so a
            // later recovery doesn't diff against now-stale counts,
            // matching CPUProvider's handling of its own core-read failure.
            previousUnitStates = [:]
            throw error
        }

        let now = Date()
        var newStates: [String: DiskUnitRawState] = [:]
        newStates.reserveCapacity(rawUnits.count)

        var unitSnapshots: [DiskUnitSnapshot] = []
        unitSnapshots.reserveCapacity(rawUnits.count)

        var totalBytesRead: UInt64 = 0
        var totalBytesWritten: UInt64 = 0
        var summedReadRate: Double = 0
        var summedWriteRate: Double = 0
        var haveAnyRate = false

        for unit in rawUnits {
            totalBytesRead += unit.bytesRead
            totalBytesWritten += unit.bytesWritten

            newStates[unit.bsdName] = DiskUnitRawState(
                bytesRead: unit.bytesRead,
                bytesWritten: unit.bytesWritten,
                totalTimeNs: unit.totalTimeNs,
                timestamp: now
            )

            var readRate: Double?
            var writeRate: Double?
            var activePercent: Double?

            if let previous = previousUnitStates[unit.bsdName] {
                let elapsed = now.timeIntervalSince(previous.timestamp)
                if elapsed > 0,
                   let readDelta = Self.nonNegativeDelta(unit.bytesRead, previous.bytesRead),
                   let writeDelta = Self.nonNegativeDelta(unit.bytesWritten, previous.bytesWritten) {
                    let computedReadRate = Double(readDelta) / elapsed
                    let computedWriteRate = Double(writeDelta) / elapsed
                    readRate = computedReadRate
                    writeRate = computedWriteRate
                    summedReadRate += computedReadRate
                    summedWriteRate += computedWriteRate
                    haveAnyRate = true
                }
                if elapsed > 0, let timeDelta = Self.nonNegativeDelta(unit.totalTimeNs, previous.totalTimeNs) {
                    let elapsedNanoseconds = elapsed * 1_000_000_000
                    activePercent = min(100, max(0, (Double(timeDelta) / elapsedNanoseconds) * 100))
                }
            }

            unitSnapshots.append(
                DiskUnitSnapshot(
                    id: unit.bsdName,
                    mediaName: unit.mediaName,
                    isInternal: unit.isInternal,
                    activePercent: activePercent,
                    readBytesPerSecond: readRate,
                    writeBytesPerSecond: writeRate,
                    totalBytesRead: unit.bytesRead,
                    totalBytesWritten: unit.bytesWritten,
                    totalReadOperations: unit.readOperations,
                    totalWriteOperations: unit.writeOperations
                )
            )
        }

        previousUnitStates = newStates

        // Headline activePercent: the internal disk if one is known, else
        // whichever unit was found first (see this type's doc comment).
        let headlineUnit = unitSnapshots.first { $0.isInternal == true } ?? unitSnapshots.first

        return DiskSnapshot(
            activePercent: headlineUnit?.activePercent,
            readBytesPerSecond: haveAnyRate ? summedReadRate : nil,
            writeBytesPerSecond: haveAnyRate ? summedWriteRate : nil,
            totalBytesRead: totalBytesRead,
            totalBytesWritten: totalBytesWritten,
            units: unitSnapshots,
            volumes: Self.readVolumeCapacities()
        )
    }

    // MARK: - Per-tick diff state

    private struct DiskUnitRawState {
        let bytesRead: UInt64
        let bytesWritten: UInt64
        let totalTimeNs: UInt64
        let timestamp: Date
    }

    /// One device's raw reading for a single tick, before it's diffed
    /// against the previous tick to produce a `DiskUnitSnapshot`.
    private struct RawDiskUnit {
        let bsdName: String
        let mediaName: String?
        let isInternal: Bool?
        let bytesRead: UInt64
        let bytesWritten: UInt64
        let readOperations: UInt64
        let writeOperations: UInt64
        /// `"Total Time (Read)"` + `"Total Time (Write)"`, nanoseconds.
        let totalTimeNs: UInt64
    }

    // MARK: - IORegistry lookup

    /// Iterates every `IOBlockStorageDriver` service in the IORegistry and
    /// reads a `RawDiskUnit` for each one that has both a `Statistics`
    /// dictionary and a discoverable BSD name; drivers missing either are
    /// silently skipped (not every registered driver necessarily has a
    /// media object attached at every instant). Throws when the lookup
    /// itself fails at the kernel level, or succeeds but finds nothing —
    /// both this domain's "entirely unreadable this tick" case.
    private static func readBlockStorageUnits() throws -> [RawDiskUnit] {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else {
            throw DiskProviderError.matchingDictionaryCreationFailed
        }

        var iterator: io_iterator_t = 0
        let lookupResult = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard lookupResult == KERN_SUCCESS else {
            throw DiskProviderError.serviceLookupFailed(kernReturn: lookupResult)
        }
        defer { IOObjectRelease(iterator) }

        var units: [RawDiskUnit] = []
        var driver = IOIteratorNext(iterator)
        while driver != 0 {
            if let unit = readUnit(fromDriver: driver) {
                units.append(unit)
            }
            IOObjectRelease(driver)
            driver = IOIteratorNext(iterator)
        }

        guard !units.isEmpty else {
            throw DiskProviderError.noBlockStorageDriversFound
        }
        return units
    }

    /// Reads one `IOBlockStorageDriver` service's `Statistics` dictionary
    /// and its whole-disk `IOMedia` child's BSD name. Returns `nil` (rather
    /// than a partially-populated unit) when either is missing.
    private static func readUnit(fromDriver driver: io_service_t) -> RawDiskUnit? {
        var propertiesUnmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(driver, &propertiesUnmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let driverProperties = propertiesUnmanaged?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        guard let statistics = driverProperties["Statistics"] as? [String: Any] else {
            return nil
        }
        guard let bsdName = findWholeMediaBSDName(childOf: driver) else {
            return nil
        }

        let totalReadTimeNs = uint64Value(statistics["Total Time (Read)"]) ?? 0
        let totalWriteTimeNs = uint64Value(statistics["Total Time (Write)"]) ?? 0

        return RawDiskUnit(
            bsdName: bsdName,
            mediaName: readMediaName(driver: driver),
            isInternal: readIsInternal(driverProperties: driverProperties),
            bytesRead: uint64Value(statistics["Bytes (Read)"]) ?? 0,
            bytesWritten: uint64Value(statistics["Bytes (Write)"]) ?? 0,
            readOperations: uint64Value(statistics["Operations (Read)"]) ?? 0,
            writeOperations: uint64Value(statistics["Operations (Write)"]) ?? 0,
            totalTimeNs: totalReadTimeNs + totalWriteTimeNs
        )
    }

    /// Finds the driver's whole-disk `IOMedia` child (its immediate
    /// `IOMedia`-conforming child in the service plane — partitions sit
    /// further below, under an `IOPartitionScheme` child of that whole-disk
    /// media, so they're never reached here) and reads its `"BSD Name"`.
    private static func findWholeMediaBSDName(childOf service: io_service_t) -> String? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var result: String?
        var child = IOIteratorNext(iterator)
        while child != 0 {
            if result == nil, IOObjectConformsTo(child, "IOMedia") != 0 {
                var propertiesUnmanaged: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(child, &propertiesUnmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let properties = propertiesUnmanaged?.takeRetainedValue() as? [String: Any],
                   let bsdName = properties["BSD Name"] as? String {
                    result = bsdName
                }
            }
            IOObjectRelease(child)
            child = IOIteratorNext(iterator)
        }
        return result
    }

    /// `nil` unless the driver's own properties carry a `"Device
    /// Characteristics"` dictionary with a `"Physical Interconnect
    /// Location"` string — see `DiskUnitSnapshot.isInternal`.
    private static func readIsInternal(driverProperties: [String: Any]) -> Bool? {
        guard let deviceCharacteristics = driverProperties["Device Characteristics"] as? [String: Any],
              let location = deviceCharacteristics["Physical Interconnect Location"] as? String else {
            return nil
        }
        return location == "Internal"
    }

    /// Best-effort label — see `DiskUnitSnapshot.mediaName`. Reads the
    /// registry name of the driver's parent entry (the protocol-specific
    /// device nub), releasing the extra reference `IORegistryEntryGetParentEntry`
    /// hands back.
    private static func readMediaName(driver: io_service_t) -> String? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(driver, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else {
            return nil
        }
        defer { IOObjectRelease(parent) }
        return registryEntryName(parent)
    }

    private static func registryEntryName(_ entry: io_registry_entry_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Volume capacity (FileManager)

    /// One `DiskCapacity` per mounted, non-hidden volume — see
    /// `DiskCapacity`'s doc comment for why this reads from `FileManager`
    /// rather than IOKit. Never throws: an unreadable individual volume is
    /// simply omitted rather than failing the whole domain, since capacity
    /// is a secondary reading alongside the driver-backed activity/rate
    /// fields this provider's `sample()` already computed by this point.
    ///
    /// Not `private`: `BenchmarksPage`'s disk-target picker calls this
    /// directly for the same real, already-filtered volume list — a
    /// second `FileManager.mountedVolumeURLs` call of its own would just
    /// duplicate this exact filtering, and a full `sample()` would also
    /// pay for the IOKit block-storage enumeration this picker doesn't
    /// need.
    static func readVolumeCapacities() -> [DiskCapacity] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        guard let volumeURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }

        return volumeURLs.compactMap { url -> DiskCapacity? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return DiskCapacity(
                id: url.path,
                volumeName: values.volumeName,
                isSystemVolume: url.path == "/",
                totalBytes: nonNegativeUInt64(values.volumeTotalCapacity),
                availableBytes: nonNegativeUInt64(values.volumeAvailableCapacityForImportantUsage)
            )
        }
    }

    private static func nonNegativeUInt64(_ value: Int?) -> UInt64? {
        guard let value, value >= 0 else { return nil }
        return UInt64(value)
    }

    private static func nonNegativeUInt64(_ value: Int64?) -> UInt64? {
        guard let value, value >= 0 else { return nil }
        return UInt64(value)
    }

    // MARK: - Value coercion / delta helpers

    /// Same `NSNumber` coercion `GPUProvider` uses for its own IOKit
    /// dictionary reads. Negative readings (shouldn't occur for a byte/time
    /// counter, but a driver bug is not this provider's to paper over) come
    /// back `nil` rather than wrapping to a huge unsigned value.
    private static func uint64Value(_ any: Any?) -> UInt64? {
        guard let number = any as? NSNumber else { return nil }
        let raw = number.int64Value
        return raw >= 0 ? UInt64(raw) : nil
    }

    /// `current - previous`, or `nil` if `current < previous` — e.g. a
    /// device whose own counters reset (a hot-unplug/replug cycle can
    /// present as a "new" BSD name reusing an old dictionary key in rare
    /// cases). An honest "no rate this tick" beats a huge fabricated one
    /// from an unsigned underflow.
    private static func nonNegativeDelta(_ current: UInt64, _ previous: UInt64) -> UInt64? {
        current >= previous ? current - previous : nil
    }
}
