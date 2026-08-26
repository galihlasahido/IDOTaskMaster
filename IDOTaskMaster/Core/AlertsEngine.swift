import Combine
import Foundation
import UserNotifications

/// User-defined threshold rules → `UserNotifications` — PLAN.md §3's
/// `Core/AlertsEngine.swift` and §4 M9's first task: "user-defined
/// threshold rules (CPU > x% for N min, memory pressure, low disk, low
/// battery, new public listening port) → UserNotifications; rule editor
/// UI." One of this app's own additions beyond the baseline feature set
/// (PLAN.md §2, M8–M10) — most comparable system monitors have no
/// alerting at all.
///
/// Owned once, at the process's lifetime, the same way `AppDelegate` owns
/// `menuBarStatus`/`dockIconRenderer` (M8): a watchdog is only useful if it
/// keeps evaluating rules while the main window is closed, so `start()` is
/// called exactly once from `AppDelegate.applicationDidFinishLaunching`,
/// never from a page's `onAppear`/`onDisappear` — `AlertsPage` (M9) only
/// reads and edits this engine's already-running state, it doesn't own its
/// lifecycle.
///
/// Two independent live sources feed rule evaluation, each on its own
/// cadence:
/// - A private `Sampler` at a slow, watchdog-appropriate 5-second interval
///   (PLAN.md §2's "lowest idle overhead (a monitor must not be the
///   load)" applies doubly here — this sampler runs for the app's entire
///   lifetime, like `MenuBarStatusModel`'s) drives the CPU/memory
///   pressure/disk/battery rules straight off `Snapshot`, the same fields
///   `Performance`/`Summary` already read.
/// - `ConnectionsProvider`, polled on a much slower fixed cadence (see
///   `pollConnectionsForNewPublicPorts`'s doc comment) — the same "not
///   wired into `Sampler`'s tick, heavier than any single domain" reason
///   `ConnectionsPage`'s own view model polls it directly — drives the
///   "new public listening port" rule by diffing this poll's public
///   listening sockets against the previous one's.
///
/// Rules are persisted as JSON in `UserDefaults` (`AlertRule` is
/// `Codable`) so they survive a relaunch; fired-alert history is kept
/// in-memory only, capped at `firedAlertsCapacity` — this app's `M9.2`
/// `HistoryStore` is the durable, cross-domain persistence layer, not this
/// engine's job to duplicate.
@MainActor
final class AlertsEngine: ObservableObject {
    static let providerID = "alerts"

    private static let rulesDefaultsKey = "alertsEngine.rules"
    private static let firedAlertsCapacity = 200
    /// Every 5 seconds — frequent enough for a "CPU above X% for N
    /// minutes" rule to resolve its sustained window to within a few
    /// seconds' accuracy, far cheaper than `Sampler`'s own 2×/sec default
    /// for a background watchdog that never stops running.
    private static let sampleInterval: Sampler.Interval = .custom(5)
    /// How often the "new public listening port" rule re-scans every
    /// process's socket table — deliberately much slower than the
    /// wattage/CPU sampler above: `ConnectionsProvider.sample()` walks
    /// every pid's fd table (or shells out to `lsof`), the same cost
    /// `ConnectionsPage`'s own view model avoids paying every tick.
    private static let connectionsPollSeconds: UInt64 = 20

