import Foundation
import IOKit
import IOKit.ps

/// Where the system is currently drawing power from, `IOPSCopyPowerSourcesInfo`'s
/// `kIOPSPowerSourceStateKey` ("Power Source State") — PLAN.md §1.1's Energy
/// detail "Power source (AC)" tile.
enum EnergyPowerSource: String, Sendable, Equatable {
    case acPower
    case batteryPower
    /// Neither of the two documented state strings was present — an
    /// external UPS or an unrecognized future value, not asserted as
    /// either AC or battery.
    case unknown
}

/// One tick's battery reading — PLAN.md §1.1 Energy detail's "Battery %,
/// Cycle count, Battery condition" tiles, present only on Macs with a
/// battery (`nil` `EnergySnapshot.battery` on Mac mini/Studio/Pro/iMac —
/// see `EnergyProvider`).
///
/// Fields split by source on purpose: `percent`/`isCharging`/`isCharged`/
/// the two time estimates come from the public, documented
/// `IOPSCopyPowerSourcesInfo` API (the same one menu-bar battery UIs use);
/// `cycleCount`/`designCapacityMAh`/`fullChargeCapacityMAh`/`condition`
/// come from the private, undocumented `AppleSmartBattery` IORegistry
/// service — no public API exposes battery health. Both are read every
/// tick and merged here.
struct EnergyBatterySnapshot: Sendable, Equatable {
    /// Charge level, `0...100`, derived from `IOPSCopyPowerSourcesInfo`'s
    /// `"Current Capacity"` / `"Max Capacity"` pair — both already
    /// percentage-scale in this API (unlike the IORegistry capacity keys
    /// below), so no unit conversion is needed. `nil` only if the source
    /// dictionary is missing either key.
    let percent: Double?
    let isCharging: Bool?
    /// `kIOPSIsChargedKey` ("Is Charged") — `true` once charging has
    /// finished, distinct from `isCharging` being `false` while on AC but
    /// not yet topped up.
    let isCharged: Bool?
    /// Minutes until empty, `kIOPSTimeToEmptyKey`. `nil` both when the
    /// battery isn't discharging and when macOS reports the documented
    /// "still estimating" sentinel (`-1`) — an honest "Unavailable" rather
    /// than a fabricated countdown.
    let timeToEmptyMinutes: Int?
    /// Minutes until full charge, `kIOPSTimeToFullChargeKey`, same `-1`
    /// handling as `timeToEmptyMinutes`.
    let timeToFullChargeMinutes: Int?
    /// `AppleSmartBattery`'s `"CycleCount"` — PLAN.md §1.1 "Cycle count".
    let cycleCount: Int?
    /// `AppleSmartBattery`'s `"DesignCapacity"`, milliamp-hours as shipped
    /// from the factory. Still reported in real mAh on every macOS version
    /// this app targets (unlike `"MaxCapacity"` below).
    let designCapacityMAh: Int?
    /// `AppleSmartBattery`'s `"AppleRawMaxCapacity"` — the battery's
    /// present full-charge capacity in the same real-mAh units as
    /// `designCapacityMAh`, so `fullChargeCapacityMAh / designCapacityMAh`
    /// is a genuine health ratio. Deliberately **not** read from the
    /// plain `"MaxCapacity"` key: on current macOS that key has been
    /// renormalized to a `0...100`-ish percentage-like figure (confirmed
    /// by reading both side by side on this dev Mac — `"MaxCapacity"`
    /// read `100` while `"AppleRawMaxCapacity"` read the real `5432`
    /// mAh), and treating it as mAh would silently fabricate a capacity
    /// figure — exactly what PLAN.md's honest-degradation rule forbids.
    /// `nil` on older systems whose `AppleSmartBattery` doesn't publish
    /// the `AppleRaw*` keys, rather than guessing at `"MaxCapacity"`'s
    /// units there.
    let fullChargeCapacityMAh: Int?
    /// Best-effort condition label — PLAN.md §1.1 "Battery condition".
    /// Prefers `IOPSCopyPowerSourcesInfo`'s `"BatteryHealthCondition"`
    /// when it's a non-empty string (the exceptional case, e.g. "Service
    /// Recommended"; empty when nothing's wrong), falling back to the
    /// coarser `"BatteryHealth"` (e.g. "Good"). `nil` when neither key is
    /// present/non-empty.
    let condition: String?
}

