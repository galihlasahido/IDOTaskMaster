import Darwin
import Foundation

/// One network interface's reading as of a tick — PLAN.md §4 M2's
/// "per-interface ... send/receive rates and totals". `id` is the BSD
/// interface name (e.g. `"en0"`, `"lo0"`, `"utun0"`), stable for the life
/// of a still-attached interface (macOS doesn't renumber one), so it
/// doubles as a `ForEach`/chart key and as the dictionary key
/// `NetworkProvider` diffs successive ticks against.
struct NetworkInterfaceSnapshot: Sendable, Equatable, Identifiable {
    let id: String
    /// `IFF_LOOPBACK` — true only for `lo0`. Excluded from
    /// `NetworkSnapshot`'s combined headline figures (see that type's doc
    /// comment) but still listed here for a future per-interface detail
    /// view (PLAN.md §1.1's Performance "Network detail ... interface
    /// info").
    let isLoopback: Bool
    /// `IFF_UP` — whether the interface is currently administratively up.
    let isUp: Bool
    /// Bytes sent/received since the previous tick, divided by the elapsed
    /// seconds. `nil` on the first tick after launch (or the first tick
    /// after this interface appeared, e.g. a VPN's `utun0` mid-session) —
    /// there is no prior sample to diff against.
    let sendBytesPerSecond: Double?
    let receiveBytesPerSecond: Double?
    /// Cumulative bytes/packets sent and received since boot
    /// (`if_data64`'s `ifi_obytes`/`ifi_ibytes`/`ifi_opackets`/
    /// `ifi_ipackets`) — always real values, never `nil`, since an
    /// interface with no readable `RTM_IFINFO2` record is dropped before a
    /// `NetworkInterfaceSnapshot` is built for it (see
    /// `NetworkProvider.readInterface`).
    let totalBytesSent: UInt64
    let totalBytesReceived: UInt64
    let totalPacketsSent: UInt64
    let totalPacketsReceived: UInt64
}

/// One tick's network reading — PLAN.md §4 M2's "per-interface + combined
/// send/receive rates and totals", merged into `Snapshot.network`.
///
/// The top-level `sendBytesPerSecond`/`receiveBytesPerSecond`/
/// `totalBytesSent`/`totalBytesReceived` fields are the headline "combined
/// interfaces throughput" figure for the Performance/Summary pages'
/// Network tile (PLAN.md §1.1: "combined interfaces throughput graph
/// (send/receive), totals"): the *sum* across every non-loopback
/// interface. Loopback (`lo0`) traffic is local IPC that never touches the
/// network, so folding it in would inflate the headline with numbers that
/// don't correspond to anything a user would recognize as "network
/// activity" — matching Activity Monitor's own Network tab, which doesn't
/// count it either. Full per-interface detail, loopback included, lives in
/// `interfaces` for a future per-interface selector UI.
struct NetworkSnapshot: Sendable, Equatable {
    /// See this type's doc comment — sum of every non-loopback interface's
    /// `sendBytesPerSecond` that had one to report this tick; `nil` only
    /// when *no* non-loopback interface had a prior sample to diff against
    /// yet (i.e. this is the very first tick after launch).
    let sendBytesPerSecond: Double?
    let receiveBytesPerSecond: Double?
    /// Sum of every non-loopback interface's cumulative bytes sent/received
    /// since boot.
    let totalBytesSent: UInt64
    let totalBytesReceived: UInt64
    /// One entry per interface the routing socket reported this tick,
    /// loopback included.
    let interfaces: [NetworkInterfaceSnapshot]
}

/// Failure modes for `NetworkProvider.sample()` — see `Provider`'s doc
/// comment for when a provider throws versus returning `nil` fields.
enum NetworkProviderError: Error, LocalizedError {
    /// The `sysctl` size-query call failed.
    case sysctlSizeQueryFailed(errno: Int32)
    /// The `sysctl` data-read call failed.
    case sysctlReadFailed(errno: Int32)
    /// The read succeeded but produced no usable `RTM_IFINFO2` records —
    /// shouldn't happen on real Mac hardware (there's always at least
    /// `lo0`), but treated as the domain being entirely unreadable this
    /// tick, matching `DiskProvider`'s `noBlockStorageDriversFound`.
    case noInterfacesFound

    var errorDescription: String? {
        switch self {
        case .sysctlSizeQueryFailed(let errno):
            return "sysctl(NET_RT_IFLIST2) size query failed (errno \(errno))"
        case .sysctlReadFailed(let errno):
            return "sysctl(NET_RT_IFLIST2) read failed (errno \(errno))"
        case .noInterfacesFound:
            return "sysctl(NET_RT_IFLIST2) returned no RTM_IFINFO2 records"
        }
    }
}