    /// The user's rule set, persisted to `UserDefaults` on every change
    /// (`didSet`, matching `SettingsStore`'s own persist-on-set
    /// convention). `private(set)` — `AlertsPage`/its rule editor mutate
    /// rules only through `addRule`/`updateRule`/`deleteRule`/
    /// `setEnabled`, never by writing this array directly, so this engine
    /// can keep its own per-rule tracking state (`cpuAboveSince`,
    /// `lastFiredAt`) in sync with whatever rules still exist.
    @Published private(set) var rules: [AlertRule] {
        didSet { persistRules() }
    }
    /// Most-recent-first log of every notification this engine has
    /// actually posted (plus test sends — see `sendTestNotification`),
    /// capped at `firedAlertsCapacity`. Backs `AlertsPage`'s "Recent
    /// Alerts" list — the only way to see a rule actually fired, short of
    /// checking Notification Center.
    @Published private(set) var firedAlerts: [FiredAlert] = []
    /// Mirrors `UNUserNotificationCenter`'s live authorization state so
    /// `AlertsPage` can show an honest "Notifications are turned off for
    /// IDOTaskMaster" banner instead of silently never firing anything —
    /// PLAN.md's honest-degradation rule applies to this engine's own
    /// delivery mechanism, not just provider readings.
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    /// When the background `Sampler` last evaluated the continuous rules
    /// (CPU/memory/disk/battery) — a live "still watching" heartbeat for
    /// `AlertsPage`'s status line.
    @Published private(set) var lastEvaluatedAt: Date?
    /// When the connections poll loop last completed a scan — `nil` until
    /// the first one finishes, or forever if no rule needs it (see
    /// `hasEnabledNewPortRule`).
    @Published private(set) var lastConnectionsPollAt: Date?
    /// Set when the most recent connections poll's `ConnectionsProvider
    /// .sample()` call itself threw — honest-degradation surface for the
    /// "new public listening port" rule specifically.
    @Published private(set) var lastConnectionsPollError: String?
    /// Incremented each time the user clicks a posted notification —
    /// `AppShell` observes this (via `onChange`) to switch to the Alerts
    /// page and bring the window forward. A counter rather than a `Bool`
    /// so `onChange` fires reliably even if two clicks land close
    /// together, with nothing to remember to reset.
    @Published private(set) var notificationClickSignal = 0

    private let defaults: UserDefaults
    private let sampler: Sampler
    private let connectionsProvider = ConnectionsProvider()
    private var hasStarted = false
    private var sampleStreamTask: Task<Void, Never>?
    private var connectionsPollTask: Task<Void, Never>?
    /// When each CPU rule's utilization first crossed its threshold and
    /// has stayed there ever since — cleared the moment a tick reads
    /// below threshold (or can't read CPU at all), so a brief dip resets
    /// the "sustained" window rather than banking partial credit.
    private var cpuAboveSince: [UUID: Date] = [:]
    /// When each rule last actually fired a notification — every rule's
    /// own cooldown (`AlertRule.cooldownMinutes`) is measured from here,
    /// so a condition that stays true doesn't renotify every tick.
    private var lastFiredAt: [UUID: Date] = [:]
    /// `"TCP:443"`-style keys for every publicly-exposed listening socket
    /// seen on the most recent connections poll. `nil` until the first
    /// poll completes — that first poll only seeds this set, it never
    /// fires (every port already open when the app launched isn't "new");
    /// see `evaluateNewPublicListeningPort`.
    private var knownPublicListenKeys: Set<String>?
    /// Every remote IP this Mac has been seen connecting *out* to, as of
    /// the most recent connections poll — the outbound counterpart of
    /// `knownPublicListenKeys`, same "`nil` until first poll, which only
    /// seeds it" rule; see `evaluateNewOutboundHost`.
    private var knownOutboundHosts: Set<String>?

