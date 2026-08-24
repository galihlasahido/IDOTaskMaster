import Foundation
import IOKit

/// System-wide thermal throttling pressure — PLAN.md §1.1's Thermals detail
/// "thermal pressure state" tile. A thin, `Sendable`, `Equatable` mirror of
/// `ProcessInfo.ThermalState`, which is itself the single macOS-documented,
/// public signal for "how hard is the system throttling right now" (the
/// same value `NSProcessInfoThermalStateDidChangeNotification` reports).
/// Unlike every other reading in this provider, this one can never fail —
/// `ProcessInfo.processInfo.thermalState` is a plain property read, not a
/// syscall — so `ThermalSnapshot.thermalPressure` is never `nil`.
enum ThermalPressureLevel: String, Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical
    /// A future `ProcessInfo.ThermalState` case this app doesn't yet know
    /// about — `ThermalState` isn't declared as a closed/frozen enum in the
    /// SDK, so a switch over it must handle this to stay exhaustive.
    /// Deliberately not folded into `.nominal`: an unrecognized state is
    /// its own honest "Unavailable"-style answer, not a guess that
    /// everything is fine.
    case unknown

    init(_ processInfoState: ProcessInfo.ThermalState) {
        switch processInfoState {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .unknown
        }
    }
}

/// One AppleSMC temperature-type key's live reading — the raw material for
/// PLAN.md §1.1's Thermals detail "per-die temperature sensor mini-graphs
/// (Die 1..N)".
///
/// `key` is the sensor's undocumented 4-character SMC code (e.g. `"TPD3"`)
/// verbatim, **not** a human-readable component name — AppleSMC publishes
/// no name for any key, only reverse-engineered folklore (see
/// `ThermalProvider`'s doc comment for why this provider doesn't lean on
/// that folklore for individual-sensor attribution). A future Performance
/// page enumerates this array as "Die 1", "Die 2", ... itself; this type
/// makes no claim about which physical die/component each reading belongs
/// to, only that the key exists on this Mac's SMC and read back a
/// plausible temperature this tick.
struct ThermalSensorReading: Sendable, Equatable, Identifiable {
    var id: String { key }
    let key: String
    let celsius: Double
}

/// One tick's thermal reading — PLAN.md §4 M2's "hotspot + per-die sensors
/// (SMC), thermal pressure", merged into `Snapshot.thermal`.
struct ThermalSnapshot: Sendable, Equatable {
    /// The highest reading among this tick's `dieSensors`, if any were
    /// readable — PLAN.md §1.1's Thermals detail "hotspot °C". See
    /// `ThermalProvider`'s doc comment for why "the hottest sensor
    /// currently tracked" is this provider's honest definition of
    /// "hotspot" rather than one hardcoded "the CPU key" that this
    /// provider cannot verify is correct on every Mac model. `nil` when
    /// `dieSensors` is empty (no AppleSMC connection, or none of the
    /// tracked keys read back this tick).
    let hotspotCelsius: Double?
    /// Every currently-tracked SMC temperature sensor's live reading this
    /// tick that passed `ThermalProvider.isPlausibleTemperature` (see that
    /// method's doc comment for why an exact `0.0` reading is treated as
    /// "not currently populated" and dropped rather than shown), sorted by
    /// `key` for a stable display order — see `ThermalSensorReading`'s doc
    /// comment. Empty when the AppleSMC connection couldn't be opened or
    /// no temperature-shaped keys were found (never a fabricated
    /// placeholder reading).
    let dieSensors: [ThermalSensorReading]
    /// Always present — see `ThermalPressureLevel`'s doc comment.
    let thermalPressure: ThermalPressureLevel
}

