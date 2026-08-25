import Foundation
import IOKit

/// One tick's Apple Neural Engine (ANE) reading — PLAN.md §4 M2's "ANE state
/// where exposed; honest 'Unavailable' note otherwise", merged into
/// `Snapshot.npu`.
///
/// Unlike CPU/GPU, Apple publishes no `PerformanceStatistics`-style
/// utilization percentage for the ANE at all — see `NPUProvider`'s doc
/// comment for what *is* readable and why a calibrated "%"/watts figure
/// would be a guess this app refuses to make. Every field here is
/// independently optional/honest about that: `devicePresent` alone is
/// unconditionally reliable (a plain IORegistry lookup), everything else
/// degrades to `nil` with `unavailableReason` explaining why when the
/// richer IOReport-based reading isn't available.
struct NPUSnapshot: Sendable, Equatable {
    /// Whether this Mac's IORegistry has an `"ane0"` device at all — the
    /// most basic honest answer to "does this Mac have a Neural Engine".
    /// `false` on Intel Macs (no ANE silicon) and, in principle, inside
    /// some virtualized/reduced device trees; never a guess, since it's a
    /// direct `IOServiceGetMatchingService` presence check
    /// (`NPUProvider.deviceInfo()`).
    let devicePresent: Bool
    /// The device's IORegistry `name` property (expected `"ane0"` when
    /// `devicePresent`), decoded from the raw null-terminated `Data` the
    /// IODeviceTree plane stores it as. `nil` when `devicePresent` is
    /// `false`, or in the unexpected case the property itself is missing.
    let deviceName: String?
    /// The device's IORegistry `compatible` property (e.g. `"ane,t8020"`
    /// on this dev Mac, an M4 Max) — the closest thing to an ANE hardware
    /// generation id IORegistry exposes; not a documented public API, so
    /// treated purely as an informational string, not parsed for meaning.
    /// `nil` under the same conditions as `deviceName`.
    let compatibleString: String?
    /// This tick's increase in the IOReport `"Energy Model"` group's
    /// `"ANE"` channel accumulator, in that channel's native raw unit —
    /// **deliberately not converted to watts or a percentage**. See
    /// `NPUProvider`'s doc comment for why: Apple documents no conversion
    /// factor for this counter, and it's known (from public reverse
    /// engineering of Apple Silicon power tooling) to differ across SoC
    /// generations this app cannot verify on hardware it doesn't have —
    /// presenting a guessed watt figure would violate PLAN.md's honest-
    /// degradation rule (§2/§3: "surface Unavailable values instead of
    /// guesses") worse than simply not showing one. `nil` on the very
    /// first tick after this provider's IOReport subscription is created
    /// (no previous sample to diff against yet — same "first tick" case
    /// `NetworkSnapshot`'s rate fields document) or whenever
    /// `unavailableReason` explains a persistent failure.
    let energyDeltaRaw: UInt64?
    /// Whether the ANE did measurable work since the previous tick —
    /// `energyDeltaRaw.map { $0 > 0 }`. This is this provider's honest
    /// notion of "ANE state" (PLAN.md §1.1's Summary "NPU 0 (status)" tile
    /// and Performance page's "ANE ... blocks-powered state"): a coarse
    /// active/idle signal derived from a real counter, not a fabricated
    /// utilization percentage. `nil` under the same conditions as
    /// `energyDeltaRaw`. Note this can't distinguish "doing a little work"
    /// from "doing a lot" — see `NPUProvider`'s doc comment on why this
    /// provider stops at that honest boundary rather than guessing further.
    let isActive: Bool?
    /// Explains why `energyDeltaRaw`/`isActive` are (persistently, not
    /// just "first tick") `nil` — PLAN.md's "honest 'Unavailable' note"
    /// this task specifically calls for, surfaced verbatim by the future
    /// NPU detail page rather than a generic "Unavailable" label with no
    /// context. Also covers `deviceName`/`compatibleString` being `nil`
    /// when `devicePresent` is `false`. `nil` whenever nothing is wrong —
    /// including the ordinary "haven't collected a second sample yet"
    /// case, which isn't a failure.
    let unavailableReason: String?
}

