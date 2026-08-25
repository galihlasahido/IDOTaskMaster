import Darwin
import Foundation

/// One open file descriptor belonging to a single process — a row in the
/// Processes page's "Open Files & Ports" tab (PLAN.md §4 M10's "Open Files
/// & Ports tab in process detail (lsof-style, like Activity Monitor's
/// Inspect window)").
struct OpenFileEntry: Sendable, Identifiable, Equatable {
    var id: Int32 { descriptor }

    /// The raw fd number — lsof's own "FD" column.
    let descriptor: Int32
    /// A short kind label — "File", "Directory", "TCP4", "UDP6", "Unix
    /// Socket", "Pipe", "Kqueue", "Shared Memory", "Semaphore", or "Other"
    /// for any fd type not covered above (`PROX_FDTYPE_ATALK`,
    /// `PROX_FDTYPE_NETPOLICY`, ...) — lsof's "TYPE" column, generalized
    /// to also carry the protocol/IP-version detail lsof folds into its
    /// own "NODE" field for sockets (matching `ConnectionsPage`'s own
    /// "TCP4"/"UDP6" convention).
    let kind: String
    /// lsof's "NAME" column: a file/directory's path, a Unix-domain
    /// socket's bound path, an IP socket's local endpoint (plus "→ remote
    /// (state)" when connected), or a pipe's kernel handle. `nil` only
    /// when this fd's own per-descriptor read failed (closed between the
    /// fd listing and this call) or the fd kind has nothing more to say
    /// (an anonymous kqueue, an fd type this provider doesn't decode) —
    /// PLAN.md's honest "Unavailable" rather than a guess; `kind` is still
    /// populated from the fd-list scan either way.
    let name: String?
}

/// One `openFiles(forPID:)` call's worth of data for a single process.
struct OpenFilesCatalog: Sendable, Equatable {
    let pid: pid_t
    /// Ascending by `descriptor`, matching `lsof`'s own row order.
    let entries: [OpenFileEntry]
    let generatedAt: Date
}

/// Failure mode for `OpenFilesProvider.openFiles(forPID:)` — see
/// `OpenFilesProvider.listFDs(pid:)`'s own doc comment for exactly when
/// this throws versus returning a (possibly empty) entry list.
enum OpenFilesProviderError: Error, LocalizedError {
    case processUnavailable

    var errorDescription: String? {
        "This process's open files couldn't be read \u{2014} it may have exited, or its file descriptors may belong to another user."
    }
}

