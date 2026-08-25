import Darwin
import Foundation

/// Transport of one socket — PLAN.md §1.1 Connections table's "protocol
/// TCP/UDP + IPv4/6" column, plus the Unix-domain case `proc_pidfdinfo`
/// reports for the exact same per-pid fd scan (this app's "Local IPC"
/// filter chip). `SocketIPVersion` carries the IPv4/IPv6 half separately
/// since it doesn't apply to `.unixDomain` at all.
enum SocketTransport: String, Sendable, Equatable {
    case tcp = "TCP"
    case udp = "UDP"
    case unixDomain = "Unix"

    /// Maps `lsof -F P`'s protocol field — see `ConnectionsProvider
    /// .lsofFallback`'s own doc comment for when that path runs at all.
    /// `lsof -i` never reports a Unix-domain socket (that needs `-U`,
    /// which this fallback doesn't ask for — see this provider's own doc
    /// comment on why), so there's no third case to map here.
    fileprivate init?(lsofProtocol: String) {
        switch lsofProtocol.uppercased() {
        case "TCP": self = .tcp
        case "UDP": self = .udp
        default: return nil
        }
    }
}

enum SocketIPVersion: Int, Sendable, Equatable {
    case v4 = 4
    case v6 = 6
}

/// TCP connection state — PLAN.md §1.1's socket table "state" column. Its
/// own enum (rather than a raw kernel int or free-form string) so
/// `ConnectionsPage`'s "Connected"/"Listening" filter chips can match
/// against it directly. UDP and Unix-domain sockets have no TCP state
/// machine, so `ConnectionSocket.tcpState` is `nil` for them —
/// `ConnectionSocket.statusText` gives those transports their own,
/// non-TCP status wording instead.
enum TCPState: Sendable, Equatable {
    case closed
    case listen
    case synSent
    case synReceived
    case established
    case closeWait
    case finWait1
    case closing
    case lastAck
    case finWait2
    case timeWait
    /// A `tcpsi_state`/`lsof` state outside the eleven documented BSD TCP
    /// states — kept as its own case rather than silently dropped.
    case other

    /// `socket_fdinfo`'s `tcp_sockinfo.tcpsi_state` — the native
    /// `proc_pidfdinfo` path's own state encoding (`<sys/proc_info.h>`'s
    /// `TSI_S_*` constants).
    fileprivate init(bsdState: Int32) {
        switch bsdState {
        case Int32(TSI_S_CLOSED): self = .closed
        case Int32(TSI_S_LISTEN): self = .listen
        case Int32(TSI_S_SYN_SENT): self = .synSent
        case Int32(TSI_S_SYN_RECEIVED): self = .synReceived
        case Int32(TSI_S_ESTABLISHED): self = .established
        case Int32(TSI_S__CLOSE_WAIT): self = .closeWait
        case Int32(TSI_S_FIN_WAIT_1): self = .finWait1
        case Int32(TSI_S_CLOSING): self = .closing
        case Int32(TSI_S_LAST_ACK): self = .lastAck
        case Int32(TSI_S_FIN_WAIT_2): self = .finWait2
        case Int32(TSI_S_TIME_WAIT): self = .timeWait
        default: self = .other
        }
    }

    /// `lsof -F T`'s `ST=` sub-field. lsof prints the same eleven BSD
    /// states as the native path above, but spells two of them
    /// differently from `<sys/proc_info.h>`'s own macro names
    /// (`SYN_RCVD` rather than `SYN_RECEIVED`, no `_CLOSE_WAIT` leading
    /// underscore) — confirmed against the `/usr/sbin/lsof` binary's own
    /// embedded state-name strings rather than assumed.
    fileprivate init?(lsofStateName: String) {
        switch lsofStateName {
        case "CLOSED": self = .closed
        case "LISTEN": self = .listen
        case "SYN_SENT": self = .synSent
        case "SYN_RCVD": self = .synReceived
        case "ESTABLISHED": self = .established
        case "CLOSE_WAIT": self = .closeWait
        case "FIN_WAIT_1": self = .finWait1
        case "CLOSING": self = .closing
        case "LAST_ACK": self = .lastAck
        case "FIN_WAIT_2": self = .finWait2
        case "TIME_WAIT": self = .timeWait
        default: return nil
        }
    }

