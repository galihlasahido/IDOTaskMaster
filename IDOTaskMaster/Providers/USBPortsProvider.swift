import Darwin
import Foundation
import IOKit

/// One physical USB-C / MagSafe port's reading as of a sample — the "USB &
/// Ports" page's core row. `id` is the port node's `PortDescription`
/// (e.g. `"Port-USB-C@1"`), stable for the life of the boot.
struct USBPortSnapshot: Sendable, Equatable, Identifiable {
    let id: String
    /// Short human name derived from the port node, e.g. "USB-C 1",
    /// "MagSafe 3".
    let name: String
    /// `PortTypeDescription`: `"USB-C"` or `"MagSafe 3"`.
    let portType: String
    /// `ConnectionActive` — whether anything is physically attached right
    /// now.
    let isConnected: Bool
    /// `IOAccessoryUSBConnectString` when connected (e.g. `"Device"`,
    /// `"Host"`); `nil` when nothing meaningful is attached.
    let connectString: String?
    /// `TransportsProvisioned` — the transports actually brought up for
    /// the current connection (e.g. `["CC", "USB2", "USB3",
    /// "DisplayPort"]`). Empty when nothing is connected.
    let activeTransports: [String]
    /// `TransportsSupported` — everything this port could carry.
    let supportedTransports: [String]
    /// `ConnectionCount` — connections seen on this port since boot.
    let connectionCount: Int?
    /// `Overcurrent Count` — power-fault events on this port since boot.
    let overcurrentCount: Int?
    /// `LDCM_LiquidDetected` — the port's liquid-detection sensor.
    /// `nil` when the port doesn't expose the property at all.
    let liquidDetected: Bool?
    /// `ActiveCable` — whether the attached cable identifies as active
    /// (redriver/retimer electronics inside). `nil` when unknown.
    let activeCable: Bool?
    /// `PlugOrientation` — which way up the connector was inserted (1/2),
    /// `nil` when nothing is plugged in or the property is absent.
    let plugOrientation: Int?
    /// Live electrical readings for this port from the SMC's per-port
    /// power channels; `nil` when no channel maps to this port (older
    /// silicon, or the SMC read failed this sample).
    let volts: Double?
    let amps: Double?
    /// `volts * amps` — `nil` when either is.
    var watts: Double? {
        guard let volts, let amps else { return nil }
        return volts * amps
    }
    /// Cable e-marker identity (from the port's SOP' responder), when a
    /// marked cable is attached and macOS has read its chip. Plain
    /// passive USB 2.0 cables have no e-marker, so `nil` here is the
    /// common, honest case — not a failure.
    let cable: USBCableInfo?
    /// The attached device/charger's PD identity (from the port's SOP
    /// responder), when one responded to Discover Identity.
    let partner: USBPartnerInfo?
    /// The data link actually negotiated on this port right now (from the
    /// port's active `IOPortTransportState*` child node) — what the
    /// connection really runs at, as opposed to what the cable's e-marker
    /// says the cable could do. `nil` when no data transport is active.
    let negotiatedLink: USBLinkInfo?
}

/// The port's live, negotiated data link — read off the active
/// `IOPortTransportStateCIO`/`USB3`/`USB2` child of the port node
/// (preferring the fastest transport class that's active).
struct USBLinkInfo: Sendable, Equatable {
    /// `DataRateDescription`, macOS's own display string (e.g.
    /// `"10 Gbps"`, `"480 Mbps"`).
    let rateDescription: String
    /// `SuperSpeedSignalingDescription` when present (e.g. `"Gen 2"`).
    let generationDescription: String?
    /// `rateDescription` parsed to Gbps for comparing against the cable's
    /// rated ceiling; `nil` when the string isn't a recognizable rate.
    let gbps: Double?
}

