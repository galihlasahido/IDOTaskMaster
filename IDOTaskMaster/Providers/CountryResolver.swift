import Foundation

/// Best-effort "which country is this IP in" lookup, cached forever per IP
/// for the life of the process — `NetworkMonitorPage`'s opt-in country
/// display. Unlike `HostnameResolver` (the OS's own DNS resolver — no new
/// network dependency, just asking the resolver every app already uses),
/// this genuinely sends the destination IP to a public geolocation API
/// (`ipwho.is`, over HTTPS) — a real, new outbound network request this
/// app wouldn't otherwise make. That's a deliberate exception to this
/// app's usual "no hidden network requests" rule, which is exactly why
/// it's off by default and only ever starts once the user explicitly
/// turns it on in `NetworkMonitorPage`'s toolbar — never silently. The
/// destination IP is the only thing sent; nothing about this Mac or its
/// user goes with it.
actor CountryResolver {
    static let shared = CountryResolver()

    struct CountryInfo: Sendable, Equatable {
        let countryCode: String
        let countryName: String
        let flagEmoji: String?
    }

    /// `nil` means "looked up, no result" — distinct from a missing key
    /// ("never looked up"), same "don't retry a permanent miss every tick"
    /// reasoning as `HostnameResolver.cache`.
    private var cache: [String: CountryInfo?] = [:]
    private var pending: Set<String> = []

    func cachedCountry(for ip: String) -> CountryInfo? {
        cache[ip] ?? nil
    }

    /// Starts a lookup for `ip` unless it's already cached, in flight, or
    /// obviously not worth asking about (a private/loopback address —
    /// see `isPubliclyRoutable`). Fire-and-forget, same polling-cadence
    /// convention as `HostnameResolver.resolve(_:)`.
    func resolve(_ ip: String) {
        guard cache[ip] == nil, !pending.contains(ip), Self.isPubliclyRoutable(ip) else { return }
        pending.insert(ip)
        Task.detached(priority: .utility) { [weak self] in
            let info = await Self.lookup(ip)
            await self?.store(ip: ip, info: info)
        }
    }

    private func store(ip: String, info: CountryInfo?) {
        cache[ip] = info
        pending.remove(ip)
    }

    /// Skips loopback and private (RFC 1918) LAN addresses — asking a
    /// public API "what country is 192.168.1.5 in" is nonsensical and
    /// would just waste a request and a cache slot.
    private static func isPubliclyRoutable(_ ip: String) -> Bool {
        if ip == "::1" || ip.hasPrefix("127.") || ip.hasPrefix("192.168.") || ip.hasPrefix("10.") { return false }
        if ip.hasPrefix("172.") {
            let parts = ip.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) { return false }
        }
        return true
    }

    private static func lookup(_ ip: String) async -> CountryInfo? {
        guard let url = URL(string: "https://ipwho.is/\(ip)?fields=success,country,country_code,flag") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["success"] as? Bool == true,
              let countryCode = json["country_code"] as? String,
              let countryName = json["country"] as? String
        else { return nil }
        let flag = (json["flag"] as? [String: Any])?["emoji"] as? String
        return CountryInfo(countryCode: countryCode, countryName: countryName, flagEmoji: flag)
    }
}