/// Samples Apple Neural Engine (ANE) presence and activity — PLAN.md §3
/// `Providers/NPUProvider.swift "ANE state via IOReport where exposed;
/// else Unavailable"` and §4 M2's eighth task.
///
/// ## Why this domain is the hardest "honest degradation" case in M2
///
/// Every other M2 provider has *some* documented or at least widely-relied-
/// upon reverse-engineered source for a genuine utilization/wattage number
/// (`GPUProvider`'s `PerformanceStatistics`, `EnergyProvider`/
/// `ThermalProvider`'s AppleSMC keys). The ANE has neither: Apple ships no
/// `IOAccelerator`-style service for it and no SMC wattage key. The only
/// thing this dev Mac's real IORegistry/IOReport actually expose (verified
/// directly against an M4 Max running macOS 15.7.7 while building this
/// provider — the same "read it for real before trusting it" discipline
/// `ThermalProvider`'s SMC section documents) is:
///
/// 1. **Device presence**: an `AppleARMIODevice` IORegistry entry named
///    `"ane0"` (`IOServiceNameMatching("ane0")` finds it directly — no
///    class-name guessing needed). Its `name`/`compatible` properties come
///    back as raw null-terminated `Data`, not `CFString` (typical of
///    IODeviceTree-sourced properties) — `decodeDeviceTreeString` unpacks
///    that.
/// 2. **A cumulative ANE energy counter**, via the private `IOReport`
///    framework (`libIOReport.dylib` — no public header, so every symbol
///    below is resolved with `dlopen`/`dlsym`, matching this app's
///    AppleSMC provider's precedent of calling undocumented system APIs
///    directly rather than depending on a third-party wrapper). Verified
///    empirically on this dev Mac:
///    - `IOReportCopyChannelsInGroup("Energy Model", nil)` succeeds with no
///      root/entitlement requirement at all — unlike passing `nil` for the
///      group (which returns `NULL` even as root; this app doesn't rely on
///      that broader query), asking for one *named* group by string is
///      freely readable by an ordinary unsigned process.
///    - That group's channel list includes one named exactly `"ANE"`
///      alongside `"CPU Energy"`/`"GPU Energy"`/etc.
///    - `IOReportCreateSubscription` → `IOReportCreateSamples` (called
///      once per tick) → `IOReportCreateSamplesDelta` between this tick's
///      and the previous tick's sample → `IOReportSimpleGetIntegerValue`
///      on the delta's `"ANE"` channel yields a plausible non-negative
///      accumulator delta (confirmed non-zero and moving under an actual
///      ANE workload — 40 back-to-back `VNRecognizeTextRequest` passes via
///      Vision.framework — during this provider's development, and a
///      steady `0` while the Mac was otherwise idle).
///
/// What is **not** available, and is not guessed at: a documented unit for
/// that counter (public references to Apple Silicon power tooling disagree
/// on the scale factor across SoC generations, and this app has hardware
/// to verify exactly one), a per-core or per-workload utilization
/// breakdown, or a literal "blocks powered" count (PLAN.md §1.1: "Apple
/// Neural Engine blocks-powered state"). Converting the raw counter
/// into invented watts or a percentage
/// would be exactly the kind of guess PLAN.md's honest-degradation rule
/// forbids, so `NPUSnapshot` stops at the honest boundary: presence, a raw
/// (unconverted) energy-delta counter, and the binary active/idle signal
/// derived from it.
///
/// A `final class`, matching every other undocumented-API provider in this
/// codebase (`ThermalProvider`, `EnergyProvider`, `GPUProvider`): the
/// device-presence lookup, the `dlopen`'d function pointers, the IOReport
/// subscription, and the previous tick's sample are all opened/created
/// once and kept for this instance's lifetime rather than redone every
/// tick, and a failed first attempt at either stage is remembered so a Mac
/// without an ANE (or a future OS that locks this API down) doesn't retry
/// a doomed lookup every tick.
final class NPUProvider: Provider {
    static let providerID = "npu"

    // MARK: - Device presence (IORegistry, cached — device topology never changes at runtime)

    private var deviceLookupAttempted = false
    private var cachedDevice: (name: String?, compatible: String?)?

    // MARK: - IOReport (dlopen'd once, cached)