    /// Table/detail-panel display text — PLAN.md's "state" column.
    var displayName: String {
        switch self {
        case .closed: return "Closed"
        case .listen: return "Listen"
        case .synSent: return "SYN Sent"
        case .synReceived: return "SYN Received"
        case .established: return "Established"
        case .closeWait: return "Close Wait"
        case .finWait1: return "Fin Wait 1"
        case .closing: return "Closing"
        case .lastAck: return "Last ACK"
        case .finWait2: return "Fin Wait 2"
        case .timeWait: return "Time Wait"
        case .other: return "Other"
        }
    }
}

/// Where a socket's traffic can reach or come from — PLAN.md §1.1's
/// Connections detail-panel "exposure 'Internet'" reading, generalized to
/// the three buckets that same section names ("loopback/LAN/Internet").
///
/// Classified off the *remote* address when the socket has one (an
/// established/connected socket's exposure is about where its actual
/// traffic goes), else off the *local* bind address (a listening/bound
/// socket's exposure is about who can reach it) — see
/// `ConnectionsProvider.classifyExposure(address:ipVersion:)`. A wildcard
/// bind (`0.0.0.0`/`::`) classifies as `.internet`: the honest worst case,
/// since it accepts connections on every interface including a public one,
/// not just the ones this app happens to know about.
enum SocketExposure: String, Sendable, Equatable, CaseIterable {
    case loopback
    case lan
    case internet

    var label: String {
        switch self {
        case .loopback: return "Loopback"
        case .lan: return "LAN"
        case .internet: return "Internet"
        }
    }
}

/// One open socket, from either the native `proc_pidfdinfo` scan or the
/// `lsof` fallback — PLAN.md §1.1's Connections table row ("app, protocol
/// TCP/UDP + IPv4/6, state, local/remote endpoint, service") and its
/// right detail panel ("endpoints, exposure 'Internet', socket
/// descriptor, observed time").
struct ConnectionSocket: Sendable, Identifiable, Equatable {
    /// A process's own fd numbers are unique to that process but not
    /// across processes (and the `lsof` fallback synthesizes a small
    /// negative-space `descriptor` — see `ConnectionsProvider
    /// .makeLsofSocket`'s doc comment — that could collide with a real fd
    /// number from a *different* pid), so the id folds in `pid` too,
    /// matching `ServiceItem.id`'s own "fold in the scope, don't assume
    /// global uniqueness" pattern.
    var id: String { "\(pid).\(descriptor)" }

    let pid: pid_t
    /// Executable short name, e.g. "Safari" or "mDNSResponder" — `nil`
    /// only when this pid's name couldn't be resolved at all (exited
    /// between the process list and the per-pid read, or a resolution
    /// failure on the `lsof` fallback path).
    let processName: String?
    let descriptor: Int32
    let transport: SocketTransport
    /// `nil` only for `.unixDomain` (no IP version) or when the `lsof`
    /// fallback's address text couldn't be classified.
    let ipVersion: SocketIPVersion?
    let tcpState: TCPState?
    let localAddress: String?
    let localPort: UInt16?
    let remoteAddress: String?
    let remotePort: UInt16?
    /// The bound path for a `.unixDomain` socket, e.g.
    /// "/var/run/mDNSResponder" — `nil` for every other transport, and
    /// for a Unix-domain socket whose kernel-reported path is empty (an
    /// unnamed/anonymous pair, e.g. one half of a `socketpair()`).
    let unixPath: String?
    let exposure: SocketExposure?
    /// `getservbyport`-resolved short service name for the local port,
    /// e.g. "https" for 443 — PLAN.md's "service" column. `nil` when the
    /// port has no `/etc/services` entry, or for `.unixDomain` (no port
    /// to look up).
    let serviceName: String?
    let observedAt: Date

    var localEndpoint: String { Self.endpointText(address: localAddress, port: localPort) }
    var remoteEndpoint: String { Self.endpointText(address: remoteAddress, port: remotePort) }

    private static func endpointText(address: String?, port: UInt16?) -> String {
        guard let address else { return "\u{2014}" }
        guard let port else { return address }
        return "\(address):\(port)"
    }

    /// The "Listening" filter chip's predicate — a TCP socket in the
    /// `LISTEN` state, or a UDP socket that's bound but has no connected
    /// peer (UDP has no `LISTEN` state of its own, but a peer-less bound
    /// socket plays the same "waiting to be talked to" role). Unix-domain
    /// sockets never count: `proc_pidfdinfo`/`lsof` report an accepted
    /// *connection* fd, not the separate listening fd a Unix-domain
    /// server keeps bound, so this app has nothing honest to call
    /// "listening" for that transport.
    var isListening: Bool {
        switch transport {
        case .tcp: return tcpState == .listen
        case .udp: return remotePort == nil
        case .unixDomain: return false
        }
    }

