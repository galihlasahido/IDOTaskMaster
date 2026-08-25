import Foundation
import MCP

/// `list_history_series` and `query_history`. Both simply query
/// `ProviderRegistry.history` — never call `.start()` on it (see that
/// property's own doc comment) — and degrade to an empty result rather than
/// an error when the GUI app has never run and the database doesn't exist
/// yet, matching `HistoryStore`'s own "no open database, no-op" behavior.
enum HistoryHandlers {
    static func listHistorySeries(registry: ProviderRegistry) async -> CallTool.Result {
        let ids = await registry.history.distinctSeries()
        return jsonResult(ListHistorySeriesResponse(series: ids.map(HistorySeriesIDDTO.init)))
    }

    static func queryHistory(registry: ProviderRegistry, arguments: [String: Value]?) async -> CallTool.Result {
        guard let domainText = Args.string(arguments, "domain"),
              let domain = HistoryStore.Domain(rawValue: domainText)
        else {
            let validDomains = HistoryStore.Domain.allCases.map(\.rawValue).joined(separator: ", ")
            return errorResult("Missing or invalid required argument \"domain\". Expected one of: \(validDomains).")
        }
        guard let key = Args.string(arguments, "key"), !key.isEmpty else {
            return errorResult("Missing required argument \"key\". Call list_history_series to see valid (domain, key) pairs.")
        }
        let rangeText = Args.string(arguments, "range") ?? "24h"
        let range: HistoryStore.Range
        switch rangeText {
        case "24h": range = .last24Hours
        case "7d": range = .last7Days
        default:
            return errorResult("Invalid \"range\" argument \"\(rangeText)\". Expected \"24h\" or \"7d\".")
        }

        let points = await registry.history.series(domain: domain, key: key, range: range)
        return jsonResult(QueryHistoryResponse(
            domain: domain.rawValue,
            key: key,
            range: rangeText,
            points: points.map(HistorySeriesPointDTO.init)
        ))
    }
}
