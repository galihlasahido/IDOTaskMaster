import Foundation

/// Drives `NetworkUsagePage`'s live data — polls `NetTrafficProvider` on a
/// fixed 1-second cadence and keeps a short combined-rate history per
/// direction for the stat tiles' sparklines.
///
/// Owned by `AppDelegate`, alongside `alertsEngine`/`historyStore`/
/// `menuBarStatus`, but **not** auto-started at launch the way those are —
/// `start()` only runs once the user explicitly asks for it, from
/// `NetworkUsagePage`'s "Not collecting network traffic yet" centered
/// button (matching `DiskSpacePage`'s own user-initiated "Start Scan"
/// shape, per the app's own convention that an expensive standing resource
/// — here, a continuously-running `nettop` subprocess sampling every
/// process on the Mac once a second — shouldn't start costing CPU before
/// the user has asked for what it's for). Once started, though, it keeps
/// running for the rest of the app's lifetime (not stopped in
/// `onDisappear`) rather than being torn down and warmed back up on every
/// page visit — `nettop -d`'s first logged block is always a
/// lifetime-totals baseline, not a delta (see `NetTrafficProvider`'s own
/// doc comment), so relaunching it fresh each time paid that warm-up cost
/// — worse on a Mac with hundreds of processes for `nettop -P` to walk —
/// on every single visit instead of just the first.
@MainActor
final class NetworkTrafficMonitor: ObservableObject {
    /// `true` once the user has clicked "Start Collecting" — before that,
    /// `NetworkUsagePage` shows its centered explanation + button instead
    /// of stat tiles/table that would otherwise just sit on "Unavailable"
    /// forever with no way to tell the user why.
    @Published private(set) var hasStarted = false
    @Published private(set) var snapshot: NetTrafficSnapshot?
    /// Set only for a genuine problem (`nettop` missing, wouldn't launch,
    /// or exited) — never for `NetTrafficProviderError
    /// .stillCollectingFirstSample`, which `isWarmingUp` below covers
    /// instead. Conflating the two used to mean `NetworkUsagePage` showed
    /// "Unavailable: Collecting the first traffic sample…" — worded and
    /// styled identically to a real failure — for however long that
    /// first-sample wait took, which read as "this app is broken" rather
    /// than "this is loading." Left in place alongside a still-populated
    /// `snapshot` after a single missed poll, matching
    /// `ConnectionsViewModel.unavailableReason`'s own rule.
    @Published private(set) var unavailableReason: String?
    /// `true` from `start()` until this provider's very first real block
    /// finishes — i.e. exactly the window `NetTrafficProviderError
    /// .stillCollectingFirstSample` covers. `NetworkUsagePage` reads this
    /// to show a friendly, unmistakably-a-loading-state message instead of
    /// folding it into `unavailableReason`. `false` (not `true`) until
    /// `start()` actually runs — before that there's nothing "warming
    /// up," collection simply hasn't been asked for yet (`hasStarted`
    /// above is what gates the page's own idle-vs-loading distinction).
    @Published private(set) var isWarmingUp = false
    /// Oldest-first combined-across-processes rate history, one entry per
    /// poll that produced a snapshot, capped at `historyLimit`. A `nil`
    /// entry marks a poll whose snapshot had no rate-bearing reading yet
    /// (`HistoryGraph`'s own "leave a gap, don't guess" convention).
    @Published private(set) var sendHistory: [Double?] = []
    @Published private(set) var receiveHistory: [Double?] = []

    /// `HistoryGraph`'s `valueRange` maps straight to pixel height with no
    /// auto-scaling of its own (see that type's doc comment) — its
    /// `0...100` default fits a percentage, not a byte rate that can run
    /// from zero to tens of megabytes/sec, so both sparkline tiles share
    /// this dynamically-sized range instead. Same "`0...max(peak, 1)`"
    /// shape `PerformancePage.PerformanceViewModel.dynamicRange(for:)`
    /// uses for its own network graph, and shared across both tiles
    /// (rather than each scaling to its own peak) so their heights stay
    /// visually comparable.
    var combinedRateRange: ClosedRange<Double> {
        let peak = (sendHistory + receiveHistory).compactMap { $0 }.max() ?? 0
        return 0...max(peak, 1)
    }

    private let provider = NetTrafficProvider()
    private var pollTask: Task<Void, Never>?
    private static let pollInterval: TimeInterval = 1.0
    private static let historyLimit = 60

    func start() {
        guard pollTask == nil else { return }
        hasStarted = true
        isWarmingUp = true
        let provider = provider
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let result = try await provider.sample()
                    guard let self, !Task.isCancelled else { return }
                    self.snapshot = result
                    self.unavailableReason = nil
                    self.isWarmingUp = false
                    self.appendHistory(result)
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    if case NetTrafficProviderError.stillCollectingFirstSample = error {
                        self.isWarmingUp = true
                        self.unavailableReason = nil
                    } else {
                        self.isWarmingUp = false
                        self.unavailableReason = error.localizedDescription
                    }
                }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            }
        }
    }

    private func appendHistory(_ snapshot: NetTrafficSnapshot) {
        sendHistory.append(snapshot.totalSendBytesPerSecond)
        receiveHistory.append(snapshot.totalReceiveBytesPerSecond)
        if sendHistory.count > Self.historyLimit {
            sendHistory.removeFirst(sendHistory.count - Self.historyLimit)
        }
        if receiveHistory.count > Self.historyLimit {
            receiveHistory.removeFirst(receiveHistory.count - Self.historyLimit)
        }
    }
}
