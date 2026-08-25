import Foundation
import SQLite3

/// Downsampled, pruned SQLite persistence of every domain's live history —
/// PLAN.md §3's `Core/HistoryStore.swift "SQLite persistence, 24h/7d
/// queries, pruning"` and §4 M9's second task: "downsampled SQLite
/// persistence of all domains; pruning policy." One of §2's "Beyond [name removed]
/// (our own additions, M8–M10)" items — [name removed] itself keeps no history at
/// all once a live graph's reading scrolls off-screen.
///
/// Owned once, at the process's lifetime, the same way `AppDelegate` owns
/// `alertsEngine`/`menuBarStatus` (M8/M9): history is only useful if it
/// keeps recording while the main window is closed, so `start()` is called
/// exactly once from `AppDelegate.applicationDidFinishLaunching`, never
/// from a page's `onAppear`/`onDisappear` — the future `HistoryPage` (a
/// separate M9 task) only *reads* this store through the query methods
/// below, it doesn't own this store's lifecycle.
///
/// ## Recording cadence — why "downsampled" starts at ingest, not just aging
/// Like `AlertsEngine`, this owns a private `Sampler` at its own slow,
/// history-appropriate cadence (`rawInterval`, 30s) rather than riding the
/// UI's own 2×/sec `Sampler` — writing to SQLite forty times a minute for
/// the sole purpose of a "24h/7d" browsing chart would spend real disk I/O
/// on resolution nothing on that chart's own axis could ever show. A day of
/// 30-second samples across eight domains is already the size this store
/// expects to hold at its finest resolution.
///
/// ## Aging — three fixed resolutions, one generic roll-up
/// A tick writes one `.raw` row per metric (`bucketStart` == the tick's own
/// timestamp; `sampleCount == 1`, `avg == min == max == value`). A
/// background maintenance pass, `runMaintenance()`, periodically rolls
/// fully-aged `.raw` rows into 5-minute `.minute` buckets, and fully-aged
/// `.minute` rows into 1-hour `.hour` buckets, using a `sampleCount`-weighted
/// average so a `.minute` → `.hour` roll-up (aggregating rows that are
/// themselves already averages) is exactly as honest as a `.raw` → `.minute`
/// one (aggregating single readings) — see
/// `compact(from:to:bucketSeconds:olderThan:)`. `.hour` rows past
/// `hourRetention` are hard-deleted by `prune(resolution:olderThan:)` — this
/// store's actual pruning policy; PLAN.md's "24h/7d views" both sit
/// comfortably inside `hourRetention`'s window, so nothing a `HistoryPage`
/// chart could ask for is ever pruned out from under it.
///
/// Every resolution's rows share one table, `history_points`, keyed
/// `(resolution, domain, key, bucketStart)`. `series(domain:key:since:)`
/// selects across all three resolutions for a time range in one query:
/// a given moment in time lives in exactly one resolution at any point in
/// this store's life, because `compact()` only deletes a resolution's
/// source rows for a bucket *after* successfully writing that bucket's
/// coarser replacement — so a plain filtered scan of the whole table is
/// already complete, with no double-counting and no gaps.
///
/// An actor, like `Sampler`: SQLite file I/O must not run on the main
/// thread, and every operation here (recording, maintenance, querying) is
/// naturally serialized against the one connection this way, with no
/// separate locking.
actor HistoryStore {
    static let providerID = "history"

    /// The eight metric domains this store records. Raw values match each
    /// domain's own `Provider.providerID` (`CPUProvider.providerID`, ...)
    /// so a stored row's `domain` column reads the same as the rest of this
    /// app's provider-health keys.
    enum Domain: String, CaseIterable, Sendable {
        case cpu, memory, gpu, disk, network, energy, thermal, npu
    }

    /// `HistoryPage`'s two named browsing windows (PLAN.md §2/§4:
    /// "persistent history (SQLite, 24h/7d views)"). `Hashable` +
    /// `CaseIterable` so `HistoryPage` can drive a segmented `Picker`
    /// straight off `Range.allCases` and use a value as a SwiftUI
    /// `.task(id:)` key; `displayName` is that picker's label text.
    enum Range: Sendable, Hashable, CaseIterable {
        case last24Hours
        case last7Days

        /// Not `fileprivate` (unlike the rest of this store's internals):
        /// `HistoryPage` itself needs this to compute the `since` bound for
        /// its own resampled chart layout, not just to pass a `Range` case
        /// through to `series(domain:key:range:now:)` below.
        var seconds: TimeInterval {
            switch self {
            case .last24Hours: 24 * 3600
            case .last7Days: 7 * 24 * 3600
            }
        }

        var displayName: String {
            switch self {
            case .last24Hours: "24 Hours"
            case .last7Days: "7 Days"
            }
        }
    }

    /// One stored row `series(domain:key:since:)` returns — a bare reading
    /// at `.raw` resolution (`average == minimum == maximum`,
    /// `sampleCount == 1`) or a real aggregate at `.minute`/`.hour`
    /// resolution. `minimum`/`maximum` are what let a 24h/7d chart still
    /// show "what spiked while I was away" even once the raw reading behind
    /// a spike has long since been rolled into a multi-sample average.
    struct SeriesPoint: Sendable, Equatable {
        let timestamp: Date
        let average: Double
        let minimum: Double
        let maximum: Double
        let sampleCount: Int
    }

    /// One `(domain, key)` series identifier — `distinctSeries()`'s element
    /// type, for a future `HistoryPage` series picker.
    struct SeriesID: Sendable, Hashable {
        let domain: Domain
        let key: String
    }

    /// The three resolutions a row can be stored/queried at — see this
    /// type's doc comment for the roll-up policy between them.
    private enum Resolution: String {
        case raw, minute, hour
    }

    /// One `(domain, key, value)` reading extracted from a `Snapshot` for
    /// recording — e.g. `(.cpu, "total", 42.3)`. `key` is this store's own
    /// short series name, not necessarily a `Snapshot` field name verbatim;
    /// see `metrics(from:)`.
    private struct Metric {
        let domain: Domain
        let key: String
        let value: Double
    }

    /// Cadence this store's own private `Sampler` records at — see this
    /// type's doc comment on why that's much slower than the UI's own
    /// `Sampler.Interval.normal`.
    private static let rawInterval: Sampler.Interval = .custom(30)
    /// How long `.raw` rows survive before `runMaintenance()` rolls them
    /// into `.minute` buckets and deletes them.
    private static let rawRetention: TimeInterval = 2 * 3600
    /// Bucket width for `.minute` rows.
    private static let minuteBucketSeconds: TimeInterval = 300
    /// How long `.minute` rows survive before `runMaintenance()` rolls them
    /// into `.hour` buckets and deletes them.
    private static let minuteRetention: TimeInterval = 2 * 24 * 3600
    /// Bucket width for `.hour` rows.
    private static let hourBucketSeconds: TimeInterval = 3600
    /// How long `.hour` rows survive before `runMaintenance()` hard-deletes
    /// them — this store's actual pruning policy, well past both of
    /// `Range`'s named windows.
    private static let hourRetention: TimeInterval = 30 * 24 * 3600
    /// How often the background maintenance pass runs. Deliberately much
    /// less often than `rawInterval`: rolling up and pruning is a handful
    /// of aggregate SQL statements over the whole table, not a per-tick
    /// cost.
    private static let maintenanceInterval: TimeInterval = 10 * 60

    /// `sqlite3_bind_text`'s "copy this string in, I'm not keeping the
    /// buffer alive myself" destructor — every text bind below passes its
    /// argument as a short-lived Swift `String`, never a buffer this store
    /// itself owns past the call, so `SQLITE_TRANSIENT` (there is no Swift
    /// constant for the C macro) is always the right choice over
    /// `SQLITE_STATIC`.
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `nil` when `openDatabase(at:)` failed (see `openError`) — every
    /// operation below degrades to a no-op / empty result rather than
    /// crashing, matching PLAN.md's "providers must degrade gracefully"
    /// rule for this store's own durability, not just a `Provider`'s
    /// readings.
    private var db: OpaquePointer?
    /// Set once, in `init`, if `db` never opened at all (e.g. the sandbox
    /// denied `Application Support`, or the disk is full). `HistoryPage`'s
    /// future "Unavailable" banner reads this the same way `PageInfoBar`
    /// reads a degraded provider's reason.
    private(set) var openError: String?
    /// Set whenever the most recent write or maintenance pass itself
    /// failed against an otherwise-open database (a full disk mid-run,
    /// say) — distinct from `openError`, which is permanent for this
    /// store's lifetime.
    private(set) var lastError: String?
    /// When this store last successfully recorded a tick's metrics —
    /// `HistoryPage`'s future "recording since" / heartbeat line.
    private(set) var lastRecordedAt: Date?
    /// The on-disk location this store opened (or tried to open) —
    /// informational only, e.g. for a future "Reveal in Finder" action.
    let databaseURL: URL

    private let sampler: Sampler
    private var hasStarted = false
    private var sampleStreamTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?

    /// - Parameter fileURL: Where to open the SQLite database. Defaults to
    ///   `defaultDatabaseURL()`; tests should pass an isolated temporary
    ///   file so they don't read or leave behind the user's real history.
    init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultDatabaseURL()
        self.databaseURL = url
        self.sampler = Sampler(interval: Self.rawInterval)
        do {
            self.db = try Self.openDatabase(at: url)
        } catch {
            self.db = nil
            self.openError = error.localizedDescription
        }
    }

    deinit {
        sampleStreamTask?.cancel()
        maintenanceTask?.cancel()
        if let db {
            sqlite3_close(db)
        }
    }

    /// Whether this store actually has an open database to write to —
    /// `false` for the whole lifetime of an instance whose `init` failed to
    /// open one (see `openError`).
    var isAvailable: Bool { db != nil }

    // MARK: - Lifecycle

    /// Starts the background recording `Sampler` and the periodic
    /// maintenance pass. Safe to call repeatedly (a no-op after the first
    /// call) — see this type's doc comment for why the only real caller is
    /// `AppDelegate.applicationDidFinishLaunching`. A no-op entirely when
    /// `isAvailable` is `false`: there is nothing useful a recording loop
    /// could do without an open database.
    func start() async {
        guard !hasStarted, isAvailable else { return }
        hasStarted = true

        let sampler = sampler
        sampleStreamTask = Task { [weak self] in
            await sampler.start()
            for await snapshot in sampler.stream() {
                guard let self else { return }
                await self.record(snapshot)
            }
        }

        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runMaintenance()
                try? await Task.sleep(nanoseconds: UInt64(HistoryStore.maintenanceInterval * 1_000_000_000))
            }
        }
    }

    /// Stops the recording `Sampler` and maintenance loop. Not called from
    /// anywhere in the app today (this store, like `AlertsEngine`, is meant
    /// to run for the whole process lifetime) — provided for symmetry with
    /// `Sampler.stop()` and for tests that need a clean teardown.
    func stop() {
        sampleStreamTask?.cancel()
        sampleStreamTask = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        hasStarted = false
    }

    // MARK: - Recording

    /// Extracts every readable metric from `snapshot` (see `metrics(from:)`)
    /// and records one `.raw` row per metric, `bucketStart` == this tick's
    /// own timestamp. Called once per this store's own private `Sampler`
    /// tick (see `start()`) — never from the UI's own faster `Sampler`, per
    /// this type's doc comment.
    private func record(_ snapshot: Snapshot) {
        guard db != nil else { return }
        let bucketStart = snapshot.timestamp.timeIntervalSince1970
        do {
            for metric in Self.metrics(from: snapshot) {
                try upsert(
                    resolution: .raw,
                    domain: metric.domain,
                    key: metric.key,
                    bucketStart: bucketStart,
                    average: metric.value,
                    minimum: metric.value,
                    maximum: metric.value,
                    sampleCount: 1
                )
            }
            lastRecordedAt = snapshot.timestamp
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Which scalar readings this store records per domain, and under what
    /// key — the "downsampled" half of this store's job starts here: every
    /// domain's rich per-tick `Snapshot` payload (per-core CPU grids,
    /// per-die thermal sensors, per-volume disk capacity, ...) is reduced to
    /// the handful of headline numbers a 24h/7d browsing chart actually
    /// plots — the same headline reading each domain's own Summary/
    /// Performance page leads with — rather than persisting everything a
    /// `Snapshot` carries. `nil` readings (this app's honest-degradation
    /// rule, already applied upstream by each `Provider`) are simply
    /// omitted here, never recorded as a fabricated zero.
    private static func metrics(from snapshot: Snapshot) -> [Metric] {
        var metrics: [Metric] = []

        if let cpu = snapshot.cpu {
            append(&metrics, .cpu, "total", cpu.totalUtilization)
            append(&metrics, .cpu, "user", cpu.userUtilization)
            append(&metrics, .cpu, "system", cpu.systemUtilization)
        }
        if let memory = snapshot.memory {
            if let total = memory.totalBytes, let used = memory.usedBytes, total > 0 {
                append(&metrics, .memory, "usedPercent", Double(used) / Double(total) * 100)
            }
            append(&metrics, .memory, "swapUsedBytes", memory.swapUsedBytes.map(Double.init))
            if let pressure = memory.pressureLevel {
                append(&metrics, .memory, "pressureLevel", pressureRank(pressure))
            }
        }
        if let gpu = snapshot.gpu {
            append(&metrics, .gpu, "utilization", gpu.utilizationPercent)
            append(&metrics, .gpu, "vramUsedBytes", gpu.vramUsedBytes.map(Double.init))
            append(&metrics, .gpu, "temperature", gpu.temperatureCelsius)
        }
        if let disk = snapshot.disk {
            append(&metrics, .disk, "activePercent", disk.activePercent)
            append(&metrics, .disk, "readBytesPerSecond", disk.readBytesPerSecond)
            append(&metrics, .disk, "writeBytesPerSecond", disk.writeBytesPerSecond)
        }
        if let network = snapshot.network {
            append(&metrics, .network, "sendBytesPerSecond", network.sendBytesPerSecond)
            append(&metrics, .network, "receiveBytesPerSecond", network.receiveBytesPerSecond)
        }
        if let energy = snapshot.energy {
            append(&metrics, .energy, "systemPowerWatts", energy.systemPowerWatts)
            append(&metrics, .energy, "batteryPercent", energy.battery?.percent)
        }
        if let thermal = snapshot.thermal {
            append(&metrics, .thermal, "hotspotCelsius", thermal.hotspotCelsius)
            append(&metrics, .thermal, "pressureLevel", pressureRank(thermal.thermalPressure))
        }
        if let npu = snapshot.npu {
            if let isActive = npu.isActive {
                append(&metrics, .npu, "active", isActive ? 1 : 0)
            }
            append(&metrics, .npu, "energyDeltaRaw", npu.energyDeltaRaw.map(Double.init))
        }

        return metrics
    }

    /// Appends `(domain, key, value)` only when `value` is present and
    /// finite — guards against ever writing `NaN`/`±infinity` into SQLite
    /// (which would otherwise round-trip as `NULL` or an unusable reading)
    /// from a reading that's honestly missing rather than zero.
    private static func append(_ metrics: inout [Metric], _ domain: Domain, _ key: String, _ value: Double?) {
        guard let value, value.isFinite else { return }
        metrics.append(Metric(domain: domain, key: key, value: value))
    }

    /// Encodes `MemoryPressureLevel` as an ordinal this store can chart
    /// numerically (`0`/`1`/`2`) — the same ordering `AlertsEngine`'s own
    /// `meetsThreshold` treats as "at least this severe".
    private static func pressureRank(_ level: MemoryPressureLevel) -> Double {
        switch level {
        case .normal: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }

    /// Encodes `ThermalPressureLevel` as an ordinal the same way. `.unknown`
    /// (a future `ProcessInfo.ThermalState` case this app doesn't yet
    /// recognize) is recorded as `-1` rather than folded into `.nominal`'s
    /// `0` — an honest "outside the known scale" value, not a guess that
    /// everything was fine.
    private static func pressureRank(_ level: ThermalPressureLevel) -> Double {
        switch level {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        case .unknown: return -1
        }
    }

    // MARK: - Maintenance (roll-up + pruning)

    /// Runs one maintenance pass: rolls fully-aged `.raw` rows into
    /// `.minute` buckets, fully-aged `.minute` rows into `.hour` buckets,
    /// then hard-deletes `.hour` rows past `hourRetention`. Called on
    /// `maintenanceInterval`'s own timer from `start()`; also safe to call
    /// directly (e.g. a future debug action, or a test that wants
    /// deterministic roll-up without waiting on the timer).
    func runMaintenance() {
        guard isAvailable else { return }
        let now = Date().timeIntervalSince1970
        do {
            try compact(from: .raw, to: .minute, bucketSeconds: Self.minuteBucketSeconds, olderThan: now - Self.rawRetention)
            try compact(from: .minute, to: .hour, bucketSeconds: Self.hourBucketSeconds, olderThan: now - Self.minuteRetention)
            try prune(resolution: .hour, olderThan: now - Self.hourRetention)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Rolls every `(domain, key)` group's fully-aged `source` rows into one
    /// `sampleCount`-weighted `target` row per bucket, then deletes the
    /// `source` rows that fed it. `olderThan` is floored to a
    /// `bucketSeconds` boundary (`alignedCutoff`) before either query runs,
    /// so a bucket is only ever finalized once its *entire* time window has
    /// aged past `olderThan` — a bucket straddling the cutoff is left alone
    /// this pass and picked up whole on a later one, rather than being
    /// finalized from a partial window and then silently missing whatever
    /// arrives in its other half.
    ///
    /// `INSERT OR REPLACE` (inside `upsert`) is what makes this safe to
    /// re-run over a bucket that a previous, interrupted pass already
    /// aggregated once (crashed between this method's insert and delete,
    /// say): the `source` rows for that bucket are still present, so the
    /// `SELECT` below recomputes the *complete* aggregate from scratch and
    /// overwrites whatever partial state the interrupted pass left, rather
    /// than double-adding on top of it.
    private func compact(from source: Resolution, to target: Resolution, bucketSeconds: TimeInterval, olderThan: TimeInterval) throws {
        guard let db else { return }
        let alignedCutoff = (olderThan / bucketSeconds).rounded(.down) * bucketSeconds

        let selectSQL = """
        SELECT domain, key,
               CAST(bucket_start / ? AS INTEGER) * ? AS coarse_bucket,
               SUM(avg_value * sample_count) / SUM(sample_count) AS w_avg,
               MIN(min_value) AS w_min,
               MAX(max_value) AS w_max,
               SUM(sample_count) AS w_count
        FROM history_points
        WHERE resolution = ? AND bucket_start < ?
        GROUP BY domain, key, coarse_bucket;
        """
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK, let selectStmt else {
            throw HistoryStoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_double(selectStmt, 1, bucketSeconds)
        sqlite3_bind_double(selectStmt, 2, bucketSeconds)
        sqlite3_bind_text(selectStmt, 3, source.rawValue, -1, Self.sqliteTransient)
        sqlite3_bind_double(selectStmt, 4, alignedCutoff)

        struct RolledUpRow {
            let domain: String
            let key: String
            let bucketStart: Double
            let average: Double
            let minimum: Double
            let maximum: Double
            let sampleCount: Int
        }
        var rolledUp: [RolledUpRow] = []
        while sqlite3_step(selectStmt) == SQLITE_ROW {
            guard let domainText = sqlite3_column_text(selectStmt, 0),
                  let keyText = sqlite3_column_text(selectStmt, 1)
            else { continue }
            rolledUp.append(RolledUpRow(
                domain: String(cString: domainText),
                key: String(cString: keyText),
                bucketStart: sqlite3_column_double(selectStmt, 2),
                average: sqlite3_column_double(selectStmt, 3),
                minimum: sqlite3_column_double(selectStmt, 4),
                maximum: sqlite3_column_double(selectStmt, 5),
                sampleCount: Int(sqlite3_column_int64(selectStmt, 6))
            ))
        }
        sqlite3_finalize(selectStmt)
        guard !rolledUp.isEmpty else { return }

        for row in rolledUp {
            guard let domain = Domain(rawValue: row.domain) else { continue }
            try upsert(
                resolution: target,
                domain: domain,
                key: row.key,
                bucketStart: row.bucketStart,
                average: row.average,
                minimum: row.minimum,
                maximum: row.maximum,
                sampleCount: row.sampleCount
            )
        }

        let deleteSQL = "DELETE FROM history_points WHERE resolution = ? AND bucket_start < ?;"
        var deleteStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStmt, nil) == SQLITE_OK, let deleteStmt else {
            throw HistoryStoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(deleteStmt) }
        sqlite3_bind_text(deleteStmt, 1, source.rawValue, -1, Self.sqliteTransient)
        sqlite3_bind_double(deleteStmt, 2, alignedCutoff)
        guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
            throw HistoryStoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Hard-deletes every `resolution` row older than `olderThan` — this
    /// store's actual pruning policy (`.hour` past `hourRetention`, called
    /// from `runMaintenance()`), with no coarser resolution left to roll
    /// the data into first.
    private func prune(resolution: Resolution, olderThan: TimeInterval) throws {
        guard let db else { return }
        let sql = "DELETE FROM history_points WHERE resolution = ? AND bucket_start < ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw HistoryStoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, resolution.rawValue, -1, Self.sqliteTransient)
        sqlite3_bind_double(stmt, 2, olderThan)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw HistoryStoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Idempotent single-row upsert shared by `record` (a fresh `.raw` row
    /// every tick) and `compact` (re-finalizing a `.minute`/`.hour` bucket).
    /// `INSERT OR REPLACE` — never a partial update — is correct for both
    /// callers: `record`'s bucket key is a brand-new timestamp, and
    /// `compact` always supplies a freshly, fully recomputed aggregate for
    /// its bucket (see that method's doc comment), so replacing whatever
    /// (if anything) was there is exactly the intended effect.
    private func upsert(
        resolution: Resolution,
        domain: Domain,
        key: String,
        bucketStart: TimeInterval,
        average: Double,
        minimum: Double,
        maximum: Double,
        sampleCount: Int
    ) throws {
        guard let db else { return }
        let sql = """
        INSERT OR REPLACE INTO history_points
            (resolution, domain, key, bucket_start, avg_value, min_value, max_value, sample_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw HistoryStoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, resolution.rawValue, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 2, domain.rawValue, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 3, key, -1, Self.sqliteTransient)
        sqlite3_bind_double(stmt, 4, bucketStart)
        sqlite3_bind_double(stmt, 5, average)
        sqlite3_bind_double(stmt, 6, minimum)
        sqlite3_bind_double(stmt, 7, maximum)
        sqlite3_bind_int64(stmt, 8, Int64(sampleCount))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw HistoryStoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Querying (HistoryPage)

    /// Every stored point for `(domain, key)` at or after `since`, oldest
    /// first, across all three resolutions in one query — see this type's
    /// doc comment for why a plain filtered scan is already a complete,
    /// non-overlapping reconstruction of the requested range. Returns an
    /// empty array (never throws) when this store has no open database or
    /// the query itself fails — `HistoryPage` reads an empty series the
    /// same honest way every other page reads a `nil`/"Unavailable" field.
    func series(domain: Domain, key: String, since: Date) -> [SeriesPoint] {
        guard let db else { return [] }
        let sql = """
        SELECT bucket_start, avg_value, min_value, max_value, sample_count
        FROM history_points
        WHERE domain = ? AND key = ? AND bucket_start >= ?
        ORDER BY bucket_start ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, domain.rawValue, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 2, key, -1, Self.sqliteTransient)
        sqlite3_bind_double(stmt, 3, since.timeIntervalSince1970)

        var points: [SeriesPoint] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            points.append(SeriesPoint(
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                average: sqlite3_column_double(stmt, 1),
                minimum: sqlite3_column_double(stmt, 2),
                maximum: sqlite3_column_double(stmt, 3),
                sampleCount: Int(sqlite3_column_int64(stmt, 4))
            ))
        }
        return points
    }

    /// Convenience over `series(domain:key:since:)` for `HistoryPage`'s two
    /// named windows (`Range.last24Hours`/`.last7Days`).
    func series(domain: Domain, key: String, range: Range, now: Date = Date()) -> [SeriesPoint] {
        series(domain: domain, key: key, since: now.addingTimeInterval(-range.seconds))
    }

    /// Every `(domain, key)` this store has ever recorded, across every
    /// resolution — a future `HistoryPage` series picker's data source.
    /// Cheap: one `DISTINCT` scan of the indexed `(domain, key)` columns,
    /// not a full table read.
    func distinctSeries() -> [SeriesID] {
        guard let db else { return [] }
        let sql = "SELECT DISTINCT domain, key FROM history_points ORDER BY domain, key;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        var ids: [SeriesID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let domainText = sqlite3_column_text(stmt, 0),
                  let keyText = sqlite3_column_text(stmt, 1),
                  let domain = Domain(rawValue: String(cString: domainText))
            else { continue }
            ids.append(SeriesID(domain: domain, key: String(cString: keyText)))
        }
        return ids
    }

    // MARK: - Database setup

    /// `~/Library/Application Support/IDOTaskMaster/History.sqlite` —
    /// created (with intermediate directories) on first launch. Matches the
    /// standard per-app `Application Support` convention; unlike
    /// `SettingsStore`/`AlertsEngine`'s `UserDefaults`-backed preferences,
    /// this store's whole reason to exist is a size and query pattern
    /// `UserDefaults` was never designed for. Falls back to a temporary
    /// directory (never `nil`) only in the unlikely case `Application
    /// Support` itself can't be resolved — `openDatabase(at:)` still fails
    /// honestly afterward if even that path can't be opened for writing.
    private static func defaultDatabaseURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("IDOTaskMaster", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("History.sqlite")
    }

    /// Opens (creating if needed) the SQLite file at `url`, applies this
    /// store's pragmas, and ensures its one table/index exist.
    private static func openDatabase(at url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            if let handle {
                sqlite3_close(handle)
            }
            throw HistoryStoreError.openFailed(message)
        }

        // WAL + NORMAL synchronous: a background history recorder should
        // survive a crash without corrupting the file, but doesn't need
        // every single write `fsync`ed at FULL durability the way a
        // financial ledger would — losing the last few unflushed seconds of
        // 30-second-cadence samples on an unclean shutdown is an acceptable
        // trade for meaningfully less disk I/O over the app's lifetime.
        // Best-effort: a pragma failing doesn't stop this store from
        // working, just from getting its preferred journaling mode.
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)

        let schema = """
        CREATE TABLE IF NOT EXISTS history_points (
            resolution TEXT NOT NULL,
            domain TEXT NOT NULL,
            key TEXT NOT NULL,
            bucket_start REAL NOT NULL,
            avg_value REAL NOT NULL,
            min_value REAL NOT NULL,
            max_value REAL NOT NULL,
            sample_count INTEGER NOT NULL,
            PRIMARY KEY (resolution, domain, key, bucket_start)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS idx_history_points_lookup
            ON history_points (domain, key, resolution, bucket_start);
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw HistoryStoreError.sqlFailed(message)
        }

        return db
    }
}

/// Failure modes for opening `HistoryStore`'s database or running one of
/// its statements — see `HistoryStore.openError`/`lastError` for how these
/// surface as this store's own honest-degradation state rather than a
/// crash.
enum HistoryStoreError: Error, LocalizedError {
    case openFailed(String)
    case sqlFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "Could not open the history database: \(message)"
        case .sqlFailed(let message):
            return message
        }
    }
}
