import AppKit
import Darwin
import Foundation

/// A process's runtime state, as reported by the kernel at the moment
/// `pbi_status` was read — PLAN.md §1.1's Processes "Status" column. Raw
/// `SIDL`/`SRUN`/`SSLEEP`/`SSTOP`/`SZOMB` values from `<sys/proc.h>` are
/// hardcoded here as integer literals rather than imported macro names —
/// like `CPUProvider`'s `CPU_STATE_*` handling, this keeps the mapping
/// independent of whether a given macro happens to bridge cleanly into
/// Swift.
enum ProcessStatus: Sendable, Equatable {
    case idle
    case running
    case sleeping
    case stopped
    case zombie
    /// A `pbi_status` value outside the five documented BSD process
    /// states — kept with its raw value rather than silently folded into
    /// one of the cases above, since that costs nothing and might matter
    /// for diagnosis.
    case other(rawValue: Int32)

    fileprivate init(bsdStatus: UInt32) {
        switch bsdStatus {
        case 1: self = .idle
        case 2: self = .running
        case 3: self = .sleeping
        case 4: self = .stopped
        case 5: self = .zombie
        default: self = .other(rawValue: Int32(bitPattern: bsdStatus))
        }
    }
}

/// One process's full-fidelity reading for the Processes and Users pages
/// (PLAN.md §1.1, §4 M4) — the richer counterpart to M3's narrow
/// `TopProcessReading`. See that type's doc comment for why the two
/// coexist: the Summary dashboard's top-N table only ever needed four
/// columns, while this type backs the grouped Applications/Background
/// tree, its detail pane, and Users' per-user rollups.
struct ProcessReading: Sendable, Identifiable, Equatable {
    var id: pid_t { pid }
    let pid: pid_t
    /// `nil` for a process whose parent already exited, or whose `ppid`
    /// is `0` (`launchd`, and the handful of kernel-owned processes above
    /// it) — an honest "no known parent" rather than a fabricated root,
    /// and the value `ProcessProvider`'s tree-builder treats as a
    /// top-level slot to attach this process at.
    let parentPID: pid_t?
    /// Display name: a running application's
    /// `NSRunningApplication.localizedName` when this pid is one (e.g.
    /// "Xcode", not the binary's exact filename), else the executable
    /// path's last component, else `proc_name`'s short name. `nil` only
    /// when every one of those sources failed for this pid.
    let name: String?
    /// Full executable path (`proc_pidpath`) — PLAN.md §1.1's Processes
    /// detail pane "full path". `nil` when unreadable (e.g. another
    /// user's process without permission).
    let executablePath: String?
    /// Whether this pid is a running application per `NSWorkspace`
    /// (`NSRunningApplication.activationPolicy != .prohibited`) — the
    /// signal `ProcessProvider` groups the tree by (PLAN.md §1.1's
    /// "Applications (17) / Background processes (467)"). Covers both
    /// Dock-visible (`.regular`) and menu-bar/agent (`.accessory`) apps.
    let isApplication: Bool
    /// PNG-encoded app icon at a fixed thumbnail size, present only when
    /// `isApplication` and `NSWorkspace` published one. Encoded to `Data`
    /// rather than carried as `NSImage` so this whole reading stays a
    /// plain `Sendable` value crossing out of `ProcessProvider`'s actor —
    /// see `ProcessProvider.pngData(from:pixelSize:)`.
    let iconPNGData: Data?
    /// Owning user id (`pbi_uid`) — always readable once `PROC_PIDTBSDINFO`
    /// itself succeeded for this pid.
    let userID: uid_t
    /// `getpwuid_r`-resolved short username for `userID`. `nil` when the
    /// lookup fails (e.g. a uid with no directory-service entry).
    let userName: String?
    let status: ProcessStatus
    /// Process start time (`pbi_start_tvsec`/`_tvusec`).
    let startedAt: Date
    /// BSD `nice` value (`pbi_nice`) — PLAN.md §1.1 Lifetime "priority".
    let niceValue: Int
    /// `nil` when `PROC_PIDTASKINFO` couldn't be read for this pid (most
    /// often another user's process without permission — the same
    /// restriction `TopProcessReading.cpuPercent`'s doc comment notes).
    let threadCount: Int?
    /// Cumulative page faults since process start (`pti_faults`) — PLAN.md
    /// §1.1 Processes detail pane "Memory (footprint, private, page
    /// faults)". `nil` under the same condition as `threadCount`.
    let pageFaultCount: Int?
    /// Busy percentage since this pid was last sampled, following the
    /// same `top`-style convention as `TopProcessReading.cpuPercent`
    /// (CPU-time delta ÷ wall-clock delta × 100, not divided by core
    /// count). `nil` on this pid's first tick, or when task info couldn't
    /// be read this tick or the previous one.
    let cpuPercent: Double?
    /// Cumulative CPU time consumed since process start, in seconds.
    /// `nil` under the same condition as `threadCount`.
    let cpuTimeSeconds: Double?
    /// Resident memory footprint (`pti_resident_size`). `nil` under the
    /// same condition as `threadCount`.
    let memoryFootprintBytes: UInt64?
    /// Bytes read/written since this pid was last sampled, from
    /// `proc_pid_rusage`'s `ri_diskio_bytesread`/`_byteswritten` deltas.
    /// `nil` on this pid's first tick, when the counters didn't advance
    /// in a readable way, or when `proc_pid_rusage` itself couldn't read
    /// this pid (same permission restriction as task info).
    let diskReadBytesPerSecond: Double?
    let diskWriteBytesPerSecond: Double?
    /// Cumulative bytes read/written since process start. `nil` only
    /// when `proc_pid_rusage` couldn't read this pid at all.
    let totalDiskBytesRead: UInt64?
    let totalDiskBytesWritten: UInt64?
}

