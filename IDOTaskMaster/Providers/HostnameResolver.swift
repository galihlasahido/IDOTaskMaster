import Foundation

/// Best-effort reverse-DNS hostname for a remote IP, cached forever per IP
/// for the life of the process — `NetworkMonitorPage`'s Little Snitch-style
/// "which server" display (a hostname like "e6858.dscx.akamaiedge.net")
/// instead of a bare IP address. Uses `Host(address:).names`, the same
/// system resolver mechanism `host`/`dig -x` use locally: no new
/// entitlement, no external service beyond the ordinary DNS queries any
/// app already makes when it connects somewhere — this doesn't send
/// anything new anywhere, it just asks the OS's own resolver "what name
/// goes with this IP I'm already seeing."
///
/// An `actor` so concurrent `resolve(_:)` calls (one per socket poll tick,
/// potentially from a fast-moving `ConnectionsCatalog`) can't race on
/// `cache`/`pending`.
actor HostnameResolver {
    static let shared = HostnameResolver()

    /// `nil` means "looked up, no name found" — distinct from a missing
    /// key, which means "never looked up." Both render the same way to a
    /// caller (show the raw IP), but keeping them distinct means a failed
    /// lookup is never retried every single poll tick.
    private var cache: [String: String?] = [:]
    private var pending: Set<String> = []

    /// The cached hostname for `ip` — `nil` if it's never been resolved,
    /// resolution is still in flight, or it genuinely has no reverse DNS
    /// entry. Callers show the raw IP in every `nil` case, matching this
    /// app's honest-degradation convention.
    func cachedHostname(for ip: String) -> String? {
        cache[ip] ?? nil
    }

    /// Starts a background resolution for `ip` unless it's already
    /// cached or already in flight. Fire-and-forget: a caller polling on
    /// its own cadence (like `NetworkMonitorViewModel`) just re-reads
    /// `cachedHostname(for:)` on its next tick once this finishes.
    func resolve(_ ip: String) {
        guard cache[ip] == nil, !pending.contains(ip) else { return }
        pending.insert(ip)
        Task.detached(priority: .utility) { [weak self] in
            let hostname = Self.reverseLookup(ip)
            await self?.store(ip: ip, hostname: hostname)
        }
    }

    private func store(ip: String, hostname: String?) {
        cache[ip] = hostname
        pending.remove(ip)
    }

    /// Blocks the calling thread while the resolver does its work — always
    /// called from `Task.detached`, never from an actor-isolated context,
    /// so that's fine. `Host.names` can return the numeric address back
    /// unchanged when it has no real name for it, which reads exactly like
    /// "no hostname" for this app's purposes.
    private static func reverseLookup(_ ip: String) -> String? {
        let names = Host(address: ip).names
        guard let name = names.first(where: { $0 != ip }) else { return nil }
        return name
    }
}