    /// - Parameter defaults: The `UserDefaults` suite rules are persisted
    ///   to/loaded from. Defaults to `.standard`; tests should pass an
    ///   isolated suite, matching `SettingsStore`'s own `init`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.sampler = Sampler(interval: Self.sampleInterval)
        if let data = defaults.data(forKey: Self.rulesDefaultsKey),
           let decoded = try? JSONDecoder().decode([AlertRule].self, from: data) {
            rules = decoded
        } else {
            rules = Self.defaultRules
        }
    }

    // MARK: - Lifecycle

    /// Starts the background `Sampler` stream, the connections poll loop,
    /// and an initial notification-authorization request. Safe to call
    /// repeatedly (a no-op after the first call) — see this type's doc
    /// comment for why the only real caller is `AppDelegate
    /// .applicationDidFinishLaunching`.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        Task { [weak self] in
            await self?.requestNotificationAuthorizationIfNeeded()
        }

        let sampler = sampler
        sampleStreamTask = Task { [weak self] in
            await sampler.start()
            for await snapshot in sampler.stream() {
                guard let self else { return }
                self.evaluateContinuousRules(snapshot: snapshot)
            }
        }

        connectionsPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.hasEnabledConnectionsPollRule {
                    await self.pollConnections()
                }
                try? await Task.sleep(nanoseconds: Self.connectionsPollSeconds * 1_000_000_000)
            }
        }
    }

    /// Whether either connections-poll-backed rule kind has an enabled
    /// rule — gates the one shared `pollConnections()` call so a session
    /// with neither enabled never pays for a `ConnectionsProvider.sample()`
    /// walk it has nothing to do with.
    private var hasEnabledConnectionsPollRule: Bool {
        rules.contains { $0.isEnabled && ($0.kind == .newPublicListeningPort || $0.kind == .newOutboundHost) }
    }

    // MARK: - Rule editing (AlertsPage's rule editor UI)

    func addRule(_ rule: AlertRule) {
        rules.append(rule)
    }

    func updateRule(_ rule: AlertRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
    }

    func deleteRule(id: UUID) {
        rules.removeAll { $0.id == id }
        cpuAboveSince[id] = nil
        lastFiredAt[id] = nil
    }

    func setEnabled(_ enabled: Bool, forRuleID id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].isEnabled = enabled
        // A disabled rule's sustained-CPU window shouldn't keep counting
        // in the background and then fire the instant it's re-enabled.
        if !enabled { cpuAboveSince[id] = nil }
    }

    /// The last time `rule` actually fired a notification, for the rule
    /// table's "Last Fired" column and the detail pane. `nil` if it never
    /// has (this launch).
    func lastFiredDate(forRuleID id: UUID) -> Date? {
        lastFiredAt[id]
    }

    /// Posts an immediate notification for `rule`, bypassing its own
    /// condition and cooldown — `AlertsPage`'s "Send Test Notification"
    /// action, so a user can confirm delivery actually works (permission
    /// granted, Do Not Disturb aside) without waiting for the real
    /// condition to occur.
    func sendTestNotification(for rule: AlertRule) {
        let message = "Test notification for \u{201C}\(rule.name)\u{201D} \u{2014} \(rule.kind.conditionSummary)."
        postNotification(title: rule.name, body: message)
        runCommandIfConfigured(rule, message: message, severity: .warning, firedAt: Date())
        recordFired(FiredAlert(ruleID: rule.id, ruleName: rule.name, message: message, severity: .warning, firedAt: Date(), isTest: true))
    }

    // MARK: - Notification authorization

    /// Re-reads the live system authorization state — called from
    /// `AlertsPage.onAppear` so its banner reflects a permission change
    /// made in System Settings while the app was already running.
    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// Requests notification authorization once, the first time this
    /// engine ever starts on a given Mac (`.notDetermined`) — never
    /// re-prompts a user who already denied it; that's what Notification
    /// Center's own Settings pane is for.
    private func requestNotificationAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let current = await center.notificationSettings()
        authorizationStatus = current.authorizationStatus
        guard current.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        let updated = await center.notificationSettings()
        authorizationStatus = updated.authorizationStatus
    }

    // MARK: - Continuous rules (CPU / memory pressure / disk / battery)

    private func evaluateContinuousRules(snapshot: Snapshot) {
        lastEvaluatedAt = snapshot.timestamp
        for rule in rules where rule.isEnabled {
            switch rule.kind {
            case .cpuAbove(let percent, let sustainedMinutes):
                evaluateCPU(rule: rule, percent: percent, sustainedMinutes: sustainedMinutes, snapshot: snapshot)
            case .memoryPressureAtLeast(let level):
                evaluateMemoryPressure(rule: rule, threshold: level, snapshot: snapshot)
            case .lowDiskFreePercent(let percent):
                evaluateLowDisk(rule: rule, percent: percent, snapshot: snapshot)
            case .lowBatteryPercent(let percent):
                evaluateLowBattery(rule: rule, percent: percent, snapshot: snapshot)
            case .newPublicListeningPort, .newOutboundHost:
                continue // handled by `pollConnections` instead
            }
        }
    }

    private func evaluateCPU(rule: AlertRule, percent: Double, sustainedMinutes: Double, snapshot: Snapshot) {
        guard let total = snapshot.cpu?.totalUtilization, total >= percent else {
            cpuAboveSince[rule.id] = nil
            return
        }
        let since = cpuAboveSince[rule.id] ?? snapshot.timestamp
        cpuAboveSince[rule.id] = since
        guard snapshot.timestamp.timeIntervalSince(since) >= sustainedMinutes * 60 else { return }
        let message = "CPU has been above \(formatPercent(percent)) for \(formatMinutes(sustainedMinutes))"
            + " (currently \(String(format: "%.0f", total))%)."
        fire(rule: rule, message: message, severity: .warning, now: snapshot.timestamp)
    }

    private func evaluateMemoryPressure(rule: AlertRule, threshold: AlertMemoryPressureLevel, snapshot: Snapshot) {
        guard let pressure = snapshot.memory?.pressureLevel, meetsThreshold(pressure, threshold) else { return }
        let severity: AlertSeverity = pressure == .critical ? .critical : .warning
        fire(rule: rule, message: "Memory pressure is \(memoryPressureText(pressure)).", severity: severity, now: snapshot.timestamp)
    }

    private func meetsThreshold(_ level: MemoryPressureLevel, _ threshold: AlertMemoryPressureLevel) -> Bool {
        switch threshold {
        case .warning: return level == .warning || level == .critical
        case .critical: return level == .critical
        }
    }

    private func memoryPressureText(_ level: MemoryPressureLevel) -> String {
        switch level {
        case .normal: return "normal"
        case .warning: return "elevated"
        case .critical: return "critical"
        }
    }

    /// Reads the boot volume's free-space percentage (falling back to
    /// whichever volume `DiskProvider` listed first if none is flagged as
    /// the system volume — shouldn't happen on a real Mac, but an honest
    /// fallback beats silently never firing). Doesn't fire at all when
    /// capacity can't be read this tick, matching every other rule's
    /// "no data this tick, no false alarm" behavior.
    private func evaluateLowDisk(rule: AlertRule, percent: Double, snapshot: Snapshot) {
        guard let disk = snapshot.disk,
              let volume = disk.volumes.first(where: { $0.isSystemVolume }) ?? disk.volumes.first,
              let total = volume.totalBytes, let available = volume.availableBytes, total > 0
        else { return }
        let freePercent = Double(available) / Double(total) * 100
        guard freePercent <= percent else { return }
        let severity: AlertSeverity = freePercent <= percent / 2 ? .critical : .warning
        let name = volume.volumeName ?? "Startup disk"
        let message = "\(name) has \(String(format: "%.1f", freePercent))% free space remaining."
        fire(rule: rule, message: message, severity: severity, now: snapshot.timestamp)
    }

    /// Only considers firing while actually running on battery power
    /// (`EnergyPowerSource.batteryPower`) — a Mac plugged in and merely
    /// not yet topped back up from a previous discharge isn't the "about
    /// to run out" situation this rule exists to warn about.
    private func evaluateLowBattery(rule: AlertRule, percent: Double, snapshot: Snapshot) {
        guard let energy = snapshot.energy, energy.powerSource == .batteryPower,
              let level = energy.battery?.percent, level <= percent
        else { return }
        let severity: AlertSeverity = level <= percent / 2 ? .critical : .warning
        let message = "Battery is at \(Int(level.rounded()))% and not plugged in."
        fire(rule: rule, message: message, severity: severity, now: snapshot.timestamp)
    }

    // MARK: - Connections poll (new public listening port / new outbound host)

    /// One shared `ConnectionsProvider.sample()` call backing both
    /// connections-based rule kinds, gated by `hasEnabledConnectionsPollRule`
    /// — a session with only one of the two enabled still pays for just
    /// one walk of every process's fd table per poll, not two.
    private func pollConnections() async {
        do {
            let catalog = try await connectionsProvider.sample()
            lastConnectionsPollAt = Date()
            lastConnectionsPollError = nil

            if rules.contains(where: { $0.isEnabled && $0.kind == .newPublicListeningPort }) {
                evaluateNewPublicListeningPort(catalog: catalog)
            }
            if rules.contains(where: { $0.isEnabled && $0.kind == .newOutboundHost }) {
                evaluateNewOutboundHost(catalog: catalog)
            }
        } catch {
            lastConnectionsPollError = error.localizedDescription
        }
    }

    /// Diffs this poll's publicly-exposed listening sockets
    /// (`SocketExposure.internet`) against `knownPublicListenKeys` from
    /// the previous poll. The very first poll after launch only seeds
    /// that set — every port already open when the app started is
    /// pre-existing, not "new" — matching `ConnectionsProvider
    /// .cachedCatalog`'s own doc comment, which named exactly this rule
    /// as the reason that diff belongs on the live catalog rather than
    /// duplicated per-caller. Every newly-appeared port found in one poll
    /// is folded into a single notification (rather than one per port) so
    /// several ports opening in the same 20-second window doesn't spam
    /// several alerts, and so this rule's own per-rule cooldown (below)
    /// only ever needs to reason about one `fire()` call per poll.
    private func evaluateNewPublicListeningPort(catalog: ConnectionsCatalog) {
        let publicListening = catalog.sockets.filter { $0.isListening && $0.exposure == .internet }
        var currentByKey: [String: ConnectionSocket] = [:]
        for socket in publicListening {
            currentByKey[publicPortKey(socket)] = socket
        }
        defer { knownPublicListenKeys = Set(currentByKey.keys) }

        guard let known = knownPublicListenKeys else { return }
        let newKeys = Set(currentByKey.keys).subtracting(known)
        guard !newKeys.isEmpty else { return }

        let newSockets = newKeys.compactMap { currentByKey[$0] }
            .sorted { ($0.localPort ?? 0) < ($1.localPort ?? 0) }
        let message = newPortMessage(for: newSockets)
        let now = Date()
        for rule in rules where rule.isEnabled && rule.kind == .newPublicListeningPort {
            fire(rule: rule, message: message, severity: .warning, now: now)
        }
    }

    private func publicPortKey(_ socket: ConnectionSocket) -> String {
        "\(socket.transport.rawValue):\(socket.localPort ?? 0)"
    }

    /// Diffs this poll's outbound remote hosts (any socket with a
    /// `remoteAddress`, not just internet-exposed/listening ones — this
    /// rule is about connections *this Mac initiates*, the opposite
    /// direction from `evaluateNewPublicListeningPort`'s own inbound
    /// check) against `knownOutboundHosts` from the previous poll. Same
    /// "first poll only seeds the baseline, never fires" rule as the
    /// listening-port check. Keyed by remote IP alone (not IP+port+pid):
    /// the alert is "this Mac has never talked to this host before," not
    /// "this exact socket is new," which is what a user actually wants
    /// from a security-awareness rule like this one — must be turned on
    /// explicitly like every other rule (`AlertsEngine.defaultRules`
    /// seeds it disabled), since a freshly-enabled rule's first poll is
    /// establishing a baseline from whatever's already connected, not a
    /// signal that all of it is suspicious.
    private func evaluateNewOutboundHost(catalog: ConnectionsCatalog) {
        var currentByIP: [String: ConnectionSocket] = [:]
        for socket in catalog.sockets {
            guard let ip = socket.remoteAddress else { continue }
            currentByIP[ip] = socket
        }
        defer { knownOutboundHosts = Set(currentByIP.keys) }

        guard let known = knownOutboundHosts else { return }
        let newIPs = Set(currentByIP.keys).subtracting(known)
        guard !newIPs.isEmpty else { return }

        let newSockets = newIPs.compactMap { currentByIP[$0] }
            .sorted { ($0.processName ?? "") < ($1.processName ?? "") }
        let message = newOutboundHostMessage(for: newSockets)
        let now = Date()
        for rule in rules where rule.isEnabled && rule.kind == .newOutboundHost {
            fire(rule: rule, message: message, severity: .warning, now: now)
        }
    }

    private func newOutboundHostMessage(for sockets: [ConnectionSocket]) -> String {
        let descriptions = sockets.map { socket -> String in
            let processText = socket.processName ?? "pid \(socket.pid)"
            let hostText = socket.remoteAddress ?? "?"
            return "\(processText) \u{2192} \(hostText)"
        }
        if descriptions.count == 1 {
            return "New outbound connection: \(descriptions[0])."
        }
        return "\(descriptions.count) new outbound connections: \(descriptions.joined(separator: ", "))."
    }

    private func newPortMessage(for sockets: [ConnectionSocket]) -> String {
        let descriptions = sockets.map { socket -> String in
            let processText = socket.processName ?? "pid \(socket.pid)"
            let portText = socket.localPort.map(String.init) ?? "?"
            return "\(processText) on \(socket.transport.rawValue)/\(portText)"
        }
        if descriptions.count == 1 {
            return "New public listening port: \(descriptions[0])."
        }
        return "\(descriptions.count) new public listening ports: \(descriptions.joined(separator: ", "))."
    }

    // MARK: - Firing

    /// Every rule kind funnels through here: enforces `rule.cooldownMinutes`
    /// against `lastFiredAt`, then posts the notification and records it
    /// into `firedAlerts`. Centralizing the cooldown check here (rather
    /// than in each `evaluate*` method) is what makes a continuous
    /// condition — CPU staying above threshold for hours — renotify only
    /// once per cooldown window instead of every 5-second tick.
    private func fire(rule: AlertRule, message: String, severity: AlertSeverity, now: Date) {
        if let last = lastFiredAt[rule.id], now.timeIntervalSince(last) < rule.cooldownMinutes * 60 {
            return
        }
        lastFiredAt[rule.id] = now
        postNotification(title: rule.name, body: message)
        runCommandIfConfigured(rule, message: message, severity: severity, firedAt: now)
        recordFired(FiredAlert(ruleID: rule.id, ruleName: rule.name, message: message, severity: severity, firedAt: now))
    }

    private func recordFired(_ alert: FiredAlert) {
        firedAlerts.insert(alert, at: 0)
        if firedAlerts.count > Self.firedAlertsCapacity {
            firedAlerts.removeLast(firedAlerts.count - Self.firedAlertsCapacity)
        }
    }

    /// Posts one local `UNNotificationRequest` with a `nil` trigger — fire
    /// immediately, no repeat schedule; this engine's own `fire(rule
    /// :message:severity:now:)` cooldown is what paces repeats, not
    /// `UserNotifications`' own scheduling. `withCompletionHandler: nil`
    /// (rather than an async `add`, whose availability is less certain
    /// across every point release of this app's macOS 13.0 minimum
    /// target) — a failed post here is inherently best-effort with
    /// nothing actionable a caller could do about it beyond what
    /// `authorizationStatus` already surfaces.
    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// Runs `rule.commandToRun` (if any) through `/bin/zsh -c` — a no-op
    /// for the common case of no command configured. This is genuinely
    /// arbitrary code execution, unlike every other `Process` launch in
    /// this app (`du`, `codesign`, `launchctl`, ... — always a fixed
    /// executable with fixed or programmatically-built arguments, never a
    /// free-form string): what makes it safe here is that the command is
    /// authored by the same person running it, in a field they typed it
    /// into themselves — the same trust boundary as a shell alias or cron
    /// job they'd write by hand, not remote or untrusted input. Dispatched
    /// onto a background queue so a slow or hanging command can never
    /// stall `AlertsEngine`'s 5-second evaluation tick; output is
    /// discarded (`/dev/null`) the same "best-effort, nothing actionable
    /// beyond what's already surfaced" way `postNotification`'s own `nil`
    /// completion handler is. The rule's own name/message/severity/fire
    /// time ride along as environment variables so the command can act on
    /// *which* alert fired without needing its own copy of this engine's
    /// state.
    private func runCommandIfConfigured(_ rule: AlertRule, message: String, severity: AlertSeverity, firedAt: Date) {
        guard let command = rule.commandToRun?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else { return }

        var environment = ProcessInfo.processInfo.environment
        environment["IDOTASKMASTER_ALERT_NAME"] = rule.name
        environment["IDOTASKMASTER_ALERT_MESSAGE"] = message
        environment["IDOTASKMASTER_ALERT_SEVERITY"] = severity.rawValue
        environment["IDOTASKMASTER_ALERT_FIRED_AT"] = ISO8601DateFormatter().string(from: firedAt)

        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
    }

    /// Called by `AppDelegate`'s `UNUserNotificationCenterDelegate`
    /// conformance when the user clicks a posted notification — without a
    /// delegate registered at all, `UNUserNotificationCenter` silently
    /// drops the click with nothing to act on it, which is why clicking a
    /// fired alert used to do nothing.
    func handleNotificationClicked() {
        notificationClickSignal += 1
    }

    // MARK: - Persistence

    private func persistRules() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: Self.rulesDefaultsKey)
    }

    /// Seeded starter rules — present but disabled, so a fresh install
    /// shows a populated, self-explanatory rule table (PLAN.md's
    /// "rule editor UI") instead of an empty list, without ever posting a
    /// notification the user didn't explicitly opt into by enabling one.
    static let defaultRules: [AlertRule] = [
        AlertRule(name: "High CPU Usage", kind: .cpuAbove(percent: 90, sustainedMinutes: 5), isEnabled: false),
        AlertRule(name: "Critical Memory Pressure", kind: .memoryPressureAtLeast(level: .critical), isEnabled: false),
        AlertRule(name: "Low Disk Space", kind: .lowDiskFreePercent(percent: 10), isEnabled: false),
        AlertRule(name: "Low Battery", kind: .lowBatteryPercent(percent: 20), isEnabled: false),
        AlertRule(name: "New Public Listening Port", kind: .newPublicListeningPort, isEnabled: false),
        AlertRule(name: "New Outbound Host", kind: .newOutboundHost, isEnabled: false),
    ]
}