/// Samples SMC hotspot/per-die temperatures and OS thermal pressure —
/// PLAN.md §3 `Providers/ThermalProvider.swift "SMC temp keys,
/// ProcessInfo.thermalState"` and §4 M2's seventh task.
///
/// Two data sources, read every tick:
/// 1. **`ProcessInfo.processInfo.thermalState`** — public, documented,
///    can't fail. Backs `thermalPressure`.
/// 2. **AppleSMC**, for individual sensor temperatures, via the same
///    reverse-engineered user-client RPC `EnergyProvider` uses for wattage
///    keys (see that type's doc comment for the wire-format background:
///    `IOConnectCallStructMethod` against AppleSMC's "handle event"
///    selector, 4-character keys packed in *reversed* byte order). This
///    provider's SMC section is a self-contained duplicate of that
///    mechanism (matching this codebase's one-file-per-provider
///    convention) rather than a shared dependency, extended with two
///    operations `EnergyProvider` doesn't need: `kSMCGetKeyCount`
///    (`"#KEY"`'s own value — an SMC key like any other) and
///    `kSMCGetKeyFromIndex`, which together let this provider *discover*
///    which temperature keys exist rather than guessing at a fixed list.
///
/// That discovery step exists because, unlike `EnergyProvider`'s three
/// wattage keys (`"PSTR"`/`"PDTR"`/`"PPBR"`, cited consistently across
/// years of third-party tools regardless of Mac model), **AppleSMC's
/// temperature key names are not stable across Apple silicon generations**
/// — verified directly on this dev Mac (an M4 Max) by dumping every key:
/// none of the M1-era CPU sensor keys commonly cited in older
/// third-party-tool folklore (e.g. `"Tp09"`, `"Tp0D"`) read back this
/// machine's real per-core temperatures — they exist, but all read back
/// a suspiciously identical flat 40.0°C, i.e. some *other*, non-CPU
/// sensor group that happens to share that prefix on this generation.
/// Hardcoding that folklore list would therefore have silently mislabeled
/// a wrong sensor as "CPU temperature" — confidently wrong, which is worse
/// than this provider's "Unavailable" (PLAN.md's honest-degradation rule
/// is about not *guessing*, and a plausible-looking wrong key is exactly
/// that kind of guess). So instead of a fixed key list, `sample()`
/// lazily discovers, once, every SMC key whose name starts with `"T"` and
/// whose value type is a float/fixed-point temperature encoding, then
/// tracks only the `maxTrackedSensors` hottest of those (found on this
/// dev Mac's real SMC: 348 such keys spanning battery/storage/Wi-Fi/
/// ambient/compute sensors alike — component attribution AppleSMC simply
/// doesn't publish; keeping the hottest few is both a reasonable proxy for
/// "the compute dies that matter to a thermal page" — idle peripheral
/// sensors read near ambient, well below any compute die under load — and
/// what keeps steady-state per-tick cost small: the full discovery scan
/// takes on the order of a second on this dev Mac (a one-time cost paid
/// lazily on the first `sample()` call, not on app launch itself), while
/// re-reading a bounded ~24 cached keys every tick after that is cheap).
/// `hotspotCelsius` is then simply the max of whichever tracked keys read
/// back a value this tick — see `ThermalSnapshot.hotspotCelsius`'s doc
/// comment for why that, not one hardcoded "the" key, is this provider's
/// honest notion of "hotspot".
///
/// A `final class`, matching `EnergyProvider`'s convention for the same
/// reason: the AppleSMC connection is opened once and kept for the app's
/// lifetime, and both the "connection failed" and "key discovery failed"
/// outcomes are remembered so neither is retried every tick.
final class ThermalProvider: Provider {
    static let providerID = "thermal"

    /// Upper bound on how many discovered temperature keys are re-read
    /// every tick — see this type's doc comment for the cost/coverage
    /// trade-off this caps.
    private static let maxTrackedSensors = 24

    private var smcConnection: io_connect_t?
    private var smcOpenAttempted = false

    /// The discovered, ranked set of temperature keys to re-read every
    /// tick, built once by `trackedSensorKeys(connection:)`. `nil` until
    /// the first discovery attempt; an empty array is a valid (if
    /// unfortunate) cached result, distinct from "not attempted yet".
    private var cachedSensorKeys: [(key: String, dataSize: UInt32, dataType: String)]?
    private var sensorDiscoveryAttempted = false

    deinit {
        if let smcConnection {
            IOServiceClose(smcConnection)
        }
    }