/// Samples per-interface network throughput and totals — PLAN.md §3
/// `Providers/NetworkProvider.swift "getifaddrs / NET_RT_IFLIST2 interface
/// counters"` and §4 M2's fifth task.
///
/// Every network interface on macOS is enumerable through the routing
/// socket's `NET_RT_IFLIST2` sysctl (`CTL_NET, PF_ROUTE, 0, 0,
/// NET_RT_IFLIST2, 0`), which returns a buffer of variable-length
/// `if_msghdr2` records — one `RTM_IFINFO2` per interface, each embedding
/// an `if_data64`: a *64-bit* cumulative counters struct (bytes/packets in
/// and out since boot, plus the interface's flags). This provider is built
/// on that call rather than `getifaddrs`'s `AF_LINK` entries (also named
/// in PLAN.md as an alternative technique): `getifaddrs` exposes the same
/// counters through the older 32-bit `if_data` struct, which wraps around
/// at 4 GiB — a real concern for a long-uptime Mac's cumulative Wi-Fi/
/// Ethernet totals. `NET_RT_IFLIST2` is the same routing-socket technique
/// `netstat -I` and third-party menu-bar monitors use for accurate
/// long-run totals. As with `IOBlockStorageDriver`'s disk counters, macOS
/// doesn't publish an instantaneous network-rate API, so rates are derived
/// by diffing this tick's cumulative counters against the previous tick's
/// — the same technique `DiskProvider` uses for disk throughput.
///
/// A `final class`, matching `DiskProvider`'s convention and for the same
/// reason: `previousInterfaceStates` carries each interface's raw
/// cumulative counters and a timestamp forward so the *next* tick can diff
/// against them. `Sampler` owns one long-lived instance and calls
/// `sample()` every tick from its own actor-isolated `tick()`, so this
/// mutable state is never touched concurrently — no locking needed.
final class NetworkProvider: Provider {
    static let providerID = "network"

    /// Raw cumulative counters from each interface's previous successful
    /// sample, keyed by BSD interface name. Missing entries (an interface
    /// seen for the first time — e.g. a VPN's `utun` appearing mid-session
    /// — or a full reset after a domain-wide failure) simply produce `nil`
    /// rates for that interface this tick — the same "no prior sample,
    /// honestly `nil`" rule `DiskProvider` follows.
    private var previousInterfaceStates: [String: InterfaceRawState] = [:]

    func sample() throws -> NetworkSnapshot {
        let rawInterfaces: [RawInterface]
        do {
            rawInterfaces = try Self.readInterfaces()
        } catch {
            // Whole domain unreadable this tick — clear prior state so a
            // later recovery doesn't diff against now-stale counts,
            // matching CPUProvider/DiskProvider's handling of their own
            // domain-wide read failures.
            previousInterfaceStates = [:]
            throw error
        }

        let now = Date()
        var newStates: [String: InterfaceRawState] = [:]
        newStates.reserveCapacity(rawInterfaces.count)

        var interfaceSnapshots: [NetworkInterfaceSnapshot] = []
        interfaceSnapshots.reserveCapacity(rawInterfaces.count)

        var totalBytesSent: UInt64 = 0
        var totalBytesReceived: UInt64 = 0
        var summedSendRate: Double = 0
        var summedReceiveRate: Double = 0
        var haveAnyRate = false

        for interface in rawInterfaces {
            if !interface.isLoopback {
                totalBytesSent += interface.bytesSent
                totalBytesReceived += interface.bytesReceived
            }

            newStates[interface.name] = InterfaceRawState(
                bytesSent: interface.bytesSent,
                bytesReceived: interface.bytesReceived,
                timestamp: now
            )

            var sendRate: Double?
            var receiveRate: Double?

            if let previous = previousInterfaceStates[interface.name] {
                let elapsed = now.timeIntervalSince(previous.timestamp)
                if elapsed > 0,
                   let sentDelta = Self.nonNegativeDelta(interface.bytesSent, previous.bytesSent),
                   let receivedDelta = Self.nonNegativeDelta(interface.bytesReceived, previous.bytesReceived) {
                    let computedSendRate = Double(sentDelta) / elapsed
                    let computedReceiveRate = Double(receivedDelta) / elapsed
                    sendRate = computedSendRate
                    receiveRate = computedReceiveRate
                    if !interface.isLoopback {
                        summedSendRate += computedSendRate
                        summedReceiveRate += computedReceiveRate
                        haveAnyRate = true
                    }
                }
            }

            interfaceSnapshots.append(
                NetworkInterfaceSnapshot(
                    id: interface.name,
                    isLoopback: interface.isLoopback,
                    isUp: interface.isUp,
                    sendBytesPerSecond: sendRate,
                    receiveBytesPerSecond: receiveRate,
                    totalBytesSent: interface.bytesSent,
                    totalBytesReceived: interface.bytesReceived,
                    totalPacketsSent: interface.packetsSent,
                    totalPacketsReceived: interface.packetsReceived
                )
            )
        }

        previousInterfaceStates = newStates

        return NetworkSnapshot(
            sendBytesPerSecond: haveAnyRate ? summedSendRate : nil,
            receiveBytesPerSecond: haveAnyRate ? summedReceiveRate : nil,
            totalBytesSent: totalBytesSent,
            totalBytesReceived: totalBytesReceived,
            interfaces: interfaceSnapshots
        )
    }