/// A cable e-marker's decoded identity — what the chip inside the cable
/// itself reports over USB-PD (SOP' Discover Identity), read back out of
/// the properties macOS already stores on the port's SOP' registry node.
/// This app never talks to the chip; the kernel already did.
struct USBCableInfo: Sendable, Equatable {
    /// `Product Type Description`, e.g. `"Passive Cable"` /
    /// `"Active Cable"` — macOS's own decode of the ID Header VDO.
    let productType: String?
    /// USB-IF vendor ID from the ID header (`Vendor ID`), `nil` when the
    /// chip reported 0 (unregistered — common on inexpensive cables).
    let vendorID: Int?
    /// Decoded from the Cable VDO's USB Highest Speed field (bits 2..0,
    /// USB PD spec) — `nil` when the VDO wasn't present or the value is a
    /// reserved bit pattern this decoder doesn't recognize.
    let maxSpeedLabel: String?
    /// The same field as a number, for comparing against the live link
    /// rate. Same `nil` rule as `maxSpeedLabel`.
    let maxSpeedGbps: Double?
    /// Decoded from the Cable VDO's VBUS Current Handling field (bits
    /// 6..5): 3 A (up to 60 W) or 5 A (up to 240 W with EPR). Same `nil`
    /// rule as `maxSpeedLabel`.
    let currentRatingLabel: String?

    /// `true` when the e-marker's claims fit a profile that, in practice,
    /// signals sloppy or dishonest chip programming: a *passive* cable
    /// claiming the very top of the speed scale (USB4 Gen 4, 80 Gbps)
    /// from an *unregistered* vendor. Real passive Gen 4 cables are short
    /// Thunderbolt 5 cables from vendors with USB-IF registrations; this
    /// combination was also verified empirically on this project's dev
    /// hardware — a cable carrying exactly this profile measured 4–8×
    /// slower than a correctly-programmed 40 Gbps cable on the identical
    /// port/enclosure, while negotiating the identical link rate.
    /// Deliberately narrow: an unregistered vendor alone is NOT flagged
    /// (plenty of honest budget cables ship unregistered e-markers), and
    /// neither is a high claim from a registered vendor. A flag means
    /// "this claim is unusual, treat it skeptically" — never "this cable
    /// is fake."
    var claimLooksImplausible: Bool {
        vendorID == nil
            && (maxSpeedGbps ?? 0) >= 80
            && (productType?.localizedCaseInsensitiveContains("passive") ?? false)
    }
}

/// The port partner's (device/charger at the far end) PD identity from the
/// SOP responder node.
struct USBPartnerInfo: Sendable, Equatable {
    let vendorID: Int?
    let productID: Int?
    let productType: String?
}

/// One USB device from the live bus tree (`IOUSBHostDevice`).
struct USBDeviceSnapshot: Sendable, Equatable, Identifiable {
    /// The registry entry ID — unique per attached device instance.
    let id: UInt64
    let name: String
    let vendorName: String?
    let vendorID: Int?
    let productID: Int?
    /// `USBSpeed` decoded to a link-speed label (USB spec enumeration
    /// macOS uses: 1 = 1.5 Mbps ... 5 = 10 Gbps, 6 = 20 Gbps).
    let speedLabel: String?
    /// Nesting depth in the bus topology (0 = attached straight to a
    /// controller/port, 1 = behind one hub, ...) — drives the tree
    /// indentation on the page without needing a recursive UI.
    let depth: Int
}

/// One sample of the whole USB/ports domain.
struct USBPortsSnapshot: Sendable, Equatable {
    let ports: [USBPortSnapshot]
    let devices: [USBDeviceSnapshot]
}

enum USBPortsProviderError: Error, LocalizedError {
    /// No port-controller nodes at all — Intel Macs (whose USB-C
    /// controllers don't publish these classes), and the front ports of
    /// Apple-silicon desktops (plain USB behind an internal hub), land
    /// here.
    case noPortControllersFound

    var errorDescription: String? {
        switch self {
        case .noPortControllersFound:
            return "No USB-C port controller (AppleHPMInterface/AppleTCController) found in the IORegistry — this Mac doesn't expose per-port data"
        }
    }
}