/// One node of the Applications/Background process tree — a
/// `ProcessReading` plus its child processes, nested per real
/// parent/child relationships. See `ProcessProvider.buildForest(from:)`
/// for how a process's position in `applications` vs. `background` is
/// decided.
struct ProcessNode: Sendable, Identifiable, Equatable {
    var id: pid_t { reading.pid }
    let reading: ProcessReading
    let children: [ProcessNode]
}

/// One tick's full process domain — PLAN.md §1.1's "Grouped tree:
/// Applications (17) / Background processes (467) with expandable
/// children" and §4 M4's first task.
struct ProcessForest: Sendable, Equatable {
    /// Root-level application processes, each with its full descendant
    /// subtree attached beneath it (e.g. a browser's helper processes
    /// nest under the browser here, even though the helpers themselves
    /// aren't applications) — see `ProcessProvider.buildForest(from:)`.
    let applications: [ProcessNode]
    /// Root-level non-application processes, structured as a forest with
    /// every application-classified descendant excised into
    /// `applications` instead (so an app launched by a background
    /// launcher still shows up under Applications, not buried in this
    /// tree).
    let background: [ProcessNode]
    /// Every reading this tick, flat — a convenience for a name/PID
    /// filter or a Users-page rollup that shouldn't have to re-walk
    /// `applications`/`background` to find a given pid.
    let all: [ProcessReading]
    /// Total process count under `applications`, including every nested
    /// descendant — PLAN.md §1.1's "(17)".
    let applicationCount: Int
    /// Total process count under `background`, including every nested
    /// descendant — PLAN.md §1.1's "(467)".
    let backgroundCount: Int
}

/// Failure mode for `ProcessProvider.sample()` — see `Provider`'s doc
/// comment for when a provider throws versus returning `nil` fields. Only
/// `proc_listallpids` failing throws; every other reading here is
/// per-process and degrades to `nil` on its own (see `ProcessReading`'s
/// field docs) rather than failing the whole tick.
enum ProcessProviderError: Error, LocalizedError {
    case listPidsFailed