/// Lists one process's open file descriptors — files, directories, sockets
/// (TCP/UDP/Unix-domain), pipes, kqueues, POSIX shared-memory regions, and
/// POSIX semaphores — the same territory `/usr/sbin/lsof -p <pid>` covers,
/// read directly via `proc_pidinfo`/`proc_pidfdinfo` rather than shelling
/// out (the same syscall-first approach every other provider in this app
/// takes; `ConnectionsProvider`'s own `lsof` fallback is reserved for when
/// that native path is unavailable *system-wide*, which this narrower
/// single-pid reader doesn't attempt to mirror — a permission failure here
/// simply throws `OpenFilesProviderError.processUnavailable`, an honest gap
/// for the one process the user is currently inspecting).
///
/// Not a `Provider` conformer — `Provider.sample()` takes no arguments, but
/// this type's whole shape is "give me one pid's fd table," matching
/// `DiskSpaceScanner`'s own precedent (see that type's doc comment) for a
/// domain that needs more than `sample()`'s one shape.
///
/// An `actor`, matching `ConnectionsProvider`/`DiskSpaceScanner`'s own
/// reasoning: not sampled from inside `Sampler`'s tick, but polled directly
/// by `ProcessesPage`'s own view model on its own cadence, only while the
/// Open Files & Ports tab is the one showing for the current selection —
/// walking one process's fd table on every tick of `Sampler`'s 2×/sec loop
/// for every process, whether its detail pane is open or not, would be the
/// kind of unnecessary idle overhead PLAN.md §2 rules out.
actor OpenFilesProvider {
    /// Not read anywhere yet — kept for the same forward-looking reason
    /// `DiskSpaceScanner.providerID` is (see that type's own doc comment):
    /// a stable per-domain key ready for `PageInfoBar`/`AlertsEngine`
    /// without every load-once/on-demand provider inventing its own naming
    /// scheme.
    static let providerID = "openFiles"

    /// One snapshot of `pid`'s open file descriptors, sorted by descriptor
    /// number.
    func openFiles(forPID pid: pid_t) async throws -> OpenFilesCatalog {
        try await Self.scan(pid: pid)
    }

    // MARK: - Scan

    /// Hops to a background queue for the same reason `ConnectionsProvider
    /// .scan()`/`DiskSpaceScanner.performScan`'s doc comments give: none of
    /// `proc_pidinfo`/`proc_pidfdinfo` have an async variant, and this
    /// actor's own executor shouldn't block on however many fds `pid` has
    /// open.
    private static func scan(pid: pid_t) async throws -> OpenFilesCatalog {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try scanSynchronously(pid: pid))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Must only ever run on the background queue `scan(pid:)` dispatches
    /// onto.
    private static func scanSynchronously(pid: pid_t) throws -> OpenFilesCatalog {
        guard let fds = listFDs(pid: pid) else {
            throw OpenFilesProviderError.processUnavailable
        }
        let now = Date()
        let entries = fds
            .map { readEntry(pid: pid, fd: $0) }
            .sorted { $0.descriptor < $1.descriptor }
        return OpenFilesCatalog(pid: pid, entries: entries, generatedAt: now)
    }

    // MARK: - libproc: fd list

    /// `nil` when `pid`'s fd table couldn't be read at all (exited since
    /// the caller looked it up, or — far more often, per every other
    /// per-pid reader in this app's own doc comments — owned by another
    /// user). An empty (non-`nil`) array is the honest, different outcome:
    /// the pid answered but currently has no open descriptors. Identical
    /// technique to `ConnectionsProvider.listSocketFDs(pid:)`, just kept
    /// every fd rather than filtering down to sockets — see this type's
    /// own doc comment for why that logic isn't shared across the two
    /// files.
    private static func listFDs(pid: pid_t) -> [proc_fdinfo]? {
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
        return Array(fds[0..<filledCount])
    }

    // MARK: - Per-fd classification

    /// Dispatches on `proc_fdtype` (`<sys/proc_info.h>`'s `PROX_FDTYPE_*`
    /// constants) to the right `proc_pidfdinfo` flavor. Always returns an
    /// entry — `kind` is already known from the fd-list scan even when the
    /// per-descriptor detail read below fails, so only `name` degrades to
    /// `nil` on a read failure (see `OpenFileEntry.name`'s own doc
    /// comment).
    private static func readEntry(pid: pid_t, fd: proc_fdinfo) -> OpenFileEntry {
        switch fd.proc_fdtype {
        case UInt32(PROX_FDTYPE_VNODE):
            return readVnode(pid: pid, descriptor: fd.proc_fd)
        case UInt32(PROX_FDTYPE_SOCKET):
            return readSocket(pid: pid, descriptor: fd.proc_fd)
        case UInt32(PROX_FDTYPE_PIPE):
            return readPipe(pid: pid, descriptor: fd.proc_fd)
        case UInt32(PROX_FDTYPE_KQUEUE):
            return OpenFileEntry(descriptor: fd.proc_fd, kind: "Kqueue", name: nil)
        case UInt32(PROX_FDTYPE_PSHM):
            return readSharedMemory(pid: pid, descriptor: fd.proc_fd)
        case UInt32(PROX_FDTYPE_PSEM):
            return readSemaphore(pid: pid, descriptor: fd.proc_fd)
        default:
            // `PROX_FDTYPE_ATALK` (long-obsolete AppleTalk), `_FSEVENTS`,
            // `_NETPOLICY`, `_CHANNEL`, `_NEXUS` — kinds this table has no
            // richer decoding for; shown honestly as "Other" rather than
            // guessed at.
            return OpenFileEntry(descriptor: fd.proc_fd, kind: "Other", name: nil)
        }
    }

    /// `PROC_PIDFDVNODEPATHINFO` — a file, directory, symlink, or device
    /// node's path plus its `vnode_info.vi_type` (`<sys/vnode.h>`'s
    /// `enum vtype`, read here as the plain `Int32` the struct field
    /// actually is rather than that enum type, since the C declaration
    /// itself is `int vi_type`, not `enum vtype vi_type`).
    private static func readVnode(pid: pid_t, descriptor: Int32) -> OpenFileEntry {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        let result = proc_pidfdinfo(pid, descriptor, PROC_PIDFDVNODEPATHINFO, &info, size)
        guard result == size else {
            return OpenFileEntry(descriptor: descriptor, kind: "File", name: nil)
        }
        let kind = vnodeKindLabel(vtype: info.pvip.vip_vi.vi_type)
        let path = fixedCString(info.pvip.vip_path)
        return OpenFileEntry(descriptor: descriptor, kind: kind, name: path)
    }

    /// `<sys/vnode.h>`'s `enum vtype` values, hardcoded the same way
    /// `TCPState(bsdState:)`-style kernel-constant mappings elsewhere in
    /// this app are (see `ConnectionsProvider.TCPState`'s own doc
    /// comment): `VNON`=0 (no type — falls to the `default` case below,
    /// same as an unrecognized value), `VREG`=1, `VDIR`=2, `VBLK`=3,
    /// `VCHR`=4, `VLNK`=5, `VSOCK`=6 (a vnode-backed socket entry
    /// shouldn't reach here — sockets are `PROX_FDTYPE_SOCKET`, handled by
    /// `readSocket` — but mapped honestly if the kernel ever reports one
    /// this way), `VFIFO`=7.
    private static func vnodeKindLabel(vtype: Int32) -> String {
        switch vtype {
        case 1: return "File"
        case 2: return "Directory"
        case 3: return "Block Device"
        case 4: return "Character Device"
        case 5: return "Symbolic Link"
        case 6: return "Socket"
        case 7: return "FIFO"
        default: return "File"
        }
    }

    /// `PROC_PIDFDSOCKETINFO` — classifies into TCP/UDP/Unix-domain the
    /// same way `ConnectionsProvider.readSocket(pid:fd:...)` does (see
    /// that type's own doc comment for why the two files each carry their
    /// own copy of this classification rather than sharing it: its
    /// `TCPState(bsdState:)` initializer and low-level address helpers are
    /// `fileprivate`/`private` to that file, and this reader's per-pid
    /// scope only needs a display string back, not a full `ConnectionSocket`
    /// value).
    private static func readSocket(pid: pid_t, descriptor: Int32) -> OpenFileEntry {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        let result = proc_pidfdinfo(pid, descriptor, PROC_PIDFDSOCKETINFO, &info, size)
        guard result == size else {
            return OpenFileEntry(descriptor: descriptor, kind: "Socket", name: nil)
        }

        let soi = info.psi
        // `soi_kind`'s field type is plain `int` (`Int32`), but the
        // `SOCKINFO_*` constants come from an anonymous, untyped C `enum`
        // — Swift's Clang importer gives those plain `Int`, so the switch
        // subject is widened to match (same reasoning as
        // `ConnectionsProvider.readSocket`'s identical cast).
        switch Int(soi.soi_kind) {
        case SOCKINFO_TCP:
            let tcp = soi.soi_proto.pri_tcp
            return ipSocketEntry(
                descriptor: descriptor,
                transportLabel: "TCP",
                ini: tcp.tcpsi_ini,
                tcpStateText: tcpStateLabel(bsdState: tcp.tcpsi_state)
            )
        case SOCKINFO_IN:
            guard soi.soi_protocol == IPPROTO_UDP else {
                // A raw IP socket (ICMP, ...) — no protocol label or state
                // this table can honestly show beyond "Socket".
                return OpenFileEntry(descriptor: descriptor, kind: "Socket", name: nil)
            }
            return ipSocketEntry(descriptor: descriptor, transportLabel: "UDP", ini: soi.soi_proto.pri_in, tcpStateText: nil)
        case SOCKINFO_UN:
            let un = soi.soi_proto.pri_un
            let path = fixedCString(un.unsi_addr.ua_sun.sun_path) ?? fixedCString(un.unsi_caddr.ua_sun.sun_path)
            return OpenFileEntry(descriptor: descriptor, kind: "Unix Socket", name: path)
        default:
            return OpenFileEntry(descriptor: descriptor, kind: "Socket", name: nil)
        }
    }

    /// Builds a TCP/UDP row's `kind` ("TCP4"/"UDP6"/...) and `name`
    /// ("192.168.1.5:51413 \u{2192} 93.184.216.34:443 (Established)") from
    /// one `in_sockinfo` — the address/port reading half of
    /// `ConnectionsProvider.makeIPSocket`'s own logic, condensed into a
    /// single display string rather than a `ConnectionSocket`'s separate
    /// fields, since that's all this tab's "Name" column has room for.
    private static func ipSocketEntry(descriptor: Int32, transportLabel: String, ini: in_sockinfo, tcpStateText: String?) -> OpenFileEntry {
        let versionSuffix: String
        if ini.insi_vflag & UInt8(INI_IPV6) != 0 {
            versionSuffix = "6"
        } else if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
            versionSuffix = "4"
        } else {
            versionSuffix = ""
        }
        let kind = "\(transportLabel)\(versionSuffix)"

        let localPort = portNumber(fromNetworkOrder: ini.insi_lport)
        let remotePort = portNumber(fromNetworkOrder: ini.insi_fport)
        let localAddress = ipAddressText(local: true, ini: ini)
        // A listening/unconnected socket's foreign port reads back as 0
        // (folded to `nil` by `portNumber`) — treated as "no remote
        // endpoint" rather than reading (and showing) meaningless foreign-
        // address bytes, matching `ConnectionsProvider.makeIPSocket`'s own
        // guard.
        let remoteAddress = remotePort != nil ? ipAddressText(local: false, ini: ini) : nil

        var name = endpointText(address: localAddress, port: localPort)
        if remoteAddress != nil {
            name += " \u{2192} \(endpointText(address: remoteAddress, port: remotePort))"
        }
        if let tcpStateText {
            name += " (\(tcpStateText))"
        }
        return OpenFileEntry(descriptor: descriptor, kind: kind, name: name)
    }

    /// `<sys/proc_info.h>`'s `TSI_S_*` BSD TCP state constants, mapped to
    /// the same display wording `ConnectionsProvider.TCPState.displayName`
    /// uses — duplicated as a plain string-returning function rather than
    /// reused because `TCPState.init(bsdState:)` is `fileprivate` to
    /// `ConnectionsProvider.swift` (see `readSocket`'s own doc comment).
    private static func tcpStateLabel(bsdState: Int32) -> String {
        switch bsdState {
        case Int32(TSI_S_CLOSED): return "Closed"
        case Int32(TSI_S_LISTEN): return "Listen"
        case Int32(TSI_S_SYN_SENT): return "SYN Sent"
        case Int32(TSI_S_SYN_RECEIVED): return "SYN Received"
        case Int32(TSI_S_ESTABLISHED): return "Established"
        case Int32(TSI_S__CLOSE_WAIT): return "Close Wait"
        case Int32(TSI_S_FIN_WAIT_1): return "Fin Wait 1"
        case Int32(TSI_S_CLOSING): return "Closing"
        case Int32(TSI_S_LAST_ACK): return "Last ACK"
        case Int32(TSI_S_FIN_WAIT_2): return "Fin Wait 2"
        case Int32(TSI_S_TIME_WAIT): return "Time Wait"
        default: return "Other"
        }
    }

    /// Converts a `socket_fdinfo` address field's network-byte-order
    /// 16-bit port (widened into a signed `int` by the kernel struct) to a
    /// host-order `UInt16`, folding `0` ("no port"/"no peer") to `nil` —
    /// identical to `ConnectionsProvider.portNumber(fromNetworkOrder:)`.
    private static func portNumber(fromNetworkOrder raw: Int32) -> UInt16? {
        let value = UInt16(bigEndian: UInt16(truncatingIfNeeded: raw))
        return value == 0 ? nil : value
    }

    /// `inet_ntop`s one side of an `in_sockinfo`'s address pair — identical
    /// technique to `ConnectionsProvider.ipAddressText(local:ini:)`.
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

    private static func endpointText(address: String?, port: UInt16?) -> String {
        guard let address else { return "Unavailable" }
        guard let port else { return address }
        return "\(address):\(port)"
    }

    /// `PROC_PIDFDPIPEINFO` — an anonymous pipe has no path, only the
    /// kernel's own handle for this end (`pipe_info.pipe_handle`), shown
    /// in hex the way `lsof` itself prints a pipe's inode-like identifier.
    private static func readPipe(pid: pid_t, descriptor: Int32) -> OpenFileEntry {
        var info = pipe_fdinfo()
        let size = Int32(MemoryLayout<pipe_fdinfo>.size)
        let result = proc_pidfdinfo(pid, descriptor, PROC_PIDFDPIPEINFO, &info, size)
        guard result == size else {
            return OpenFileEntry(descriptor: descriptor, kind: "Pipe", name: nil)
        }
        return OpenFileEntry(descriptor: descriptor, kind: "Pipe", name: String(format: "Handle 0x%llx", info.pipeinfo.pipe_handle))
    }

    /// `PROC_PIDFDPSHMINFO` — a POSIX shared-memory region's `shm_open`
    /// name.
    private static func readSharedMemory(pid: pid_t, descriptor: Int32) -> OpenFileEntry {
        var info = pshm_fdinfo()
        let size = Int32(MemoryLayout<pshm_fdinfo>.size)
        let result = proc_pidfdinfo(pid, descriptor, PROC_PIDFDPSHMINFO, &info, size)
        guard result == size else {
            return OpenFileEntry(descriptor: descriptor, kind: "Shared Memory", name: nil)
        }
        return OpenFileEntry(descriptor: descriptor, kind: "Shared Memory", name: fixedCString(info.pshminfo.pshm_name))
    }

    /// `PROC_PIDFDPSEMINFO` — a POSIX semaphore's `sem_open` name.
    private static func readSemaphore(pid: pid_t, descriptor: Int32) -> OpenFileEntry {
        var info = psem_fdinfo()
        let size = Int32(MemoryLayout<psem_fdinfo>.size)
        let result = proc_pidfdinfo(pid, descriptor, PROC_PIDFDPSEMINFO, &info, size)
        guard result == size else {
            return OpenFileEntry(descriptor: descriptor, kind: "Semaphore", name: nil)
        }
        return OpenFileEntry(descriptor: descriptor, kind: "Semaphore", name: fixedCString(info.pseminfo.psem_name))
    }

    /// Reads a fixed-size C-string struct field (a `(CChar, CChar, ...)`
    /// tuple, however long) out as a `String`, `nil` for an empty one —
    /// one generic helper standing in for the several near-identical
    /// per-field versions `ConnectionsProvider.unixPathText(from:)` writes
    /// out by hand, since this reader needs the same technique for four
    /// different fixed-array fields (`vip_path`, `sun_path`, `pshm_name`,
    /// `psem_name`) rather than just one.
    private static func fixedCString<T>(_ value: T) -> String? {
        var mutableValue = value
        let text = withUnsafeBytes(of: &mutableValue) { raw -> String in
            let pointer = raw.bindMemory(to: CChar.self).baseAddress!
            return String(cString: pointer)
        }
        return text.isEmpty ? nil : text
    }
}