    /// Never actually throws: `ProcessInfo.thermalState` can't fail, and,
    /// matching `EnergyProvider`'s "AppleSMC connection failure doesn't
    /// take the whole domain down" rule, every SMC-sourced field simply
    /// reads back empty/`nil` when the AppleSMC service can't be opened or
    /// no temperature keys are found — never a thrown error. `throws`
    /// stays in the signature only to satisfy `Provider`'s requirement.
    func sample() throws -> ThermalSnapshot {
        let pressure = ThermalPressureLevel(ProcessInfo.processInfo.thermalState)

        guard let connection = openSMCConnectionIfNeeded() else {
            return ThermalSnapshot(hotspotCelsius: nil, dieSensors: [], thermalPressure: pressure)
        }

        let trackedKeys = trackedSensorKeys(connection: connection)
        guard !trackedKeys.isEmpty else {
            return ThermalSnapshot(hotspotCelsius: nil, dieSensors: [], thermalPressure: pressure)
        }

        var readings: [ThermalSensorReading] = []
        readings.reserveCapacity(trackedKeys.count)
        for entry in trackedKeys {
            if let celsius = Self.readSMCTemperature(
                connection: connection,
                key: entry.key,
                dataSize: entry.dataSize,
                dataType: entry.dataType
            ), Self.isPlausibleTemperature(celsius) {
                readings.append(ThermalSensorReading(key: entry.key, celsius: celsius))
            }
        }
        readings.sort { $0.key < $1.key }

        return ThermalSnapshot(
            hotspotCelsius: readings.map(\.celsius).max(),
            dieSensors: readings,
            thermalPressure: pressure
        )
    }

    // MARK: - AppleSMC connection (self-contained — see this type's doc comment)

    /// Opens (and caches) the AppleSMC user-client connection, matching
    /// `EnergyProvider.openSMCConnectionIfNeeded()`: `nil` without
    /// retrying once a first attempt has failed, rather than reopening a
    /// doomed connection every tick.
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

    // MARK: - Temperature key discovery (once — see this type's doc comment)

    /// Returns the cached, ranked temperature-key list, discovering it on
    /// the first call and remembering a failed/empty discovery so it isn't
    /// retried every tick (same "don't retry a doomed operation" rule as
    /// `openSMCConnectionIfNeeded()`).
    private func trackedSensorKeys(connection: io_connect_t) -> [(key: String, dataSize: UInt32, dataType: String)] {
        if let cachedSensorKeys { return cachedSensorKeys }
        guard !sensorDiscoveryAttempted else { return [] }
        sensorDiscoveryAttempted = true

        let discovered = Self.discoverTemperatureKeys(connection: connection, maxTracked: Self.maxTrackedSensors)
        cachedSensorKeys = discovered
        return discovered
    }

    /// Walks every SMC key by index (`kSMCGetKeyCount` via `"#KEY"`, then
    /// `kSMCGetKeyFromIndex` per index), keeps the ones whose name starts
    /// with `"T"` and whose value type is a temperature-shaped encoding
    /// (`"flt "` or `"sp78"` — the only two types this dev Mac's real
    /// temperature keys reported when every key was dumped, see this
    /// type's doc comment), reads each one's starting value for ranking,
    /// discards implausible readings (`isPlausibleTemperature` — guards
    /// against a key this decoding happens to misread, or one currently
    /// reporting its "not populated" sentinel, rather than a real
    /// reading), and returns the hottest `maxTracked` of the rest as
    /// `(key, dataSize, dataType)` triples ready for cheap per-tick
    /// re-reads (no further `kSMCGetKeyInfo` calls needed).
    private static func discoverTemperatureKeys(
        connection: io_connect_t,
        maxTracked: Int
    ) -> [(key: String, dataSize: UInt32, dataType: String)] {
        guard let count = readKeyCount(connection: connection) else { return [] }

        var candidates: [(key: String, dataSize: UInt32, dataType: String, celsius: Double)] = []
        for index in 0..<count {
            guard let name = readKeyName(connection: connection, atIndex: index),
                  name.hasPrefix("T"),
                  let keyBytes = encodeSMCKey(name) else { continue }

            guard let infoOutput = callSMC(connection, makeSMCInput(keyBytes: keyBytes, op: SMCWire.getKeyInfoOp)) else {
                continue
            }
            let dataSize = UInt32(littleEndianBytes: infoOutput[SMCWire.dataSizeOffset..<(SMCWire.dataSizeOffset + 4)])
            let dataType = decodeSMCFourCC(infoOutput[SMCWire.dataTypeOffset..<(SMCWire.dataTypeOffset + 4)])
            guard dataType == "flt " || dataType == "sp78" else { continue }

            guard let celsius = readSMCTemperature(
                connection: connection,
                keyBytes: keyBytes,
                dataSize: dataSize,
                dataType: dataType
            ), isPlausibleTemperature(celsius) else { continue }

            candidates.append((name, dataSize, dataType, celsius))
        }

        return candidates
            .sorted { $0.celsius > $1.celsius }
            .prefix(maxTracked)
            .map { (key: $0.key, dataSize: $0.dataSize, dataType: $0.dataType) }
    }