    private var ioReportSetupAttempted = false
    private var ioReportUnavailableReason: String?
    private var reportFunctions: IOReportFunctions?
    /// The live subscription handle IOReport hands back from
    /// `IOReportCreateSubscription`. Typed `AnyObject` (not a named CF
    /// type) because `libIOReport.dylib` ships no header declaring
    /// `IOReportSubscriptionRef`'s type — but it prints as a genuine
    /// `<IOReportSubscription ...>` CoreFoundation object (confirmed while
    /// building this provider) and is ARC/CF-toll-free-bridged like any
    /// other `Unmanaged<...>.takeRetainedValue()` result, so holding it as
    /// a plain stored property is sufficient for correct retain/release —
    /// no manual `CFRelease` needed in `deinit`.
    private var subscription: AnyObject?
    private var sampleChannels: CFMutableDictionary?
    /// The previous tick's raw sample, kept so this tick's
    /// `IOReportCreateSamplesDelta` has something to diff against. `nil`
    /// before the first successful sample — the ordinary "first tick, no
    /// rate yet" case `NPUSnapshot.energyDeltaRaw` documents.
    private var previousSample: CFDictionary?

    func sample() throws -> NPUSnapshot {
        let device = deviceInfoIfPresent()
        guard let device else {
            return NPUSnapshot(
                devicePresent: false,
                deviceName: nil,
                compatibleString: nil,
                energyDeltaRaw: nil,
                isActive: nil,
                unavailableReason: "No Apple Neural Engine device (\"ane0\") found in the IORegistry — this Mac's SoC has no ANE (e.g. an Intel Mac), or this environment exposes a reduced device tree."
            )
        }

        let (delta, reason) = readANEEnergyDelta()
        return NPUSnapshot(
            devicePresent: true,
            deviceName: device.name,
            compatibleString: device.compatible,
            energyDeltaRaw: delta,
            isActive: delta.map { $0 > 0 },
            unavailableReason: reason
        )
    }

    // MARK: - Device presence

    /// Looks up (and caches) the `"ane0"` IORegistry entry. Returns `nil`
    /// once, permanently, on a Mac with no such device — this domain's
    /// presence can't change while the app is running, so there's no
    /// reason to repeat a failed `IOServiceGetMatchingService` every tick
    /// (same "don't retry a doomed lookup" rule as
    /// `ThermalProvider.openSMCConnectionIfNeeded()`).
    ///
    /// Only queries `"ane0"` — the first/only ANE cluster on every Mac
    /// this app has been verified against. Some Ultra-class multi-die
    /// configurations are reported (in third-party reverse engineering,
    /// unverified here) to expose a second `"ane1"`; this provider doesn't
    /// enumerate it, an honest scope limit rather than a guess at a device
    /// this app can't confirm exists or behaves the same way.
    private func deviceInfoIfPresent() -> (name: String?, compatible: String?)? {
        if let cachedDevice { return cachedDevice }
        guard !deviceLookupAttempted else { return nil }
        deviceLookupAttempted = true

        guard let matching = IOServiceNameMatching("ane0") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var propertiesUnmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propertiesUnmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = propertiesUnmanaged?.takeRetainedValue() as? [String: Any] else {
            // The device exists but its properties couldn't be read — still
            // an honest "present, details unavailable" rather than "absent".
            let device = (name: Optional<String>.none, compatible: Optional<String>.none)
            cachedDevice = device
            return device
        }

        let device = (
            name: Self.decodeDeviceTreeString(properties["name"]),
            compatible: Self.decodeDeviceTreeString(properties["compatible"])
        )
        cachedDevice = device
        return device
    }