/// One tick's energy reading — PLAN.md §4 M2's "system watts (SMC), power
/// source/mode, battery state", merged into `Snapshot.energy`.
struct EnergySnapshot: Sendable, Equatable {
    /// Total system power draw in watts, SMC key `"PSTR"`. `nil` when the
    /// AppleSMC connection couldn't be opened or this Mac's SMC firmware
    /// doesn't publish the key — see `EnergyProvider`'s doc comment for
    /// why this is inherently best-effort.
    let systemPowerWatts: Double?
    /// DC-in (power adapter) draw in watts, SMC key `"PDTR"`. Typically
    /// higher than `systemPowerWatts` while the battery is also charging
    /// (the difference covers charging + conversion losses); `nil` on
    /// battery power on most Macs, and whenever the key is unreadable.
    let adapterPowerWatts: Double?
    /// Battery charge/discharge power in watts, SMC key `"PPBR"`. Positive
    /// while charging on most firmwares; near zero once charged; `nil`
    /// whenever the key is unreadable.
    let batteryPowerWatts: Double?
    /// AC vs. battery, from the public Power Sources API.
    let powerSource: EnergyPowerSource
    /// `ProcessInfo.processInfo.isLowPowerModeEnabled` — PLAN.md §1.1's
    /// Energy detail "Power mode (Low Power Mode)" tile. Always readable
    /// (a `ProcessInfo` property, not a syscall that can fail), so never
    /// `nil`.
    let isLowPowerModeEnabled: Bool
    /// `nil` on Macs with no battery (desktops); see
    /// `EnergyBatterySnapshot`'s doc comment for how a present battery's
    /// fields are sourced.
    let battery: EnergyBatterySnapshot?
}

/// Failure modes for `EnergyProvider.sample()` — see `Provider`'s doc
/// comment for when a provider throws versus returning `nil` fields. Note
/// how narrow this is: an AppleSMC connection failure does **not** appear
/// here — it only blanks the three wattage fields (see this type's doc
/// comment on `EnergyProvider`), since power-source/battery state is still
/// fully readable without it.
enum EnergyProviderError: Error, LocalizedError {
    /// `IOPSCopyPowerSourcesInfo` itself returned `nil` — shouldn't happen
    /// on real macOS, but the whole domain is unreadable without it.
    case powerSourcesInfoUnavailable

    var errorDescription: String? {
        switch self {
        case .powerSourcesInfoUnavailable:
            return "IOPSCopyPowerSourcesInfo returned nil"
        }
    }
}

/// Samples system power draw, power source/mode, and battery state —
/// PLAN.md §3 `Providers/EnergyProvider.swift "SMC power keys,
/// IOPSCopyPowerSourcesInfo battery"` and §4 M2's sixth task.
///
/// Three data sources feed this provider, each read every tick:
/// 1. **AppleSMC**, for instantaneous wattage. Apple publishes no
///    documented API for this (same undocumented-territory situation as
///    `GPUProvider`'s `PerformanceStatistics`); every third-party power
///    monitor (iStat Menus, `stats`, TG Pro, ...) reads it the same
///    reverse-engineered way this provider does — opening a user-space
///    connection to the `AppleSMC` IOKit service and issuing a small
///    struct-based RPC (`IOConnectCallStructMethod` against a single
///    "handle event" selector, with an inner `data8` op code selecting
///    get-key-info vs. read-key) to pull one 4-character-keyed value at a
///    time. The wire struct's key/type fields are 4-character codes
///    packed as `(c0<<24 | c1<<16 | c2<<8 | c3)` and then stored through
///    that *value's* native little-endian byte order — i.e. the bytes
///    that actually cross the RPC boundary are the ASCII characters
///    **reversed** (verified empirically against this dev Mac's live SMC:
///    the forward byte order for `"PSTR"` reads back "key not found",
///    the reversed order reads a plausible wattage). `encodeSMCKey`/
///    `decodeSMCFourCC` below centralize that reversal so every call site
///    just deals in normal 4-character strings.
///    Candidate wattage keys (`"PSTR"` system total, `"PDTR"` DC-in,
///    `"PPBR"` battery) are widely cited across those third-party tools;
///    a key a given Mac's firmware doesn't publish reads back a clean
///    "key not found" status (never a fabricated number) and simply
///    surfaces as `nil` — PLAN.md's honest degradation. If the SMC
///    connection can't even be opened, all three wattage fields are `nil`
///    for the whole tick, but `sample()` still succeeds: power source and
///    battery state below don't depend on SMC at all, so a single bad
///    source must not take the whole domain down (`Provider`'s
///    doc comment).
/// 2. **`IOPSCopyPowerSourcesInfo`/`IOPSCopyPowerSourcesList`/
///    `IOPSGetPowerSourceDescription`** (`IOKit.ps`), Apple's public,
///    documented Power Sources API — the same one menu-bar battery
///    indicators use. Supplies AC-vs-battery state and the
///    percent/charging/time-remaining half of `EnergyBatterySnapshot`.
/// 3. **`ProcessInfo.processInfo.isLowPowerModeEnabled`**, for Low Power
///    Mode.
/// 4. The `AppleSmartBattery` IORegistry service (private, undocumented,
///    like the SMC dictionary above) for cycle count and health-capacity
///    figures the public Power Sources API doesn't expose — see
///    `EnergyBatterySnapshot`'s doc comment for the `"MaxCapacity"` vs.
///    `"AppleRawMaxCapacity"` units pitfall this provider deliberately
///    avoids.
///
/// A `final class`, matching `CPUProvider`/`DiskProvider`'s convention:
/// the AppleSMC user-client connection is opened once and kept open for
/// the app's lifetime (`smcConnection`) rather than reopened every tick,
/// and a failed first attempt is remembered (`smcOpenAttempted`) so a Mac
/// without an `AppleSMC` service (e.g. inside certain virtualized
/// environments) doesn't retry a doomed `IOServiceOpen` every tick.
final class EnergyProvider: Provider {
    static let providerID = "energy"