// MARK: - Rule model

/// One user-defined threshold rule — PLAN.md §4 M9's "user-defined
/// threshold rules ... → UserNotifications." `Codable` so `AlertsEngine`
/// can persist the whole array as one JSON blob in `UserDefaults`;
/// `Equatable` so `AlertsPage`'s rule editor can compare a draft against
/// the rule it started from.
struct AlertRule: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var kind: AlertRuleKind
    var isEnabled: Bool
    /// Minimum time between two notifications from this same rule —
    /// keeps a condition that stays true (CPU pegged for an hour) from
    /// renotifying every evaluation tick. Defaults to 15 minutes, a
    /// reasonable "don't nag" starting point a user can shorten or
    /// lengthen per rule.
    var cooldownMinutes: Double
    /// A shell command to run (via `/bin/zsh -c`) every time this rule
    /// fires, alongside the notification — `nil`/empty runs nothing.
    /// `Optional` rather than defaulting to `""` so a rule persisted
    /// before this field existed decodes as `nil` for free: synthesized
    /// `Decodable` treats a missing key on an `Optional` property as
    /// `nil` rather than a decode failure, so no custom `init(from:)` or
    /// schema migration is needed for this to be additive-safe.
    var commandToRun: String?

    init(
        id: UUID = UUID(),
        name: String,
        kind: AlertRuleKind,
        isEnabled: Bool = true,
        cooldownMinutes: Double = 15,
        commandToRun: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isEnabled = isEnabled
        self.cooldownMinutes = cooldownMinutes
        self.commandToRun = commandToRun
    }
}