    var errorDescription: String? {
        switch self {
        case .listPidsFailed: return "proc_listallpids failed"
        }
    }
}

/// Samples every running process's identity, lifetime, CPU, memory,
/// thread count, and disk I/O, grouped into an Applications/Background
/// tree — PLAN.md §3 `Providers/ProcessProvider.swift "libproc list/tree,
/// per-pid cpu/mem/threads/disk-io"` and §4 M4's first task. Backs the
/// Processes and Users pages (M4's remaining tasks).
///
/// An `actor`, matching `TopProcessesProvider`'s reasoning: this isn't
/// sampled from inside `Sampler`'s tick — there's no `process` field on
/// `Snapshot`, since a full process tree with icons is much heavier than
/// the 2×/sec domains `Sampler` folds together — but polled directly by
/// the Processes/Users pages' own view models, off the main thread.
/// Carries three kinds of state across ticks: the previous CPU-time and
/// disk-I/O raw counters (to derive rates, the same technique
/// `TopProcessesProvider` and `DiskProvider` use), a resolved-username
/// cache keyed by uid, and a PNG icon cache keyed by app path (so a
/// hundreds-of-processes list doesn't re-render every running app's icon
/// every tick).
actor ProcessProvider: Provider {
    static let providerID = "process"

    private struct CPUSample {
        let nanoseconds: UInt64
        let timestamp: Date
    }

    private struct DiskIOSample {
        let bytesRead: UInt64
        let bytesWritten: UInt64
        let timestamp: Date
    }

    /// One `NSWorkspace`-derived fact about a running application, read
    /// entirely on the main actor (see `readRunningApplications`) and
    /// reduced to plain `Sendable` data before crossing back — never an
    /// `NSRunningApplication`/`NSImage` itself.
    private struct RunningAppInfo: Sendable {
        let localizedName: String?
        let iconCacheKey: String
        let isAppLike: Bool
        /// Freshly-rendered icon PNG data, or `nil` when this app's icon
        /// is already in `iconCache` (skipped to avoid re-rendering it
        /// every tick) or it has none.
        let freshIconPNGData: Data?
    }

    /// Previous tick's raw CPU-time reading per pid — see
    /// `TopProcessesProvider.previousSamples`'s doc comment for why this
    /// is keyed by pid rather than array position.
    private var previousCPUSamples: [pid_t: CPUSample] = [:]
    private var previousDiskIOSamples: [pid_t: DiskIOSample] = [:]
    private var userNameCache: [uid_t: String] = [:]
    /// PNG icon data keyed by app bundle/executable path (see
    /// `RunningAppInfo.iconCacheKey`) — persists for the life of this
    /// provider so relaunching the same app reuses its cached icon.
    private var iconCache: [String: Data] = [:]

    func sample() async throws -> ProcessForest {
        let pids: [pid_t]
        do {
            pids = try Self.listAllPids()
        } catch {
            // Whole domain unreadable this tick — clear prior diff state
            // so a later recovery doesn't diff against now-stale counts
            // across the gap, matching CPUProvider/DiskProvider's own
            // handling of their whole-domain read failures.
            previousCPUSamples = [:]
            previousDiskIOSamples = [:]
            throw error
        }
        let now = Date()

        let runningApps = await Self.readRunningApplications(skippingIconsFor: Set(iconCache.keys))
        for info in runningApps.values {
            if let freshIcon = info.freshIconPNGData {
                iconCache[info.iconCacheKey] = freshIcon
            }
        }

        var currentCPUSamples: [pid_t: CPUSample] = [:]
        currentCPUSamples.reserveCapacity(pids.count)
        var currentDiskIOSamples: [pid_t: DiskIOSample] = [:]

        var readings: [pid_t: ProcessReading] = [:]
        readings.reserveCapacity(pids.count)

        for pid in pids {
            guard let bsdInfo = Self.readBSDInfo(pid: pid) else { continue }

            let taskInfo = Self.readTaskInfo(pid: pid)

            var cpuPercent: Double?
            var cpuTimeSeconds: Double?
            if let taskInfo {
                let cpuNanoseconds = taskInfo.pti_total_user + taskInfo.pti_total_system
                cpuTimeSeconds = Double(cpuNanoseconds) / 1_000_000_000
                currentCPUSamples[pid] = CPUSample(nanoseconds: cpuNanoseconds, timestamp: now)
                if let previous = previousCPUSamples[pid] {
                    let elapsed = now.timeIntervalSince(previous.timestamp)
                    if elapsed > 0, cpuNanoseconds >= previous.nanoseconds {
                        let deltaSeconds = Double(cpuNanoseconds - previous.nanoseconds) / 1_000_000_000
                        cpuPercent = (deltaSeconds / elapsed) * 100
                    }
                }
            }

            var diskReadRate: Double?
            var diskWriteRate: Double?
            var totalDiskRead: UInt64?
            var totalDiskWritten: UInt64?
            if let diskIO = Self.readDiskIOBytes(pid: pid) {
                totalDiskRead = diskIO.read
                totalDiskWritten = diskIO.written
                currentDiskIOSamples[pid] = DiskIOSample(
                    bytesRead: diskIO.read,
                    bytesWritten: diskIO.written,
                    timestamp: now
                )
                if let previous = previousDiskIOSamples[pid] {
                    let elapsed = now.timeIntervalSince(previous.timestamp)
                    if elapsed > 0, diskIO.read >= previous.bytesRead, diskIO.written >= previous.bytesWritten {
                        diskReadRate = Double(diskIO.read - previous.bytesRead) / elapsed
                        diskWriteRate = Double(diskIO.written - previous.bytesWritten) / elapsed
                    }
                }
            }

            let uid = bsdInfo.pbi_uid
            var userName = userNameCache[uid]
            if userName == nil, let resolved = Self.userName(forUID: uid) {
                userName = resolved
                userNameCache[uid] = resolved
            }

            let path = Self.executablePath(pid: pid)
            let runningApp = runningApps[pid]
            let isApplication = runningApp?.isAppLike ?? false
            let name = runningApp?.localizedName ?? Self.processName(pid: pid, path: path)
            let iconData: Data? = {
                guard isApplication, let key = runningApp?.iconCacheKey else { return nil }
                return iconCache[key]
            }()

            let rawParentPID = pid_t(bitPattern: bsdInfo.pbi_ppid)
            let parentPID: pid_t? = rawParentPID == 0 ? nil : rawParentPID

            let startedAt = Date(
                timeIntervalSince1970: Double(bsdInfo.pbi_start_tvsec) + Double(bsdInfo.pbi_start_tvusec) / 1_000_000
            )

            readings[pid] = ProcessReading(
                pid: pid,
                parentPID: parentPID,
                name: name,
                executablePath: path,
                isApplication: isApplication,
                iconPNGData: iconData,
                userID: uid,
                userName: userName,
                status: ProcessStatus(bsdStatus: bsdInfo.pbi_status),
                startedAt: startedAt,
                niceValue: Int(bsdInfo.pbi_nice),
                threadCount: taskInfo.map { Int($0.pti_threadnum) },
                pageFaultCount: taskInfo.map { Int($0.pti_faults) },
                cpuPercent: cpuPercent,
                cpuTimeSeconds: cpuTimeSeconds,
                memoryFootprintBytes: taskInfo?.pti_resident_size,
                diskReadBytesPerSecond: diskReadRate,
                diskWriteBytesPerSecond: diskWriteRate,
                totalDiskBytesRead: totalDiskRead,
                totalDiskBytesWritten: totalDiskWritten
            )
        }

        previousCPUSamples = currentCPUSamples
        previousDiskIOSamples = currentDiskIOSamples

        return Self.buildForest(from: readings)
    }

    // MARK: - Tree building

    /// Splits every reading into the Applications/Background forest pair
    /// `ProcessForest` publishes — PLAN.md §1.1's grouped tree. A process
    /// becomes a root of `applications` the moment it's itself
    /// `isApplication`, with its *entire* descendant subtree attached
    /// beneath it (so e.g. a browser's renderer helpers nest under the
    /// browser, even though the helpers aren't applications themselves).
    /// Every other process starts in `background`, except that any
    /// `isApplication` descendant found while walking a background
    /// subtree is excised out into its own `applications` root instead of
    /// staying nested — so an app spawned by a background launcher still
    /// surfaces as its own Applications entry, matching [name removed]'s flat
    /// per-app grouping (PLAN.md §1.1: "Applications (17)").
    private static func buildForest(from readings: [pid_t: ProcessReading]) -> ProcessForest {
        var childrenOf: [pid_t: [pid_t]] = [:]
        for reading in readings.values {
            guard let parentPID = reading.parentPID, readings[parentPID] != nil else { continue }
            childrenOf[parentPID, default: []].append(reading.pid)
        }
        for pid in childrenOf.keys {
            childrenOf[pid]?.sort { pidSortKey(readings[$0]) < pidSortKey(readings[$1]) }
        }

        var applicationRoots: [ProcessNode] = []
        var backgroundRoots: [ProcessNode] = []

        func fullSubtree(_ pid: pid_t) -> ProcessNode {
            let children = (childrenOf[pid] ?? []).map { fullSubtree($0) }
            return ProcessNode(reading: readings[pid]!, children: children)
        }

        func backgroundSubtree(_ pid: pid_t) -> ProcessNode {
            var children: [ProcessNode] = []
            for childPID in childrenOf[pid] ?? [] {
                guard let childReading = readings[childPID] else { continue }
                if childReading.isApplication {
                    applicationRoots.append(fullSubtree(childPID))
                } else {
                    children.append(backgroundSubtree(childPID))
                }
            }
            return ProcessNode(reading: readings[pid]!, children: children)
        }

        let allPIDs = Set(readings.keys)
        let topLevelPIDs = allPIDs
            .filter { pid in
                guard let parentPID = readings[pid]?.parentPID else { return true }
                return readings[parentPID] == nil
            }
            .sorted { pidSortKey(readings[$0]) < pidSortKey(readings[$1]) }

        for pid in topLevelPIDs {
            guard let reading = readings[pid] else { continue }
            if reading.isApplication {
                applicationRoots.append(fullSubtree(pid))
            } else {
                backgroundRoots.append(backgroundSubtree(pid))
            }
        }

        return ProcessForest(
            applications: applicationRoots,
            background: backgroundRoots,
            all: Array(readings.values),
            applicationCount: countNodes(applicationRoots),
            backgroundCount: countNodes(backgroundRoots)
        )
    }

    /// Sort key for display order within a tree level: name (matching
    /// Finder/Activity Monitor's default alphabetical process ordering),
    /// falling back to pid for the rare unnamed process so ordering is
    /// still stable.
    private static func pidSortKey(_ reading: ProcessReading?) -> String {
        guard let reading else { return "" }
        return (reading.name ?? String(reading.pid)).lowercased()
    }

    private static func countNodes(_ nodes: [ProcessNode]) -> Int {
        nodes.reduce(0) { $0 + 1 + countNodes($1.children) }
    }

    // MARK: - libproc

    /// Lists every currently-running pid — identical technique to
    /// `TopProcessesProvider.listAllPids()` (see that method's doc
    /// comment for why the buffer is padded past the first estimate).
    private static func listAllPids() throws -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { throw ProcessProviderError.listPidsFailed }

        let capacity = Int(estimate) + 256
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytesFilled = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard bytesFilled > 0 else { throw ProcessProviderError.listPidsFailed }

        let filledCount = min(Int(bytesFilled) / MemoryLayout<pid_t>.size, pids.count)
        return Array(pids[0..<filledCount])
    }

    /// `nil` when `proc_pidinfo` can't read this pid's BSD info this tick
    /// (exited between `listAllPids()` and this call, or permission
    /// denied) — the whole reading is skipped for this pid rather than
    /// built from a partial struct.
    private static func readBSDInfo(pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard result == size else { return nil }
        return info
    }

    /// `nil` when `proc_pidinfo` can't read this pid's task info — most
    /// often another user's process without permission (same restriction
    /// `TopProcessesProvider.readTaskInfo` documents).
    private static func readTaskInfo(pid: pid_t) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        guard result == size else { return nil }
        return info
    }

    /// Cumulative disk I/O byte counters via `proc_pid_rusage`
    /// (`RUSAGE_INFO_V2`'s `ri_diskio_bytesread`/`_byteswritten`) — the
    /// per-process counterpart to `DiskProvider`'s whole-device
    /// `IOBlockStorageDriver` statistics. `nil` on any failure (most
    /// often the same cross-user permission restriction as task info).
    private static func readDiskIOBytes(pid: pid_t) -> (read: UInt64, written: UInt64)? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, rebound)
            }
        }
        guard result == 0 else { return nil }
        return (read: info.ri_diskio_bytesread, written: info.ri_diskio_byteswritten)
    }

    /// Full executable path (`proc_pidpath`). `nil` when unreadable.
    private static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * 1024)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Display name fallback for a pid that isn't a running application:
    /// the executable path's last component, else `proc_name`'s short
    /// name — same technique as `TopProcessesProvider.processName`.
    private static func processName(pid: pid_t, path: String?) -> String? {
        if let path {
            let lastComponent = URL(fileURLWithPath: path).lastPathComponent
            if !lastComponent.isEmpty { return lastComponent }
        }
        var buffer = [CChar](repeating: 0, count: 64)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Directory service

    /// Thread-safe (`getpwuid_r`, not the shared-buffer `getpwuid`)
    /// short username lookup for a uid. `nil` when the uid has no
    /// directory-service entry.
    private static func userName(forUID uid: uid_t) -> String? {
        var entry = passwd()
        var entryPointer: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4096)
        let result = getpwuid_r(uid, &entry, &buffer, buffer.count, &entryPointer)
        guard result == 0, let entryPointer, let namePointer = entryPointer.pointee.pw_name else {
            return nil
        }
        return String(cString: namePointer)
    }

    // MARK: - NSWorkspace (main actor)

    /// Reads every running application's identity and, for ones not
    /// already in `iconCache`, its icon — all on the main actor, since
    /// `NSWorkspace`/`NSRunningApplication`/`NSImage` rendering isn't
    /// safe off it. Reduces each app to a plain `Sendable`
    /// `RunningAppInfo` before returning, rather than handing back
    /// `NSRunningApplication`/`NSImage` themselves.
    private static func readRunningApplications(skippingIconsFor cachedKeys: Set<String>) async -> [pid_t: RunningAppInfo] {
        await MainActor.run {
            var result: [pid_t: RunningAppInfo] = [:]
            for app in NSWorkspace.shared.runningApplications {
                let key = app.bundleURL?.path ?? app.executableURL?.path ?? "pid-\(app.processIdentifier)"
                let isAppLike = app.activationPolicy != .prohibited

                var freshIcon: Data?
                if isAppLike, !cachedKeys.contains(key), let icon = app.icon {
                    freshIcon = pngData(from: icon, pixelSize: 64)
                }

                result[app.processIdentifier] = RunningAppInfo(
                    localizedName: app.localizedName,
                    iconCacheKey: key,
                    isAppLike: isAppLike,
                    freshIconPNGData: freshIcon
                )
            }
            return result
        }
    }

    /// Renders `image` into a fixed `pixelSize × pixelSize` RGBA bitmap
    /// and encodes it as PNG — a consistent thumbnail size for the
    /// Processes table regardless of which representation
    /// `NSRunningApplication.icon` happened to hand back. `nil` if the
    /// bitmap context couldn't be created.
    private static func pngData(from image: NSImage, pixelSize: Int) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        return bitmap.representation(using: .png, properties: [:])
    }
}