/// Samples the physical USB-C/MagSafe ports, their live power draw, any
/// attached cable's e-marker identity, and the USB device tree.
///
/// Three IORegistry/SMC sources, all verified live on this dev Mac:
///
/// 1. **Port controllers** — `AppleHPMInterfaceType10` (USB-C) and
///    `Type11` (MagSafe) on M3-era silicon; `AppleTCControllerType10/11`
///    on M1/M2 (matched too, harmlessly absent here). Properties carry the
///    connection state, provisioned transports, plug orientation,
///    connection/overcurrent counters, and the liquid-detection sensor.
/// 2. **Per-port power** — the SMC publishes four channels `D1..D4`
///    (`DxJV` volts, `DxJI` amps, `DxUI` a 16-byte UUID). The UUID
///    matches the `UUID` property of the port node's parent
///    `AppleHPMDeviceHAL*` node, which is how a channel is tied to a
///    physical port. Same 80-byte `AppleSMC` user-client wire protocol
///    `EnergyProvider`/`ThermalProvider` already use (each provider keeps
///    its own private copy by this codebase's existing convention).
/// 3. **Cable/partner identity** — when a marked cable (or PD device) is
///    attached, macOS runs USB-PD Discover Identity itself and stores the
///    responses as `IOPortTransportComponentCCUSBPDSOPp` (the cable's own
///    e-marker chip) / `...SOP` (the far-end device) registry nodes. This
///    provider reads those stored properties and decodes the two Cable
///    VDO fields worth surfacing (max speed, current rating) per the USB
///    PD R3.x spec bit layout.
///
/// Everything degrades honestly: a missing SMC channel, an unmarked
/// cable, or an absent property is a `nil` field, never a guess — and a
/// Mac with no port-controller nodes at all throws
/// `noPortControllersFound` so the page can say so plainly.
final class USBPortsProvider {
    private var smcConnection: io_connect_t?
    private var smcOpenAttempted = false

    /// The port-controller classes to match, most-specific first. The
    /// class name varies by chip generation — see this type's doc
    /// comment. A class that doesn't exist on this Mac simply matches
    /// nothing.
    private static let portControllerClasses = [
        "AppleHPMInterfaceType10", // USB-C (M3-era and later)
        "AppleHPMInterfaceType11", // MagSafe (M3-era and later)
        "AppleHPMInterfaceType12",
        "AppleHPMInterfaceType18",
        "AppleTCControllerType10", // USB-C (M1/M2)
        "AppleTCControllerType11", // MagSafe (M1/M2)
    ]

    deinit {
        if let smcConnection {
            IOServiceClose(smcConnection)
        }
    }

    func sample() throws -> USBPortsSnapshot {
        let powerChannels = readSMCPortPowerChannels()
        var ports: [USBPortSnapshot] = []
        var seenPortIDs = Set<String>()

        for className in Self.portControllerClasses {
            guard let matching = IOServiceMatching(className) else { continue }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }

            var service = IOIteratorNext(iterator)
            while service != 0 {
                defer {
                    IOObjectRelease(service)
                    service = IOIteratorNext(iterator)
                }
                guard let port = Self.readPort(service: service, powerChannels: powerChannels),
                      !seenPortIDs.contains(port.id) else { continue }
                seenPortIDs.insert(port.id)
                ports.append(port)
            }
        }

        guard !ports.isEmpty else {
            throw USBPortsProviderError.noPortControllersFound
        }

        // Stable, human order: USB-C ports by number, then MagSafe.
        ports.sort { a, b in
            if (a.portType == b.portType) { return a.name < b.name }
            return a.portType < b.portType
        }