    /// The "Connected" filter chip's predicate.
    var isConnected: Bool {
        switch transport {
        case .tcp: return tcpState == .established
        case .udp: return remotePort != nil
        case .unixDomain: return true
        }
    }

    /// Table "State" column / detail-panel status line, generalized across
    /// every transport this table can show (only TCP has a true state
    /// machine — see `isListening`'s own doc comment for why UDP/Unix get
    /// their own wording rather than a borrowed TCP state name).
    var statusText: String {
        switch transport {
        case .tcp: return tcpState?.displayName ?? "Unavailable"
        case .udp: return remotePort == nil ? "Bound" : "Connected"
        case .unixDomain: return "Local IPC"
        }
    }
}

/// One `sample()`'s worth of socket data — mirrors `ServicesCatalog`'s
/// "cached, page-driven reload" shape (see `ConnectionsProvider`'s own doc
/// comment for why this domain isn't wired into `Sampler`'s per-tick
/// loop).
struct ConnectionsCatalog: Sendable, Equatable {
    let sockets: [ConnectionSocket]
    let generatedAt: Date
    /// `true` when this catalog came from the `lsof` fallback rather than
    /// the native `proc_pidfdinfo` scan — see `ConnectionsProvider
    /// .scanSynchronously`'s doc comment for exactly when that happens.
    /// Surfaced so `ConnectionsPage`'s status line can say so, matching
    /// PLAN.md's "honest degradation" spirit: this app never hides *how*
    /// a reading was obtained, only ever what it honestly could and
    /// couldn't read.
    let usedFallback: Bool
    /// How many pids `proc_listallpids` reported this scan — set even
    /// when `usedFallback` is `true` (`proc_listallpids` still ran; only
    /// the per-socket read failed system-wide). Feeds the status line's
    /// "N processes with sockets, of M running" framing.
    let scannedProcessCount: Int
}

/// Failure modes for `ConnectionsProvider.sample()` — see `Provider`'s doc
/// comment for when a provider throws versus degrading a single reading.
enum ConnectionsProviderError: Error, LocalizedError {
    case listPidsFailed
    /// Neither the native `proc_pidfdinfo` scan nor the `lsof` fallback
    /// produced any usable socket data this tick.
    case noDataAvailable

    var errorDescription: String? {
        switch self {
        case .listPidsFailed:
            return "proc_listallpids failed"
        case .noDataAvailable:
            return "Neither proc_pidfdinfo nor lsof produced any socket data"
        }
    }
}