    /// Sanity bound applied to every raw SMC-decoded value before it's
    /// treated as a real reading, both at discovery time (ranking
    /// candidates) and every tick thereafter (re-reading tracked keys).
    /// Two failure modes this guards against, both observed empirically on
    /// this dev Mac's real SMC while building this provider: a decode
    /// landing on garbage (`< -10`/`> 150`, well outside anything a Mac
    /// component reaches), and — the common one — a key that reads back
    /// exactly (or near) `0.0`, which every populated temperature sensor
    /// checked on this dev Mac never does (ambient-floor readings are
    /// comfortably above freezing); `0.0` reads instead like a "sensor not
    /// currently populated/powered" sentinel some of the tracked keys
    /// intermittently report, not a real Celsius value. Excluding it here
    /// keeps a momentarily-unpowered sensor from showing as a bogus
    /// "0.0°C" reading — or, worse, from ever being picked as
    /// `hotspotCelsius` by being the sole survivor of a tick where every
    /// other tracked key happened to fail to read.
    private static func isPlausibleTemperature(_ celsius: Double) -> Bool {
        celsius > 1 && celsius < 150
    }

    /// Reads `"#KEY"`, AppleSMC's own count of published keys, as a plain
    /// big-endian unsigned integer of whatever size it reports (verified
    /// empirically against this dev Mac's live SMC: decoding it big-endian
    /// reads back a plausible key count in the low thousands; the
    /// little-endian interpretation does not). `nil` on any failure along
    /// the way — the whole discovery pass is skipped in that case.
    private static func readKeyCount(connection: io_connect_t) -> UInt32? {
        guard let keyBytes = encodeSMCKey("#KEY") else { return nil }
        guard let infoOutput = callSMC(connection, makeSMCInput(keyBytes: keyBytes, op: SMCWire.getKeyInfoOp)) else {
            return nil
        }
        let dataSize = UInt32(littleEndianBytes: infoOutput[SMCWire.dataSizeOffset..<(SMCWire.dataSizeOffset + 4)])
        guard dataSize > 0, dataSize <= 4 else { return nil }

        guard let readOutput = callSMC(connection, makeSMCInput(keyBytes: keyBytes, op: SMCWire.readKeyOp, dataSize: dataSize)) else {
            return nil
        }
        var count: UInt32 = 0
        for byte in readOutput[SMCWire.dataOffset..<(SMCWire.dataOffset + Int(dataSize))] {
            count = (count << 8) | UInt32(byte)
        }
        return count
    }

    /// `kSMCGetKeyFromIndex`: resolves the `index`-th of AppleSMC's
    /// `"#KEY"` published keys to its 4-character name. The index goes in
    /// the wire struct's `data32` field (`SMCWire.indexOffset`), *not* the
    /// `key` field — verified empirically against this dev Mac's live SMC
    /// (placing it in the `key` field instead reads back nothing; this
    /// offset reads back real key names). `nil` on failure or an empty/
    /// null-padded name (both treated as "no key at this index").
    private static func readKeyName(connection: io_connect_t, atIndex index: UInt32) -> String? {
        var buffer = [UInt8](repeating: 0, count: SMCWire.structSize)
        withUnsafeBytes(of: index.littleEndian) { raw in
            buffer.replaceSubrange(SMCWire.indexOffset..<(SMCWire.indexOffset + 4), with: raw)
        }
        buffer[SMCWire.selectorOffset] = SMCWire.getKeyFromIndexOp

        guard let output = callSMC(connection, buffer) else { return nil }
        let name = decodeSMCFourCC(output[SMCWire.keyOffset..<(SMCWire.keyOffset + 4)])
        guard !name.isEmpty, name != "\0\0\0\0" else { return nil }
        return name
    }