    private var smcConnection: io_connect_t?
    private var smcOpenAttempted = false

    deinit {
        if let smcConnection {
            IOServiceClose(smcConnection)
        }
    }

    func sample() throws -> EnergySnapshot {
        guard let infoUnmanaged = IOPSCopyPowerSourcesInfo() else {
            throw EnergyProviderError.powerSourcesInfoUnavailable
        }
        let info = infoUnmanaged.takeRetainedValue()

        var powerSource: EnergyPowerSource = .unknown
        var battery: EnergyBatterySnapshot?

        if let listUnmanaged = IOPSCopyPowerSourcesList(info) {
            let sources = listUnmanaged.takeRetainedValue() as [CFTypeRef]
            for source in sources {
                guard let descUnmanaged = IOPSGetPowerSourceDescription(info, source),
                      let description = descUnmanaged.takeUnretainedValue() as? [String: Any] else {
                    continue
                }

                if let stateString = description["Power Source State"] as? String {
                    powerSource = Self.powerSource(fromStateString: stateString)
                }
                if (description["Type"] as? String) == "InternalBattery" {
                    battery = Self.readBattery(fromIOPSDescription: description)
                }
            }
        }

        let connection = openSMCConnectionIfNeeded()

        return EnergySnapshot(
            systemPowerWatts: connection.flatMap { Self.readSMCWatts(connection: $0, key: "PSTR") },
            adapterPowerWatts: connection.flatMap { Self.readSMCWatts(connection: $0, key: "PDTR") },
            batteryPowerWatts: connection.flatMap { Self.readSMCWatts(connection: $0, key: "PPBR") },
            powerSource: powerSource,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            battery: battery
        )
    }

    // MARK: - Power Sources (public API)

    private static func powerSource(fromStateString stateString: String) -> EnergyPowerSource {
        switch stateString {
        case "AC Power": return .acPower
        case "Battery Power": return .batteryPower
        default: return .unknown
        }
    }

    /// Builds an `EnergyBatterySnapshot` from one `IOPSGetPowerSourceDescription`
    /// dictionary (the percent/charging/time-remaining/condition half) and
    /// augments it with the `AppleSmartBattery` IORegistry read (the
    /// cycle-count/capacity half) — see this type's doc comment on
    /// `EnergyProvider` for why the two sources are split this way.
    private static func readBattery(fromIOPSDescription description: [String: Any]) -> EnergyBatterySnapshot {
        var percent: Double?
        if let current = description["Current Capacity"] as? Int,
           let max = description["Max Capacity"] as? Int,
           max > 0 {
            percent = (Double(current) / Double(max)) * 100
        }

        let registryProperties = readSmartBatteryRegistryProperties()
        let condition = nonEmptyString(description["BatteryHealthCondition"])
            ?? nonEmptyString(description["BatteryHealth"])

        return EnergyBatterySnapshot(
            percent: percent,
            isCharging: description["Is Charging"] as? Bool,
            isCharged: description["Is Charged"] as? Bool,
            timeToEmptyMinutes: nonNegativeMinutes(description["Time to Empty"] as? Int),
            timeToFullChargeMinutes: nonNegativeMinutes(description["Time to Full Charge"] as? Int),
            cycleCount: registryProperties?["CycleCount"] as? Int,
            designCapacityMAh: registryProperties?["DesignCapacity"] as? Int,
            fullChargeCapacityMAh: registryProperties?["AppleRawMaxCapacity"] as? Int,
            condition: condition
        )
    }