/// Lists every process's open sockets — PLAN.md §3 `Providers/
/// ConnectionsProvider.swift "per-pid sockets via proc_pidfdinfo; lsof
/// fallback"` and §4 M6's second task: "Connections: stat tiles, filter
/// chips, per-process socket table (proc_pidfdinfo, lsof fallback),
/// exposure classification (loopback/LAN/Internet), detail panel."
///
/// **Two data sources, same shape.** The primary path walks every pid's
/// fd table (`PROC_PIDLISTFDS`) and reads each socket fd's kernel state
/// directly (`PROC_PIDFDSOCKETINFO`) — no shell-out, no text parsing,
/// the same syscall-first approach every other provider in this app takes.
/// `proc_pidfdinfo` only succeeds for this app's own uid (and root's),
/// exactly the same cross-user permission restriction
/// `ProcessProvider.readTaskInfo`'s doc comment already documents for task
/// info — a pid owned by another user is silently skipped, an honest gap
/// rather than a failure, matching every other per-pid read in this app.
/// If that native scan produces *zero* sockets system-wide (implausible
/// under normal conditions — even a freshly-booted Mac has
/// `mDNSResponder`/`launchd` listeners — but a real possibility if a
/// future macOS release tightens `proc_pidfdinfo` further), this
/// provider falls back to shelling out to `/usr/sbin/lsof -F` and parsing
/// its field-mode output instead: PLAN.md's own named fallback. The
/// fallback is coarser (no real fd number — `makeLsofSocket` synthesizes
/// one — and no Unix-domain sockets, since that needs a separate `-U`
/// flag this app doesn't ask for) but still gives every column this
/// page's table needs. `sample()` only throws when *both* paths come back
/// empty.
///
/// An `actor`, matching `ServicesProvider`/`StartupProvider`'s reasoning:
/// this isn't sampled from inside `Sampler`'s tick — walking every
/// process's fd table is far more I/O than any 2×/sec domain provider —
/// but polled directly by `ConnectionsPage`'s own view model, off the main
/// thread, on its own slower cadence.
actor ConnectionsProvider: Provider {
    static let providerID = "connections"

    /// Not read anywhere yet — kept for the same forward-looking reason
    /// `ServicesProvider.cachedCatalog` is: a future M9 `AlertsEngine`
    /// rule ("new public listening port," per PLAN.md §4 M9) will want to
    /// diff this tick's catalog against the previous one, and that diff
    /// belongs here rather than duplicated into every caller.
    private(set) var cachedCatalog: ConnectionsCatalog?

    func sample() async throws -> ConnectionsCatalog {
        let catalog = try await Self.scan()
        cachedCatalog = catalog
        return catalog
    }

    // MARK: - Scan

    /// Hops to a background queue for the same reason `ServicesProvider
    /// .scan()`/`StartupProvider.scan()` do: none of `proc_pidinfo`,
    /// `proc_pidfdinfo`, or a shelled-out `lsof` have an async variant,
    /// and running potentially hundreds of them directly on this actor's
    /// executor would tie up a cooperative-pool thread for however long
    /// the whole scan takes.
    private static func scan() async throws -> ConnectionsCatalog {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try scanSynchronously())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Must only ever run on the background queue `scan()` dispatches
    /// onto. Deliberately re-resolves every pid's process name on every
    /// call rather than caching pid → name across ticks the way
    /// `ProcessProvider.userNameCache`/`iconCache` do for their own keys:
    /// a pid is recycled by the kernel far sooner than a uid or an app's
    /// bundle path is ever reused, so a pid-keyed cache would risk
    /// showing a socket under its *previous* occupant's name — one extra
    /// `proc_pidpath`/`proc_name` call per socket-holding pid per tick is
    /// cheap enough to not need that risk.
    private static func scanSynchronously() throws -> ConnectionsCatalog {
        let pids = try listAllPids()
        let now = Date()

        var sockets: [ConnectionSocket] = []
        for pid in pids {
            guard let fds = listSocketFDs(pid: pid), !fds.isEmpty else { continue }
            let name = processName(pid: pid)
            for fd in fds {
                guard let socket = readSocket(pid: pid, fd: fd, processName: name, observedAt: now) else { continue }
                sockets.append(socket)
            }
        }

        if !sockets.isEmpty {
            return ConnectionsCatalog(sockets: sockets, generatedAt: now, usedFallback: false, scannedProcessCount: pids.count)
        }

        if let fallback = try? lsofFallback(observedAt: now), !fallback.isEmpty {
            return ConnectionsCatalog(sockets: fallback, generatedAt: now, usedFallback: true, scannedProcessCount: pids.count)
        }

        throw ConnectionsProviderError.noDataAvailable
    }

    // MARK: - libproc: pid list

    /// Identical technique to `ProcessProvider.listAllPids()`/
    /// `TopProcessesProvider.listAllPids()` — see either's doc comment for
    /// why the buffer is padded past the first estimate.
    private static func listAllPids() throws -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { throw ConnectionsProviderError.listPidsFailed }

        let capacity = Int(estimate) + 256
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytesFilled = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard bytesFilled > 0 else { throw ConnectionsProviderError.listPidsFailed }

        let filledCount = min(Int(bytesFilled) / MemoryLayout<pid_t>.size, pids.count)
        return Array(pids[0..<filledCount])
    }

    /// `nil` when this pid's fd table couldn't be read at all (exited
    /// since `listAllPids()`, or — far more often — owned by another user;
    /// see this type's own doc comment). An empty (non-`nil`) array is the
    /// honest, different outcome: the pid answered but has no fds at all.
    private static func listSocketFDs(pid: pid_t) -> [Int32]? {
        let neededSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard neededSize > 0 else { return nil }

        let count = Int(neededSize) / MemoryLayout<proc_fdinfo>.size
        guard count > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let filledSize = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard filledSize > 0 else { return nil }

        let filledCount = min(Int(filledSize) / MemoryLayout<proc_fdinfo>.size, fds.count)
        return fds[0..<filledCount]
            .filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }
            .map(\.proc_fd)
    }

    /// Reads one fd's kernel socket state and classifies it into a
    /// `ConnectionSocket` — `nil` when `proc_pidfdinfo` itself failed (the
    /// fd closed between `listSocketFDs` and this call), or the socket is
    /// a kind this table has no column for (raw/non-UDP `SOCKINFO_IN`,
    /// `SOCKINFO_NDRV`, ...) rather than TCP, UDP, or Unix-domain.
    private static func readSocket(pid: pid_t, fd: Int32, processName: String?, observedAt: Date) -> ConnectionSocket? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        let result = proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size)
        guard result == size else { return nil }

        let soi = info.psi
        // `soi_kind`'s field type is plain `int` (`Int32`), but the
        // `SOCKINFO_*` constants come from an anonymous, untyped C `enum`
        // — Swift's Clang importer gives those plain `Int` (not `Int32`),
        // so the switch subject is widened to match rather than the
        // (narrower, lossy in the other direction) reverse.
        switch Int(soi.soi_kind) {
        case SOCKINFO_TCP:
            let tcp = soi.soi_proto.pri_tcp
            return makeIPSocket(
                pid: pid,
                fd: fd,
                processName: processName,
                transport: .tcp,
                ini: tcp.tcpsi_ini,
                tcpState: TCPState(bsdState: tcp.tcpsi_state),
                observedAt: observedAt
            )
        case SOCKINFO_IN:
            // A generic IP socket `proc_pidfdinfo` didn't classify as
            // `SOCKINFO_TCP` — this table only has a place for it when
            // it's actually UDP (PLAN.md's own "UDP" filter chip); a raw
            // socket (ICMP, ...) has neither a protocol label nor a state
            // this table's columns could honestly show, so it's skipped
            // rather than shown with blanks.
            guard soi.soi_protocol == IPPROTO_UDP else { return nil }
            return makeIPSocket(
                pid: pid,
                fd: fd,
                processName: processName,
                transport: .udp,
                ini: soi.soi_proto.pri_in,
                tcpState: nil,
                observedAt: observedAt
            )
        case SOCKINFO_UN:
            return makeUnixSocket(pid: pid, fd: fd, processName: processName, info: soi.soi_proto.pri_un, observedAt: observedAt)
        default:
            return nil
        }
    }

    private static func makeIPSocket(
        pid: pid_t,
        fd: Int32,
        processName: String?,
        transport: SocketTransport,
        ini: in_sockinfo,
        tcpState: TCPState?,
        observedAt: Date
    ) -> ConnectionSocket {
        let ipVersion: SocketIPVersion?
        if ini.insi_vflag & UInt8(INI_IPV6) != 0 {
            ipVersion = .v6
        } else if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
            ipVersion = .v4
        } else {
            ipVersion = nil
        }

        let localAddress = ipAddressText(local: true, ini: ini)
        let localPort = portNumber(fromNetworkOrder: ini.insi_lport)
        let remotePort = portNumber(fromNetworkOrder: ini.insi_fport)
        // A listening/unconnected socket's `insi_fport` reads back as 0
        // (no peer), which `portNumber` already folds to `nil` — treat
        // that as "no remote endpoint" rather than showing a meaningless
        // "0.0.0.0:0" (or the "hasRemote" address read would itself be
        // uninitialized foreign-address garbage on some kernel versions).
        let remoteAddress = remotePort != nil ? ipAddressText(local: false, ini: ini) : nil

        let exposure = classifyExposure(address: remoteAddress ?? localAddress, ipVersion: ipVersion)

        return ConnectionSocket(
            pid: pid,
            processName: processName,
            descriptor: fd,
            transport: transport,
            ipVersion: ipVersion,
            tcpState: tcpState,
            localAddress: localAddress,
            localPort: localPort,
            remoteAddress: remoteAddress,
            remotePort: remotePort,
            unixPath: nil,
            exposure: exposure,
            serviceName: localPort.flatMap { serviceName(port: $0, transport: transport) },
            observedAt: observedAt
        )
    }

    private static func makeUnixSocket(pid: pid_t, fd: Int32, processName: String?, info: un_sockinfo, observedAt: Date) -> ConnectionSocket {
        let path = unixPathText(from: info.unsi_addr.ua_sun) ?? unixPathText(from: info.unsi_caddr.ua_sun)
        return ConnectionSocket(
            pid: pid,
            processName: processName,
            descriptor: fd,
            transport: .unixDomain,
            ipVersion: nil,
            tcpState: nil,
            localAddress: nil,
            localPort: nil,
            remoteAddress: nil,
            remotePort: nil,
            unixPath: path,
            // Unix-domain sockets are same-machine IPC by construction —
            // the kernel has no path for their bytes to leave this Mac —
            // so `.loopback` here is a fact, not a default guess, and the
            // only honest bucket of PLAN.md's three-way split for this
            // transport.
            exposure: .loopback,
            serviceName: nil,
            observedAt: observedAt
        )
    }

    /// Converts a `socket_fdinfo` address field's network-byte-order 16-bit
    /// port (widened into a signed `int` by the kernel struct, per
    /// `<sys/proc_info.h>`) to a host-order `UInt16`, folding `0`
    /// ("no port"/"no peer") to `nil` — the same `ntohs`-plus-honest-empty
    /// treatment `serviceName`'s own lookup and `makeIPSocket`'s remote-
    /// endpoint logic both rely on.
    private static func portNumber(fromNetworkOrder raw: Int32) -> UInt16? {
        let value = UInt16(bigEndian: UInt16(truncatingIfNeeded: raw))
        return value == 0 ? nil : value
    }

    /// `inet_ntop`s one side (`local`) of an `in_sockinfo`'s address pair,
    /// reading the IPv4 or IPv6 union member per `insi_vflag` — the two
    /// members are read out individually (`.ina_46.i46a_addr4` /
    /// `.ina_6`) rather than through one shared helper taking the whole
    /// union, since the union's Clang-imported Swift type has no name of
    /// its own to write down as a parameter type.
    private static func ipAddressText(local: Bool, ini: in_sockinfo) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if ini.insi_vflag & UInt8(INI_IPV6) != 0 {
            var addr6 = local ? ini.insi_laddr.ina_6 : ini.insi_faddr.ina_6
            guard inet_ntop(AF_INET6, &addr6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return String(cString: buffer)
        }
        if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
            var addr4 = local ? ini.insi_laddr.ina_46.i46a_addr4 : ini.insi_faddr.ina_46.i46a_addr4
            guard inet_ntop(AF_INET, &addr4, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return String(cString: buffer)
        }
        return nil
    }

    /// Reads a `sockaddr_un.sun_path` fixed C-string field out as a
    /// `String`, `nil` for an empty path (an unnamed/anonymous Unix-domain
    /// socket, e.g. one half of a `socketpair()`, has no path to report —
    /// an honest gap, not a read failure).
    private static func unixPathText(from sun: sockaddr_un) -> String? {
        var mutableSun = sun
        let path = withUnsafeBytes(of: &mutableSun.sun_path) { raw -> String in
            let pointer = raw.bindMemory(to: CChar.self).baseAddress!
            return String(cString: pointer)
        }
        return path.isEmpty ? nil : path
    }

    /// `getservbyport`-backed service-name lookup for the table's
    /// "Service" column — `nil` for port `0` or a port with no
    /// `/etc/services` entry (an honest "nothing to show," not a guess).
    private static func serviceName(port: UInt16, transport: SocketTransport) -> String? {
        let protocolName: String
        switch transport {
        case .tcp: protocolName = "tcp"
        case .udp: protocolName = "udp"
        case .unixDomain: return nil
        }
        // `getservbyport` takes the port in network byte order — the
        // exact reverse of `portNumber(fromNetworkOrder:)`'s conversion
        // above, applied here to get back to the form the lookup expects.
        guard let entry = getservbyport(Int32(port.bigEndian), protocolName) else { return nil }
        guard let namePointer = entry.pointee.s_name else { return nil }
        return String(cString: namePointer)
    }

    // MARK: - Exposure classification

    /// PLAN.md's "exposure classification (loopback/LAN/Internet)" —
    /// shared by both the native and `lsof` paths. `nil` only when there's
    /// no address to classify at all (an `ipVersion`-less reading, or the
    /// `lsof` fallback's text couldn't be parsed as an endpoint).
    private static func classifyExposure(address: String?, ipVersion: SocketIPVersion?) -> SocketExposure? {
        guard let address, let ipVersion else { return nil }
        switch ipVersion {
        case .v4: return classifyIPv4Exposure(address)
        case .v6: return classifyIPv6Exposure(address)
        }
    }

    /// RFC 1918 private ranges plus RFC 3927 link-local as `.lan`,
    /// `127.0.0.0/8` as `.loopback`, the `0.0.0.0` wildcard bind (see
    /// `SocketExposure`'s own doc comment) and everything else as
    /// `.internet`. A dotted-quad that fails to parse as four octets
    /// (shouldn't happen from a real `inet_ntop`/`lsof` reading, but this
    /// function has no way to *know* that) also falls through to
    /// `.internet` — the most cautious bucket, rather than silently
    /// mis-filing an address this function couldn't actually read as
    /// `.loopback`/`.lan`.
    private static func classifyIPv4Exposure(_ address: String) -> SocketExposure {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return .internet }
        if octets[0] == 127 { return .loopback }
        if octets[0] == 10 { return .lan }
        if octets[0] == 172, (16...31).contains(octets[1]) { return .lan }
        if octets[0] == 192, octets[1] == 168 { return .lan }
        if octets[0] == 169, octets[1] == 254 { return .lan }
        return .internet
    }

    /// `::1` as `.loopback`; `fe80::/10` link-local and `fc00::/7` unique
    /// local as `.lan`; the `::` wildcard bind and everything else
    /// (including a real routable global-unicast address) as `.internet`.
    /// Matched by string prefix rather than parsing the address into
    /// bytes: `inet_ntop`'s zero-compressed IPv6 text (and macOS's own
    /// `fe80:<ifindex>::...` embedded-scope-id form observed from `lsof`
    /// on this Mac) both still start with the same prefix regardless of
    /// exactly how the rest of the address is abbreviated.
    private static func classifyIPv6Exposure(_ address: String) -> SocketExposure {
        let lowercased = address.lowercased()
        if lowercased == "::1" { return .loopback }
        if lowercased.hasPrefix("fe80") { return .lan }
        if lowercased.hasPrefix("fc") || lowercased.hasPrefix("fd") { return .lan }
        return .internet
    }

    // MARK: - Process name

    private static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * 1024)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Same fallback order as `ProcessProvider.processName(pid:path:)`:
    /// the executable path's last component, else `proc_name`'s short
    /// name. Deliberately re-implemented here rather than shared — see
    /// `ServicesProvider`'s own doc comment on why this app accepts a
    /// little duplication between providers with genuinely different
    /// scopes rather than reaching into another domain's actor for a
    /// three-line helper.
    private static func processName(pid: pid_t) -> String? {
        if let path = executablePath(pid: pid) {
            let lastComponent = URL(fileURLWithPath: path).lastPathComponent
            if !lastComponent.isEmpty { return lastComponent }
        }
        var buffer = [CChar](repeating: 0, count: 64)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - `lsof` fallback

    /// Runs `lsof -nP -i -F pcnPT` and parses its field-mode output —
    /// see this type's own doc comment for exactly when `scanSynchronously`
    /// reaches for this. `-F` (rather than `lsof`'s default columnar text)
    /// is a stable, documented per-field output mode meant for exactly
    /// this kind of parsing, unlike the column-aligned human-readable
    /// format `lsof` prints without it. `-n` skips hostname resolution and
    /// `-P` skips `/etc/services` port-name resolution (this provider does
    /// its own with `serviceName(port:transport:)`, matching the native
    /// path) — both purely to keep this fallback fast, since a DNS PTR
    /// lookup per remote endpoint would be the kind of unbounded I/O
    /// PLAN.md §2 warns a monitor must never become. `-i` selects only
    /// Internet-domain (TCP/UDP) sockets; Unix-domain sockets need a
    /// separate `-U` flag this fallback doesn't pass, so a catalog built
    /// from this path never has a `.unixDomain` row (an honest gap: the
    /// scenario that reaches this fallback at all is native `proc_pidfdinfo`
    /// access having failed system-wide, so it's not this app's place to
    /// then claim precise fd-level Unix-socket data from a coarser
    /// text-parsing source).
    private static func lsofFallback(observedAt: Date) throws -> [ConnectionSocket] {
        guard let output = runLsof(["-nP", "-i", "-F", "pcnPT"]) else {
            throw ConnectionsProviderError.noDataAvailable
        }
        return parseLsofOutput(output, observedAt: observedAt)
    }

    /// `nil` only when `lsof` itself couldn't be launched. `lsof` exits
    /// non-zero (1) whenever its selection matched nothing at all, which
    /// is a legitimately empty (not failed) result here, so — unlike
    /// `ServicesProvider.runLaunchctl`'s own subprocess helper — this one
    /// doesn't gate on `terminationStatus`, only on the process starting.
    private static func runLsof(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = arguments
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return nil }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Parses `lsof -F pcnPT`'s output: one un-prefixed-by-anything-else
    /// line per field, each starting with a single identifying letter
    /// (`p` pid, `c` command, `f` fd, `P` protocol, `n` name/address,
    /// `T` a `KEY=value` sub-field — here only `ST=<state>` is read, the
    /// others (`QR`/`QS` queue lengths) aren't columns this table has).
    /// `p`/`c` lines persist across every `f`-group that follows within
    /// the same process block; each `f` line starts a fresh socket record
    /// that's finalized the moment the next `f` or `p` line begins (or at
    /// the end of output).
    private static func parseLsofOutput(_ output: String, observedAt: Date) -> [ConnectionSocket] {
        var sockets: [ConnectionSocket] = []

        var currentPID: pid_t?
        var currentCommand: String?
        // Synthesizes a stable-within-this-scan fd-like descriptor for
        // the fallback path, which has no real fd number to report (see
        // `ConnectionSocket.descriptor`'s own doc comment) — a running
        // per-process counter of `f`-groups seen so far.
        var nextDescriptor: [pid_t: Int32] = [:]

        var pendingProtocol: String?
        var pendingName: String?
        var pendingState: String?
        var hasPendingRecord = false

        func flushPending() {
            defer {
                pendingProtocol = nil
                pendingName = nil
                pendingState = nil
                hasPendingRecord = false
            }
            guard
                hasPendingRecord,
                let pid = currentPID,
                let protocolText = pendingProtocol,
                let name = pendingName,
                let transport = SocketTransport(lsofProtocol: protocolText)
            else { return }
            let descriptor = nextDescriptor[pid, default: 0]
            nextDescriptor[pid] = descriptor + 1
            guard let socket = makeLsofSocket(
                pid: pid,
                descriptor: descriptor,
                processName: currentCommand,
                transport: transport,
                name: name,
                tcpStateName: pendingState,
                observedAt: observedAt
            ) else { return }
            sockets.append(socket)
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let marker = rawLine.first else { continue }
            let value = String(rawLine.dropFirst())
            switch marker {
            case "p":
                flushPending()
                currentPID = pid_t(value)
                currentCommand = nil
            case "c":
                currentCommand = value
            case "f":
                flushPending()
                hasPendingRecord = true
            case "P":
                pendingProtocol = value
            case "n":
                pendingName = value
            case "T":
                if value.hasPrefix("ST=") {
                    pendingState = String(value.dropFirst(3))
                }
            default:
                break
            }
        }
        flushPending()

        return sockets
    }

    private static func makeLsofSocket(
        pid: pid_t,
        descriptor: Int32,
        processName: String?,
        transport: SocketTransport,
        name: String,
        tcpStateName: String?,
        observedAt: Date
    ) -> ConnectionSocket? {
        let parts = name.components(separatedBy: "->")
        guard let local = parseEndpoint(parts[0]) else { return nil }
        let remote = parts.count > 1 ? parseEndpoint(parts[1]) : nil

        // A bracketed host (`[...]`) is unambiguously IPv6; an
        // unbracketed one defaults to IPv4 — including for a wildcard
        // (`*`) bind, since `lsof`'s combined `-i` selection doesn't
        // distinguish an IPv4-any from an IPv6-any wildcard listener in
        // its text output. That single ambiguous case only affects
        // `SocketExposure` classification (both wildcard forms already
        // classify as `.internet` either way) and this fallback only
        // ever runs when the native path is unavailable system-wide, so
        // it's an acceptable loss of fidelity rather than one worth a
        // second `lsof` invocation to disambiguate.
        let ipVersion: SocketIPVersion = local.host.contains(":") ? .v6 : .v4
        let tcpState = tcpStateName.flatMap { TCPState(lsofStateName: $0) }
        let exposure = classifyExposure(address: remote?.host ?? local.host, ipVersion: ipVersion)

        return ConnectionSocket(
            pid: pid,
            processName: processName,
            descriptor: descriptor,
            transport: transport,
            ipVersion: ipVersion,
            tcpState: tcpState,
            localAddress: local.host,
            localPort: local.port,
            remoteAddress: remote?.host,
            remotePort: remote?.port,
            unixPath: nil,
            exposure: exposure,
            serviceName: local.port.flatMap { serviceName(port: $0, transport: transport) },
            observedAt: observedAt
        )
    }

    /// Parses one `lsof -F n` endpoint token — `"*:22"`, `"192.168.1.5:51413"`,
    /// or a bracketed IPv6 form (`"[fe80::1]:53"`) — into a host/port pair.
    /// `nil` port when the text has none (shouldn't happen for a real
    /// socket, but parsed defensively rather than force-unwrapped).
    private static func parseEndpoint(_ raw: String) -> (host: String, port: UInt16?)? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        if text.hasPrefix("[") {
            guard let closeBracket = text.firstIndex(of: "]") else { return nil }
            let host = String(text[text.index(after: text.startIndex)..<closeBracket])
            let remainder = text[text.index(after: closeBracket)...]
            guard remainder.hasPrefix(":") else { return (host, nil) }
            return (host, UInt16(remainder.dropFirst()))
        }

        guard let lastColon = text.lastIndex(of: ":") else { return (text, nil) }
        let host = String(text[..<lastColon])
        let portText = text[text.index(after: lastColon)...]
        return (host, UInt16(portText))
    }
}
