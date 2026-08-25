import Foundation

/// Drives `NetworkUsagePage`'s live data — polls `NetTrafficProvider` on a
/// fixed 1-second cadence and keeps a short combined-rate history per
/// direction for the stat tiles' sparklines.
///
/// Owned by `AppDelegate` and started once at launch, alongside
/// `alertsEngine`/`historyStore`/`menuBarStatus` — **not** a per-page
/// `@StateObject` started in `onAppear`/stopped in `onDisappear` the way
/// this type used to be (`NetworkUsageViewModel`). That per-page lifetime
/// meant the backing `nettop` subprocess was killed every time the user
/// navigated away from Network Usage and relaunched from zero every time
/// they came back — paying `nettop -d`'s "first block is a lifetime-totals
/// baseline, not a delta" warm-up cost (which, per that provider's own doc
/// comment, can take much longer than one `-s 1` interval on a Mac with
/// hundreds of processes for `nettop -P` to walk) on *every single visit*,
/// not just once per app launch. Making this app-lifetime means that cost
/// is paid at most once, before the user has necessarily even opened the
/// page.
@MainActor
final class NetworkTrafficMonitor: ObservableObject {
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
    /// folding it into `unavailableReason`.
    @Published private(set) var isWarmingUp = true
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
