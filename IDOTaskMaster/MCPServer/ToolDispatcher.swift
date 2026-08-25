import MCP

/// Routes one `tools/call` request to the matching handler in
/// `Handlers/*.swift` — the `CallTool` method handler registered in
/// `main.swift` delegates here so that registration site stays a short,
/// readable switch rather than growing every handler's body inline.
enum ToolDispatcher {
    static func dispatch(name: String, arguments: [String: Value]?, registry: ProviderRegistry) async -> CallTool.Result {
        switch name {
        case "get_summary":
            return await SummaryHandler.handle(registry: registry)
        case "list_processes":
            return await ProcessHandlers.listProcesses(registry: registry, arguments: arguments)
        case "get_top_processes":
            return await ProcessHandlers.getTopProcesses(registry: registry, arguments: arguments)
        case "get_process_detail":
            return await ProcessHandlers.getProcessDetail(registry: registry, arguments: arguments)
        case "get_system_info":
            return await SystemInfoHandlers.getSystemInfo(registry: registry, arguments: arguments)
        case "list_startup_items":
            return await StartupServicesHandlers.listStartupItems(registry: registry, arguments: arguments)
        case "list_services":
            return await StartupServicesHandlers.listServices(registry: registry, arguments: arguments)
        case "list_connections":
            return await ConnectionsHandlers.listConnections(registry: registry, arguments: arguments)
        case "list_installed_apps":
            return await InstalledAppsHandlers.listInstalledApps(registry: registry, arguments: arguments)
        case "list_history_series":
            return await HistoryHandlers.listHistorySeries(registry: registry)
        case "query_history":
            return await HistoryHandlers.queryHistory(registry: registry, arguments: arguments)
        case "list_alert_rules":
            return await AlertsHandlers.listAlertRules(registry: registry)
        default:
            return errorResult("Unknown tool: \(name)")
        }
    }
}