    /// `-1` is `IOPSKeys.h`'s documented "still estimating" sentinel for
    /// both time-remaining keys; treated as `nil` (honest "Unavailable")
    /// rather than a bogus negative minute count.
    private static func nonNegativeMinutes(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    private static func nonEmptyString(_ any: Any?) -> String? {
        guard let string = any as? String, !string.isEmpty else { return nil }
        return string
    }

    /// One-shot IORegistry read of the private `AppleSmartBattery` service
    /// — cycle count and raw (real-mAh) capacity figures the public Power
    /// Sources API doesn't expose. `nil` on any Mac with no battery
    /// (desktops) or if the lookup otherwise fails; never throws, matching
    /// `DiskProvider.readVolumeCapacities`'s "secondary reading, omit
    /// rather than fail the tick" convention.
    private static func readSmartBatteryRegistryProperties() -> [String: Any]? {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var propertiesUnmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propertiesUnmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = propertiesUnmanaged?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return properties
    }

    // MARK: - AppleSMC (private, reverse-engineered — see doc comment above)

    /// Opens (and caches) the AppleSMC user-client connection. Returns
    /// `nil` without retrying once a first attempt has failed — see this
    /// type's doc comment on why that's not itself a whole-domain failure.
    private func openSMCConnectionIfNeeded() -> io_connect_t? {
        if let smcConnection { return smcConnection }
        guard !smcOpenAttempted else { return nil }
        smcOpenAttempted = true

        guard let matching = IOServiceMatching("AppleSMC") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        smcConnection = connection
        return connection
    }

    /// AppleSMC's `SMCKeyData_t` request/response struct is 80 bytes: a
    /// 4-byte key, a 6-byte version block, a 16-byte power-limit block, a
    /// 12-byte key-info block (`dataSize`/`dataType`/`dataAttributes`,
    /// padded), `result`/`status`/`data8`/`data32`, and a trailing 32-byte
    /// data payload — offsets below are that layout's byte positions,
    /// used directly on raw `[UInt8]` buffers (rather than a mirrored
    /// Swift struct) so this provider's correctness doesn't depend on
    /// Swift's struct-layout algorithm happening to match C's, only on
    /// these offsets, which are verified against this dev Mac's live SMC
    /// (see this type's doc comment).
    private enum SMCWire {
        static let structSize = 80
        static let keyOffset = 0
        static let dataSizeOffset = 28
        static let dataTypeOffset = 32
        static let resultOffset = 40
        static let selectorOffset = 42
        static let dataOffset = 48

        static let handleYPCEventSelector: UInt32 = 2
        static let readKeyOp: UInt8 = 5
        static let getKeyInfoOp: UInt8 = 9
        static let success: UInt8 = 0
    }

    /// Packs a 4-character SMC key string into wire byte order — see this
    /// type's doc comment for why that's the *reverse* of the characters'
    /// natural order.
    private static func encodeSMCKey(_ key: String) -> [UInt8]? {
        let characters = Array(key.utf8)
        guard characters.count == 4 else { return nil }
        return Array(characters.reversed())
    }

    /// Inverse of `encodeSMCKey`, used to decode the `dataType` 4-character
    /// code (e.g. `"flt "`) the SMC hands back in a key-info response.
    private static func decodeSMCFourCC(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.reversed(), as: UTF8.self)
    }