        return USBPortsSnapshot(ports: ports, devices: Self.readUSBDeviceTree())
    }

    // MARK: - Port controllers

    private static func readPort(service: io_service_t, powerChannels: [SMCPortPowerChannel]) -> USBPortSnapshot? {
        guard let props = registryProperties(of: service) else { return nil }
        // Internal DRD ports and other non-physical nodes have no
        // `PortTypeDescription` / `Port-` description — skip them.
        guard let portDescription = props["PortDescription"] as? String,
              portDescription.hasPrefix("Port-"),
              let portType = props["PortTypeDescription"] as? String else { return nil }

        let isConnected = (props["ConnectionActive"] as? Bool) ?? false

        // Tie this port to its SMC power channel via the parent HAL
        // node's UUID — see this type's doc comment.
        var volts: Double?
        var amps: Double?
        if let halUUID = parentHALUUID(of: service),
           let channel = powerChannels.first(where: { $0.uuid.caseInsensitiveCompare(halUUID) == .orderedSame }) {
            volts = channel.volts
            amps = channel.amps
        }

        let (cable, partner, negotiatedLink) = readPortChildren(portService: service)

        return USBPortSnapshot(
            id: portDescription,
            name: friendlyPortName(portDescription: portDescription, portType: portType),
            portType: portType,
            isConnected: isConnected,
            connectString: isConnected ? (props["IOAccessoryUSBConnectString"] as? String) : nil,
            activeTransports: isConnected ? ((props["TransportsProvisioned"] as? [String]) ?? []) : [],
            supportedTransports: (props["TransportsSupported"] as? [String]) ?? [],
            connectionCount: props["ConnectionCount"] as? Int,
            overcurrentCount: props["Overcurrent Count"] as? Int,
            liquidDetected: props["LDCM_LiquidDetected"] as? Bool,
            activeCable: isConnected ? (props["ActiveCable"] as? Bool) : nil,
            plugOrientation: isConnected ? (props["PlugOrientation"] as? Int) : nil,
            volts: volts,
            amps: amps,
            cable: cable,
            partner: partner,
            negotiatedLink: isConnected ? negotiatedLink : nil
        )
    }

    /// `"Port-USB-C@1"` → `"USB-C 1"`, `"Port-MagSafe 3@1"` → `"MagSafe 3"`.
    private static func friendlyPortName(portDescription: String, portType: String) -> String {
        guard let atIndex = portDescription.lastIndex(of: "@") else { return portType }
        let number = portDescription[portDescription.index(after: atIndex)...]
        // MagSafe is a single port — appending "@1" would just be noise.
        if portType.hasPrefix("MagSafe") { return portType }
        return "\(portType) \(number)"
    }

    /// Walks up the IOService plane to the nearest ancestor whose class
    /// name contains "HPMDeviceHAL" or "TCController" *and* carries a
    /// `UUID` property — the node the SMC's `DxUI` channel UUIDs refer to.
    private static func parentHALUUID(of service: io_service_t) -> String? {
        var current: io_registry_entry_t = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        for _ in 0..<4 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(current)
            current = parent

            if let uuidUnmanaged = IORegistryEntryCreateCFProperty(current, "UUID" as CFString, kCFAllocatorDefault, 0),
               let uuid = uuidUnmanaged.takeRetainedValue() as? String {
                // Strip dashes to match the SMC's bare-hex form.
                return uuid.replacingOccurrences(of: "-", with: "")
            }
        }
        return nil
    }

    // MARK: - Port children (PD identities + negotiated link)

    /// One walk over the port node's descendants, collecting everything
    /// that lives under it: the SOP'/SOP PD responder nodes (whose
    /// `Description` is rooted at the port's own, e.g.
    /// `"Port-USB-C@1/CC/SOP'"` — what ties a responder to its port when
    /// several ports have things attached), and the active
    /// `IOPortTransportState*` node describing the negotiated data link.
    /// When more than one transport is active (a USB2 fallback link often
    /// stays up alongside USB3), the fastest transport class wins: CIO
    /// (Thunderbolt/USB4) over USB3 over USB2.
    private static func readPortChildren(portService: io_service_t) -> (USBCableInfo?, USBPartnerInfo?, USBLinkInfo?) {
        var cable: USBCableInfo?
        var partner: USBPartnerInfo?
        var linkByClass: [String: USBLinkInfo] = [:]

        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            portService, kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively), &iterator
        ) == KERN_SUCCESS else { return (nil, nil, nil) }
        defer { IOObjectRelease(iterator) }

        var child = IOIteratorNext(iterator)
        while child != 0 {
            defer {
                IOObjectRelease(child)
                child = IOIteratorNext(iterator)
            }
            var classNameBuffer = [CChar](repeating: 0, count: 128)
            guard IOObjectGetClass(child, &classNameBuffer) == KERN_SUCCESS else { continue }
            let className = String(cString: classNameBuffer)

            if className == "IOPortTransportComponentCCUSBPDSOPp", cable == nil {
                cable = readCableInfo(sopPrimeService: child)
            } else if className == "IOPortTransportComponentCCUSBPDSOP", partner == nil {
                partner = readPartnerInfo(sopService: child)
            } else if className.hasPrefix("IOPortTransportState"), linkByClass[className] == nil {
                if let link = readLinkInfo(transportService: child) {
                    linkByClass[className] = link
                }
            }
        }

        let link = linkByClass["IOPortTransportStateCIO"]
            ?? linkByClass["IOPortTransportStateUSB3"]
            ?? linkByClass["IOPortTransportStateUSB2"]
        return (cable, partner, link)
    }

    /// Reads one transport-state node's negotiated rate — only when the
    /// transport is actually `Active` and reports a `DataRateDescription`.
    private static func readLinkInfo(transportService: io_service_t) -> USBLinkInfo? {
        guard let props = registryProperties(of: transportService),
              (props["Active"] as? Bool) == true,
              let rateDescription = props["DataRateDescription"] as? String, !rateDescription.isEmpty else {
            return nil
        }
        return USBLinkInfo(
            rateDescription: rateDescription,
            generationDescription: props["SuperSpeedSignalingDescription"] as? String,
            gbps: parseGbps(rateDescription)
        )
    }

    /// `"10 Gbps"` → 10, `"480 Mbps"` → 0.48; `nil` for anything else.
    private static func parseGbps(_ rateDescription: String) -> Double? {
        let parts = rateDescription.split(separator: " ")
        guard parts.count == 2, let value = Double(parts[0]) else { return nil }
        switch parts[1] {
        case "Gbps": return value
        case "Mbps": return value / 1000
        default: return nil
        }
    }

    private static func readCableInfo(sopPrimeService: io_service_t) -> USBCableInfo? {
        guard let props = registryProperties(of: sopPrimeService) else { return nil }
        let metadata = props["Metadata"] as? [String: Any]

        let vendorIDRaw = (props["Vendor ID"] as? Int) ?? (metadata?["Vendor ID"] as? Int)
        var maxSpeed: (label: String, gbps: Double)?
        var currentRatingLabel: String?

        // The Cable VDO is the 4th VDO of a cable's Discover Identity
        // response (ID Header, Cert Stat, Product, Cable — USB PD R3.x
        // §6.4.4.3). macOS stores the raw responses as an array of 4-byte
        // little-endian values.
        if let vdos = metadata?["VDOs"] as? [Data], vdos.count >= 4, vdos[3].count >= 4 {
            let cableVDO = vdos[3].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
            maxSpeed = Self.cableSpeed(rawBits: Int(cableVDO & 0b111))
            currentRatingLabel = Self.cableCurrentLabel(rawBits: Int((cableVDO >> 5) & 0b11))
        }

        let info = USBCableInfo(
            productType: (props["Product Type Description"] as? String) ?? (metadata?["Product Type Description"] as? String),
            vendorID: (vendorIDRaw ?? 0) == 0 ? nil : vendorIDRaw,
            maxSpeedLabel: maxSpeed?.label,
            maxSpeedGbps: maxSpeed?.gbps,
            currentRatingLabel: currentRatingLabel
        )
        // A node with nothing readable at all isn't a cable reading.
        if info.productType == nil && info.vendorID == nil && info.maxSpeedLabel == nil {
            return nil
        }
        return info
    }

    private static func readPartnerInfo(sopService: io_service_t) -> USBPartnerInfo? {
        guard let props = registryProperties(of: sopService) else { return nil }
        let metadata = props["Metadata"] as? [String: Any]
        let vendorID = (props["Vendor ID"] as? Int) ?? (metadata?["Vendor ID"] as? Int)
        let productID = (props["Product ID"] as? Int) ?? (metadata?["Product ID"] as? Int)
        let productType = (props["Product Type Description"] as? String) ?? (metadata?["Product Type Description"] as? String)
        guard vendorID != nil || productID != nil || productType != nil else { return nil }
        return USBPartnerInfo(
            vendorID: (vendorID ?? 0) == 0 ? nil : vendorID,
            productID: (productID ?? 0) == 0 ? nil : productID,
            productType: productType
        )
    }

    /// USB PD Cable VDO "USB Highest Speed" field (bits 2..0).
    private static func cableSpeed(rawBits: Int) -> (label: String, gbps: Double)? {
        switch rawBits {
        case 0: return ("USB 2.0 (480 Mbps)", 0.48)
        case 1: return ("USB 3.2 Gen 1 (5 Gbps)", 5)
        case 2: return ("USB 3.2 Gen 2 (10 Gbps)", 10)
        case 3: return ("USB4 Gen 3 (40 Gbps)", 40)
        case 4: return ("USB4 Gen 4 (80 Gbps)", 80)
        default: return nil // reserved bit pattern — honest "unknown"
        }
    }

    /// USB PD Cable VDO "VBUS Current Handling" field (bits 6..5).
    private static func cableCurrentLabel(rawBits: Int) -> String? {
        switch rawBits {
        case 1: return "3 A (up to 60 W)"
        case 2: return "5 A (up to 240 W)"
        default: return nil // 0 = reserved/USB-default, 3 = reserved
        }
    }

    // MARK: - USB device tree

    /// All `IOUSBHostDevice` nodes, flattened parent-before-child with a
    /// `depth` per node (0 = no USB-device ancestor). Depth is computed by
    /// counting `IOUSBHostDevice` ancestors in the IOService plane, which
    /// is the same topology the USB bus itself has (a device behind a hub
    /// has that hub's device node as an ancestor).
    private static func readUSBDeviceTree() -> [USBDeviceSnapshot] {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        struct RawDevice {
            let entryID: UInt64
            let parentChain: Set<UInt64>
            let snapshotBase: USBDeviceSnapshot
        }
        var rawDevices: [RawDevice] = []

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS,
                  let props = registryProperties(of: service) else { continue }

            let name = (props["USB Product Name"] as? String)
                ?? (props["kUSBProductString"] as? String)
                ?? "USB Device"

            rawDevices.append(RawDevice(
                entryID: entryID,
                parentChain: usbAncestorEntryIDs(of: service),
                snapshotBase: USBDeviceSnapshot(
                    id: entryID,
                    name: name,
                    vendorName: (props["USB Vendor Name"] as? String) ?? (props["kUSBVendorString"] as? String),
                    vendorID: props["idVendor"] as? Int,
                    productID: props["idProduct"] as? Int,
                    speedLabel: usbSpeedLabel(props["USBSpeed"] as? Int),
                    depth: 0
                )
            ))
        }

        // Depth = how many of the *other* found devices are ancestors.
        let allIDs = Set(rawDevices.map(\.entryID))
        var result: [USBDeviceSnapshot] = []
        for raw in rawDevices.sorted(by: { $0.parentChain.count < $1.parentChain.count }) {
            let depth = raw.parentChain.intersection(allIDs).count
            let base = raw.snapshotBase
            result.append(USBDeviceSnapshot(
                id: base.id, name: base.name, vendorName: base.vendorName,
                vendorID: base.vendorID, productID: base.productID,
                speedLabel: base.speedLabel, depth: depth
            ))
        }
        return result
    }

    /// Registry entry IDs of every `IOUSBHostDevice` ancestor of `service`
    /// (walking the IOService plane upward).
    private static func usbAncestorEntryIDs(of service: io_service_t) -> Set<UInt64> {
        var result = Set<UInt64>()
        var current: io_registry_entry_t = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        while true {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(current)
            current = parent

            if IOObjectConformsTo(current, "IOUSBHostDevice") == boolean_t(1) {
                var entryID: UInt64 = 0
                if IORegistryEntryGetRegistryEntryID(current, &entryID) == KERN_SUCCESS {
                    result.insert(entryID)
                }
            }
        }
        return result
    }

    /// `USBSpeed`'s enumeration per `<IOKit/usb/AppleUSBDefinitions.h>`.
    private static func usbSpeedLabel(_ raw: Int?) -> String? {
        switch raw {
        case 1: return "1.5 Mbps (Low)"
        case 2: return "12 Mbps (Full)"
        case 3: return "480 Mbps (High)"
        case 4: return "5 Gbps (SuperSpeed)"
        case 5: return "10 Gbps (SuperSpeed+)"
        case 6: return "20 Gbps (SuperSpeed+ ×2)"
        default: return nil
        }
    }

    // MARK: - Shared helpers

    private static func registryProperties(of service: io_registry_entry_t) -> [String: Any]? {
        var propertiesUnmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propertiesUnmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = propertiesUnmanaged?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return properties
    }

    // MARK: - SMC per-port power (private copy, matching EnergyProvider's convention)

    /// One SMC power channel: `DxUI` (bare-hex UUID tying it to a port's
    /// HAL node), `DxJV` volts, `DxJI` amps.
    private struct SMCPortPowerChannel {
        let uuid: String
        let volts: Double
        let amps: Double
    }

    /// Reads channels `D1..D4`. Empty when the SMC can't be opened or the
    /// keys aren't published (older silicon) — per-port power simply shows
    /// as Unavailable then.
    private func readSMCPortPowerChannels() -> [SMCPortPowerChannel] {
        guard let connection = openSMCConnectionIfNeeded() else { return [] }
        var channels: [SMCPortPowerChannel] = []
        for index in 1...4 {
            guard let uuidBytes = Self.readSMCKeyBytes(connection: connection, key: "D\(index)UI"),
                  !uuidBytes.isEmpty else { continue }
            let uuid = uuidBytes.map { String(format: "%02X", $0) }.joined()
            let volts = Self.readSMCFloat(connection: connection, key: "D\(index)JV") ?? 0
            let amps = Self.readSMCFloat(connection: connection, key: "D\(index)JI") ?? 0
            channels.append(SMCPortPowerChannel(uuid: uuid, volts: Double(volts), amps: Double(amps)))
        }
        return channels
    }

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

    /// The same 80-byte `AppleSMC` wire layout `EnergyProvider.SMCWire`
    /// documents — see that type for the field-by-field rationale.
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

    private static func encodeSMCKey(_ key: String) -> [UInt8]? {
        let characters = Array(key.utf8)
        guard characters.count == 4 else { return nil }
        return Array(characters.reversed())
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

    /// Reads one key's raw value bytes (get-info for the size, then the
    /// read call). `nil` on any failure — including the expected
    /// key-not-found on Macs whose firmware doesn't publish it.
    private static func readSMCKeyBytes(connection: io_connect_t, key: String) -> [UInt8]? {
        guard let keyBytes = encodeSMCKey(key) else { return nil }
        guard let infoOutput = callSMC(connection, makeSMCInput(keyBytes: keyBytes, op: SMCWire.getKeyInfoOp)) else {
            return nil
        }
        let dataSize = UInt32(infoOutput[SMCWire.dataSizeOffset])
            | (UInt32(infoOutput[SMCWire.dataSizeOffset + 1]) << 8)
            | (UInt32(infoOutput[SMCWire.dataSizeOffset + 2]) << 16)
            | (UInt32(infoOutput[SMCWire.dataSizeOffset + 3]) << 24)
        guard dataSize > 0, dataSize <= 32 else { return nil }
        guard let readOutput = callSMC(connection, makeSMCInput(keyBytes: keyBytes, op: SMCWire.readKeyOp, dataSize: dataSize)) else {
            return nil
        }
        return Array(readOutput[SMCWire.dataOffset..<(SMCWire.dataOffset + Int(dataSize))])
    }

    /// Reads one key as a little-endian IEEE-754 float (`flt ` — the type
    /// `DxJV`/`DxJI` report).
    private static func readSMCFloat(connection: io_connect_t, key: String) -> Float? {
        guard let bytes = readSMCKeyBytes(connection: connection, key: key), bytes.count >= 4 else { return nil }
        var value: Float = 0
        _ = withUnsafeMutableBytes(of: &value) { raw in
            raw.copyBytes(from: bytes.prefix(4))
        }
        return value
    }
}