    /// IODeviceTree-sourced string properties (like `"ane0"`'s `name`/
    /// `compatible`) come back as raw null-terminated `Data`, not
    /// `CFString` — verified directly against this dev Mac's real
    /// IORegistry while building this provider (`name` read back the 5
    /// bytes `"ane0\0"`). Decodes up to the first `0x00` byte as UTF-8;
    /// `nil` when the property is absent or not `Data`.
    private static func decodeDeviceTreeString(_ any: Any?) -> String? {
        guard let data = any as? Data else { return nil }
        let bytes = data.prefix { $0 != 0 }
        guard !bytes.isEmpty else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - IOReport (private framework, dlopen'd — see this type's doc comment)

    /// Returns this tick's `"ANE"` energy-channel delta and, on a
    /// persistent failure, an explanatory `unavailableReason` — `nil`/`nil`
    /// on the ordinary "first sample, nothing to diff yet" case, which is
    /// not itself a failure.
    private func readANEEnergyDelta() -> (delta: UInt64?, reason: String?) {
        guard let functions = ioReportFunctionsIfAvailable() else {
            return (nil, ioReportUnavailableReason)
        }
        guard let subscription, let sampleChannels else {
            // `ioReportFunctionsIfAvailable()` succeeding but the
            // subscription itself failing is recorded in
            // `ioReportUnavailableReason` by `setUpIOReportIfNeeded()`.
            return (nil, ioReportUnavailableReason)
        }

        guard let sampleUnmanaged = functions.createSamples(subscription, sampleChannels) else {
            return (nil, "IOReportCreateSamples failed this tick")
        }
        let currentSample = sampleUnmanaged.takeRetainedValue()
        defer { previousSample = currentSample }

        guard let previousSample else {
            // First successful sample since this provider started — no
            // prior reading to diff against yet. Not a failure.
            return (nil, nil)
        }

        guard let deltaUnmanaged = functions.createSamplesDelta(previousSample, currentSample, nil) else {
            return (nil, "IOReportCreateSamplesDelta failed this tick")
        }
        let delta = deltaUnmanaged.takeRetainedValue()

        guard let aneValue = Self.aneChannelValue(in: delta, functions: functions) else {
            return (nil, "The IOReport \"Energy Model\" group's channel list has no \"ANE\" entry on this Mac")
        }
        guard aneValue >= 0 else {
            // A negative delta would mean the underlying accumulator
            // wrapped or reset between ticks — an honest "can't trust this
            // reading" rather than reporting a nonsensical negative energy
            // use, matching `GPUProvider.uint64Value`'s "don't wrap to a
            // huge unsigned value" convention.
            return (nil, nil)
        }
        return (UInt64(aneValue), nil)
    }

    /// Finds the channel named exactly `"ANE"` within a sample/delta
    /// dictionary's `"IOReportChannels"` array and reads its integer
    /// value. `nil` when the key structure is missing or no such channel
    /// exists (e.g. a future macOS/SoC generation renaming or dropping it
    /// — an honest "Unavailable" rather than an assumption this app can't
    /// verify beyond the one dev Mac it was built against).
    private static func aneChannelValue(in delta: CFDictionary, functions: IOReportFunctions) -> Int64? {
        guard let items = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return nil }
        for item in items {
            let cfItem = item as CFDictionary
            guard let nameUnmanaged = functions.channelGetChannelName(cfItem) else { continue }
            if nameUnmanaged.takeUnretainedValue() as String == "ANE" {
                return functions.simpleGetIntegerValue(cfItem, 0)
            }
        }
        return nil
    }

    /// Returns the cached, already-`dlsym`'d function table and live
    /// subscription, setting both up once on the first call. `nil` after a
    /// failed first attempt — see `ioReportUnavailableReason` for why —
    /// without retrying every tick.
    private func ioReportFunctionsIfAvailable() -> IOReportFunctions? {
        if let reportFunctions { return reportFunctions }
        guard !ioReportSetupAttempted else { return nil }
        ioReportSetupAttempted = true

        guard let functions = IOReportFunctions.load() else {
            ioReportUnavailableReason = "libIOReport.dylib could not be loaded, or is missing an expected symbol"
            return nil
        }

        guard let channelsUnmanaged = functions.copyChannelsInGroup("Energy Model" as CFString, nil) else {
            ioReportUnavailableReason = "IOReportCopyChannelsInGroup(\"Energy Model\") returned nil"
            return nil
        }
        let channelsRaw = channelsUnmanaged.takeRetainedValue()
        guard let channels = CFDictionaryCreateMutableCopy(nil, 0, channelsRaw) else {
            ioReportUnavailableReason = "Could not copy the IOReport \"Energy Model\" channel list"
            return nil
        }

        var subscribedChannelsPtr: Unmanaged<CFMutableDictionary>?
        guard let subscriptionUnmanaged = functions.createSubscription(nil, channels, &subscribedChannelsPtr, 0, nil) else {
            ioReportUnavailableReason = "IOReportCreateSubscription failed"
            return nil
        }

        reportFunctions = functions
        subscription = subscriptionUnmanaged.takeRetainedValue()
        sampleChannels = subscribedChannelsPtr?.takeRetainedValue() ?? channels
        return functions
    }