    private static func makeSMCInput(keyBytes: [UInt8], op: UInt8, dataSize: UInt32 = 0) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: SMCWire.structSize)
        buffer.replaceSubrange(SMCWire.keyOffset..<(SMCWire.keyOffset + 4), with: keyBytes)
        if dataSize > 0 {
            withUnsafeBytes(of: dataSize.littleEndian) { raw in
                buffer.replaceSubrange(SMCWire.dataSizeOffset..<(SMCWire.dataSizeOffset + 4), with: raw)
            }
        }
        buffer[SMCWire.selectorOffset] = op
        return buffer
    }

    /// Issues one `IOConnectCallStructMethod` round trip against the
    /// AppleSMC "handle event" selector. Returns `nil` on any failure —
    /// the kernel call itself failing, or a non-success `result` byte
    /// (most commonly `kSMCKeyNotFound` for a key this Mac's firmware
    /// simply doesn't publish, which is the expected, non-error outcome
    /// for most of the candidate keys this provider tries).
    private static func callSMC(_ connection: io_connect_t, _ input: [UInt8]) -> [UInt8]? {
        var inputBuffer = input
        var outputBuffer = [UInt8](repeating: 0, count: SMCWire.structSize)
        var outputSize = SMCWire.structSize

        let kernResult = inputBuffer.withUnsafeMutableBytes { inputPointer -> kern_return_t in
            outputBuffer.withUnsafeMutableBytes { outputPointer -> kern_return_t in
                IOConnectCallStructMethod(
                    connection,
                    SMCWire.handleYPCEventSelector,
                    inputPointer.baseAddress,
                    SMCWire.structSize,
                    outputPointer.baseAddress,
                    &outputSize
                )
            }
        }

        guard kernResult == KERN_SUCCESS, outputBuffer[SMCWire.resultOffset] == SMCWire.success else {
            return nil
        }
        return outputBuffer
    }

    /// Reads one SMC key's value as watts: a `kSMCGetKeyInfo` call to
    /// learn its size/type, then a `kSMCReadKey` call for the bytes,
    /// decoded per `decodeSMCValue`. `nil` at any step — connection
    /// trouble, key not found, unrecognized/oversized data type — is
    /// this key's honest "Unavailable" for this tick, never a guess.
    private static func readSMCWatts(connection: io_connect_t, key: String) -> Double? {
        guard let keyBytes = encodeSMCKey(key) else { return nil }

        guard let infoOutput = callSMC(connection, makeSMCInput(keyBytes: keyBytes, op: SMCWire.getKeyInfoOp)) else {
            return nil
        }
        let dataSize = UInt32(littleEndianBytes: infoOutput[SMCWire.dataSizeOffset..<(SMCWire.dataSizeOffset + 4)])
        let dataType = decodeSMCFourCC(infoOutput[SMCWire.dataTypeOffset..<(SMCWire.dataTypeOffset + 4)])
        guard dataSize > 0, dataSize <= 32 else { return nil }

        guard let readOutput = callSMC(connection, makeSMCInput(keyBytes: keyBytes, op: SMCWire.readKeyOp, dataSize: dataSize)) else {
            return nil
        }
        let valueBytes = Array(readOutput[SMCWire.dataOffset..<(SMCWire.dataOffset + Int(dataSize))])
        return decodeSMCValue(type: dataType, bytes: valueBytes)
    }

    /// Decodes an SMC value into a `Double`, dispatching on its 4-character
    /// type code. `"flt "` (a plain little-endian IEEE-754 float — this
    /// dev Mac's `PSTR`/`PDTR`/`PPBR` all report this type) covers every
    /// wattage key this provider currently reads; the fixed-point/integer
    /// branches are kept as defensive fallbacks for other Mac generations'
    /// firmware without this app being able to verify them live, following
    /// the widely-documented SMC type conventions (`"sp78"` a signed 8.8
    /// fixed-point pair, `"ui#"/"si#"` big-endian integers of the given
    /// byte width). An unrecognized type returns `nil` rather than a wrong
    /// guess.
    private static func decodeSMCValue(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "flt " where bytes.count == 4:
            let bits = UInt32(littleEndianBytes: bytes[...])
            return Double(Float(bitPattern: bits))
        case "sp78" where bytes.count == 2:
            let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
            return Double(raw) / 256.0
        default:
            guard !bytes.isEmpty, bytes.count <= 8, type.hasPrefix("ui") || type.hasPrefix("si") else {
                return nil
            }
            var magnitude: UInt64 = 0
            for byte in bytes { magnitude = (magnitude << 8) | UInt64(byte) }
            guard type.hasPrefix("si") else { return Double(magnitude) }
            let bitWidth = bytes.count * 8
            let signBit: UInt64 = bitWidth < 64 ? (1 << (bitWidth - 1)) : (1 << 63)
            guard magnitude & signBit != 0, bitWidth < 64 else { return Double(magnitude) }
            return Double(Int64(magnitude) - Int64(1 << bitWidth))
        }
    }
}

// MARK: - Little-endian byte helpers

private extension UInt32 {
    /// Reassembles a little-endian `UInt32` from exactly 4 bytes — used
    /// both to write the SMC wire struct's `dataSize` field and to read
    /// back a `"flt "` value's raw bits ahead of `Float(bitPattern:)`.
    init(littleEndianBytes bytes: ArraySlice<UInt8>) {
        precondition(bytes.count == 4)
        var value: UInt32 = 0
        for (index, byte) in bytes.enumerated() {
            value |= UInt32(byte) << (8 * index)
        }
        self = value
    }
}