    // MARK: - Per-tick diff state

    private struct InterfaceRawState {
        let bytesSent: UInt64
        let bytesReceived: UInt64
        let timestamp: Date
    }

    /// One interface's raw reading for a single tick, before it's diffed
    /// against the previous tick to produce a `NetworkInterfaceSnapshot`.
    private struct RawInterface {
        let name: String
        let isLoopback: Bool
        let isUp: Bool
        let bytesSent: UInt64
        let bytesReceived: UInt64
        let packetsSent: UInt64
        let packetsReceived: UInt64
    }

    // MARK: - NET_RT_IFLIST2 (routing socket sysctl)

    /// Reads every interface's current cumulative counters via
    /// `sysctl(CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0)`, which fills a
    /// buffer with variable-length `if_msghdr2` records (one `RTM_IFINFO2`
    /// per interface). Throws `NetworkProviderError` when either `sysctl`
    /// call fails or the buffer yields no interface records at all — both
    /// this domain's "entirely unreadable this tick" case.
    private static func readInterfaces() throws -> [RawInterface] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]

        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0 else {
            throw NetworkProviderError.sysctlSizeQueryFailed(errno: errno)
        }
        guard length > 0 else {
            throw NetworkProviderError.noInterfacesFound
        }

        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else {
            throw NetworkProviderError.sysctlReadFailed(errno: errno)
        }

        var interfaces: [RawInterface] = []
        buffer.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let headerPointer = (base + offset).assumingMemoryBound(to: if_msghdr.self)
                let messageLength = Int(headerPointer.pointee.ifm_msglen)
                guard messageLength > 0, offset + messageLength <= length else { break }

                if headerPointer.pointee.ifm_type == UInt8(RTM_IFINFO2),
                   messageLength >= MemoryLayout<if_msghdr2>.size,
                   let interface = Self.readInterface(recordStart: base + offset) {
                    interfaces.append(interface)
                }

                offset += messageLength
            }
        }

        guard !interfaces.isEmpty else {
            throw NetworkProviderError.noInterfacesFound
        }
        return interfaces
    }

    /// Decodes one `if_msghdr2` record starting at `recordStart` into a
    /// `RawInterface`. `nil` only if the interface index it names can no
    /// longer be resolved to a name via `if_indextoname` (e.g. the
    /// interface detached between the `sysctl` call and this read) — a
    /// benign race, not a domain failure, so the caller simply skips it.
    private static func readInterface(recordStart: UnsafeRawPointer) -> RawInterface? {
        let messagePointer = recordStart.assumingMemoryBound(to: if_msghdr2.self)
        let message = messagePointer.pointee

        var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil else {
            return nil
        }

        let flags = message.ifm_flags
        let data = message.ifm_data

        return RawInterface(
            name: String(cString: nameBuffer),
            isLoopback: (flags & IFF_LOOPBACK) != 0,
            isUp: (flags & IFF_UP) != 0,
            bytesSent: data.ifi_obytes,
            bytesReceived: data.ifi_ibytes,
            packetsSent: data.ifi_opackets,
            packetsReceived: data.ifi_ipackets
        )
    }

    // MARK: - Delta helper

    /// `current - previous`, or `nil` if `current < previous` — e.g. an
    /// interface whose counters reset (a detach/reattach cycle). An honest
    /// "no rate this tick" beats a huge fabricated one from an unsigned
    /// underflow, matching `DiskProvider`'s `nonNegativeDelta`.
    private static func nonNegativeDelta(_ current: UInt64, _ previous: UInt64) -> UInt64? {
        current >= previous ? current - previous : nil
    }
}