/// The condition half of an `AlertRule` — PLAN.md's five named rule
/// kinds, each carrying whatever parameters that condition needs.
/// `Codable` synthesis (SE-0295) handles the associated values without
/// any hand-written `encode(to:)`/`init(from:)` here.
enum AlertRuleKind: Equatable, Codable {
    /// Fires once total CPU utilization has stayed at or above `percent`
    /// continuously for `sustainedMinutes`.
    case cpuAbove(percent: Double, sustainedMinutes: Double)
    /// Fires once `MemorySnapshot.pressureLevel` reaches at least `level`.
    case memoryPressureAtLeast(level: AlertMemoryPressureLevel)
    /// Fires once the boot volume's free space drops to or below
    /// `percent` of its total capacity.
    case lowDiskFreePercent(percent: Double)
    /// Fires once battery charge drops to or below `percent` while
    /// running on battery power (not plugged in).
    case lowBatteryPercent(percent: Double)
    /// Fires once a process starts listening on a port classified
    /// `SocketExposure.internet` (reachable from outside the LAN) that
    /// wasn't already listening on the previous connections poll.
    case newPublicListeningPort
    /// Fires once a process connects out to a remote host this Mac hasn't
    /// been seen talking to on any previous connections poll since this
    /// rule was last enabled.
    case newOutboundHost
}