    /// The handful of `IOReport` C symbols this provider needs, resolved
    /// once via `dlopen`/`dlsym` since `libIOReport.dylib` ships no public
    /// header. Ownership of each function's CoreFoundation return value
    /// follows the Create/Copy-vs-Get naming convention documented on each
    /// property below — Swift can't infer this automatically for a raw
    /// `dlsym`'d pointer the way it does for an imported C header, so every
    /// call site must apply `takeRetainedValue()`/`takeUnretainedValue()`
    /// itself; verified empirically (no crashes or leaks observed across
    /// repeated sampling on this dev Mac while building this provider) that
    /// treating these as ordinary Create/Copy/Get-ruled CF functions is
    /// correct.
    private struct IOReportFunctions {
        typealias CopyChannelsInGroupFn = @convention(c) (CFString?, CFString?) -> Unmanaged<CFDictionary>?
        typealias CreateSubscriptionFn = @convention(c) (
            CFAllocator?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?
        ) -> Unmanaged<AnyObject>?
        typealias CreateSamplesFn = @convention(c) (AnyObject, CFMutableDictionary) -> Unmanaged<CFDictionary>?
        typealias CreateSamplesDeltaFn = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
        typealias SimpleGetIntegerValueFn = @convention(c) (CFDictionary, Int32) -> Int64
        typealias ChannelGetChannelNameFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?

        /// `IOReportCopyChannelsInGroup` — Copy semantics (+1 owned).
        let copyChannelsInGroup: CopyChannelsInGroupFn
        /// `IOReportCreateSubscription` — Create semantics (+1 owned); the
        /// `subscribedChannels` out-parameter is also +1 owned when
        /// non-`nil`.
        let createSubscription: CreateSubscriptionFn
        /// `IOReportCreateSamples` — Create semantics (+1 owned).
        let createSamples: CreateSamplesFn
        /// `IOReportCreateSamplesDelta` — Create semantics (+1 owned).
        let createSamplesDelta: CreateSamplesDeltaFn
        /// `IOReportSimpleGetIntegerValue` — returns a plain `Int64`, no
        /// CF ownership involved.
        let simpleGetIntegerValue: SimpleGetIntegerValueFn
        /// `IOReportChannelGetChannelName` — Get semantics (+0 borrowed;
        /// valid only as long as the parent sample/delta dictionary is).
        let channelGetChannelName: ChannelGetChannelNameFn

        /// `dlopen`s `libIOReport.dylib` and resolves every symbol above.
        /// `nil` if the library can't be opened or any single symbol is
        /// missing — a partial function table is treated the same as no
        /// table at all, since every code path here needs the full set.
        static func load() -> IOReportFunctions? {
            guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }

            func resolve<T>(_ name: String, as type: T.Type) -> T? {
                guard let pointer = dlsym(handle, name) else { return nil }
                return unsafeBitCast(pointer, to: T.self)
            }

            guard let copyChannelsInGroup = resolve("IOReportCopyChannelsInGroup", as: CopyChannelsInGroupFn.self),
                  let createSubscription = resolve("IOReportCreateSubscription", as: CreateSubscriptionFn.self),
                  let createSamples = resolve("IOReportCreateSamples", as: CreateSamplesFn.self),
                  let createSamplesDelta = resolve("IOReportCreateSamplesDelta", as: CreateSamplesDeltaFn.self),
                  let simpleGetIntegerValue = resolve("IOReportSimpleGetIntegerValue", as: SimpleGetIntegerValueFn.self),
                  let channelGetChannelName = resolve("IOReportChannelGetChannelName", as: ChannelGetChannelNameFn.self)
            else { return nil }

            return IOReportFunctions(
                copyChannelsInGroup: copyChannelsInGroup,
                createSubscription: createSubscription,
                createSamples: createSamples,
                createSamplesDelta: createSamplesDelta,
                simpleGetIntegerValue: simpleGetIntegerValue,
                channelGetChannelName: channelGetChannelName
            )
        }
    }
}