    /// Reads one already-known temperature key's current value — the
    /// per-tick path, given a cached `dataSize`/`dataType` so no
    /// `kSMCGetKeyInfo` round trip is needed.
    private static func readSMCTemperature(connection: io_connect_t, key: String, dataSize: UInt32, dataType: String) -> Double? {
        guard let keyBytes = encodeSMCKey(key) else { return nil }
        return readSMCTemperature(connection: connection, keyBytes: keyBytes, dataSize: dataSize, dataType: dataType)
    }

    /// `keyBytes`-taking core of `readSMCTemperature(connection:key:dataSize:dataType:)`,
    /// also used directly during discovery (where the caller already has
    /// `keyBytes` on hand from its own `kSMCGetKeyInfo` call, so there's no
    /// reason to re-encode the key string). Decodes only the two value
    /// types `discoverTemperatureKeys` ever keeps (`"flt "`/`"sp78"` —
    /// see that method's doc comment); any other type reads back `nil`.
    private static func readSMCTemperature(connection: io_connect_t, keyBytes: [UInt8], dataSize: UInt32, dataType: String) -> Double? {
        guard let readOutput = callSMC(connection, makeSMCInput(keyBytes: keyBytes, op: SMCWire.readKeyOp, dataSize: dataSize)) else {
            return nil
        }
        let valueBytes = Array(readOutput[SMCWire.dataOffset..<(SMCWire.dataOffset + Int(dataSize))])
        switch dataType {
        case "flt " where valueBytes.count == 4:
            let bits = UInt32(littleEndianBytes: valueBytes[...])
            return Double(Float(bitPattern: bits))
        case "sp78" where valueBytes.count == 2:
            let raw = Int16(bitPattern: (UInt16(valueBytes[0]) << 8) | UInt16(valueBytes[1]))
            return Double(raw) / 256.0
        default:
            return nil
        }
    }

    // MARK: - AppleSMC wire format (self-contained duplicate of `EnergyProvider`'s — see this type's doc comment)

    /// Same 80-byte `SMCKeyData_t` layout `EnergyProvider.SMCWire`
    /// documents, plus the two offsets/opcodes this provider's key
    /// discovery needs that `EnergyProvider` doesn't: `indexOffset` (the
    /// `data32` field `kSMCGetKeyFromIndex` reads its index from) and
    /// `getKeyFromIndexOp`.
    private enum SMCWire {
        static let structSize = 80
        static let keyOffset = 0
        static let dataSizeOffset = 28
        static let dataTypeOffset = 32
        static let resultOffset = 40
        static let selectorOffset = 42
        static let indexOffset = 44
        static let dataOffset = 48

        static let handleYPCEventSelector: UInt32 = 2
        static let readKeyOp: UInt8 = 5
        static let getKeyFromIndexOp: UInt8 = 8
        static let getKeyInfoOp: UInt8 = 9
        static let success: UInt8 = 0
    }

    /// Packs a 4-character SMC key string into wire byte order (reversed
    /// character order — see `EnergyProvider`'s doc comment).
    private static func encodeSMCKey(_ key: String) -> [UInt8]? {
        let characters = Array(key.utf8)
        guard characters.count == 4 else { return nil }
        return Array(characters.reversed())
    }

    /// Inverse of `encodeSMCKey`, used both to decode a `dataType`
    /// four-character code and to decode a resolved key name from
    /// `kSMCGetKeyFromIndex`'s response.
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
    /// AppleSMC "handle event" selector. `nil` on any failure — the kernel
    /// call itself failing, or a non-success `result` byte (most commonly
    /// `kSMCKeyNotFound`, the expected outcome for an index past the end
    /// of the table or a key this Mac's firmware doesn't publish).
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
}

// MARK: - Little-endian byte helper

private extension UInt32 {
    /// Reassembles a little-endian `UInt32` from exactly 4 bytes — same
    /// helper as `EnergyProvider`'s private copy, duplicated here per this
    /// type's doc comment on why the SMC section is self-contained rather
    /// than a shared dependency. `private` at file scope keeps the two
    /// declarations from colliding.
    init(littleEndianBytes bytes: ArraySlice<UInt8>) {
        precondition(bytes.count == 4)
        var value: UInt32 = 0
        for (index, byte) in bytes.enumerated() {
            value |= UInt32(byte) << (8 * index)
        }
        self = value
    }
}