/// Codable stand-in for `MemoryPressureLevel` restricted to the two
/// levels a rule can threshold on ("fires at warning or worse" / "fires
/// at critical only") — kept as this engine's own type rather than
/// extending `MemoryPressureLevel` with `Codable` itself, since that type
/// belongs to `MemoryProvider` and has no `.normal`-as-a-threshold case
/// that would make sense here (a rule thresholding on "normal" would fire
/// constantly).
enum AlertMemoryPressureLevel: String, Codable, CaseIterable, Identifiable {
    case warning
    case critical

    var id: String { rawValue }
    var displayName: String { self == .warning ? "Warning" : "Critical" }
}

/// How urgently `AlertsPage`'s "Recent Alerts" list should read a fired
/// alert — maps onto `Theme/StatusPalette.swift`'s shared `.warning`/
/// `.critical` tokens at the view layer (kept as a plain enum here, no
/// `Color`, so this Core file has no SwiftUI dependency — matching
/// `Sampler`/`Snapshot`/`ProviderProtocol`'s own Darwin/Foundation-only
/// imports).
enum AlertSeverity: String, Codable, Equatable {
    case warning
    case critical
}

/// One notification this engine actually posted (or, with `isTest: true`,
/// a manually-triggered test send) — `AlertsEngine.firedAlerts`' element
/// type. Not `Codable`/persisted: this is a live, in-memory log for
/// `AlertsPage`, not durable history (that's `HistoryStore`'s job, a
/// separate M9 task).
struct FiredAlert: Identifiable, Equatable {
    let id: UUID
    let ruleID: UUID
    let ruleName: String
    let message: String
    let severity: AlertSeverity
    let firedAt: Date
    let isTest: Bool

