import Foundation
import MCP

/// `list_alert_rules`. Reads `AlertsEngine.rules` right off the instance
/// `ProviderRegistry.make()` built (from the GUI app's own shared
/// `UserDefaults` suite) — never calls `.start()` on it, which would begin a
/// live 5-second sampling loop and notification delivery this read-only
/// server has no business running. Reading `@Published`/`@MainActor` state
/// needs a hop onto the main actor.
enum AlertsHandlers {
    static func listAlertRules(registry: ProviderRegistry) async -> CallTool.Result {
        let rules = await MainActor.run { registry.alerts.rules }
        return jsonResult(ListAlertRulesResponse(
            rules: rules.map(AlertRuleDTO.init),
            note: "Shows configured rules only. Fired-alert history is kept in-memory inside the running GUI app process and isn't accessible from this separate CLI process."
        ))
    }
}