    init(ruleID: UUID, ruleName: String, message: String, severity: AlertSeverity, firedAt: Date, isTest: Bool = false) {
        self.id = UUID()
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.message = message
        self.severity = severity
        self.firedAt = firedAt
        self.isTest = isTest
    }
}

/// Which of the five rule shapes a rule is — drives `AlertsPage`'s "Add
/// Rule" picker and its per-kind editor fields. Kept separate from
/// `AlertRuleKind` itself (rather than a `switch` on the case with
/// associated values ignored) so the editor can hold "which kind is
/// selected" as its own piece of `@State` independent of that kind's
/// still-being-edited parameters.
enum AlertRuleKindTag: String, CaseIterable, Identifiable, Codable {
    case cpuAbove
    case memoryPressure
    case lowDisk
    case lowBattery
    case newPublicPort
    case newOutboundHost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpuAbove: return "CPU Usage"
        case .memoryPressure: return "Memory Pressure"
        case .lowDisk: return "Low Disk Space"
        case .lowBattery: return "Low Battery"
        case .newPublicPort: return "New Public Listening Port"
        case .newOutboundHost: return "New Outbound Host"
        }
    }

    var systemImage: String {
        switch self {
        case .cpuAbove: return "cpu"
        case .memoryPressure: return "memorychip"
        case .lowDisk: return "internaldrive"
        case .lowBattery: return "battery.25"
        case .newPublicPort: return "network"
        case .newOutboundHost: return "globe"
        }
    }
}

extension AlertRuleKind {
    var tag: AlertRuleKindTag {
        switch self {
        case .cpuAbove: return .cpuAbove
        case .memoryPressureAtLeast: return .memoryPressure
        case .lowDiskFreePercent: return .lowDisk
        case .lowBatteryPercent: return .lowBattery
        case .newPublicListeningPort: return .newPublicPort
        case .newOutboundHost: return .newOutboundHost
        }
    }

    /// Human-readable condition text for the rule table's "Condition"
    /// column and the detail pane — e.g. "CPU above 90% for 5 min".
    var conditionSummary: String {
        switch self {
        case .cpuAbove(let percent, let sustainedMinutes):
            return "CPU above \(formatPercent(percent)) for \(formatMinutes(sustainedMinutes))"
        case .memoryPressureAtLeast(let level):
            return "Memory pressure reaches \(level.displayName)"
        case .lowDiskFreePercent(let percent):
            return "Startup disk free space drops to \(formatPercent(percent)) or below"
        case .lowBatteryPercent(let percent):
            return "Battery drops to \(formatPercent(percent)) or below while unplugged"
        case .newPublicListeningPort:
            return "A process starts listening on a new public port"
        case .newOutboundHost:
            return "A process connects to a host it hasn\u{2019}t talked to before"
        }
    }
}

// MARK: - Shared formatting

private func formatPercent(_ value: Double) -> String {
    "\(Int(value.rounded()))%"
}

private func formatMinutes(_ value: Double) -> String {
    if value < 1 { return "\(Int((value * 60).rounded()))s" }
    if value == value.rounded() { return "\(Int(value)) min" }
    return String(format: "%.1f min", value)
}
