import Foundation
import MCP

/// `list_installed_apps`.
enum InstalledAppsHandlers {
    static func listInstalledApps(registry: ProviderRegistry, arguments: [String: Value]?) async -> CallTool.Result {
        let filter = Args.string(arguments, "filter")?.lowercased()

        do {
            let catalog = try await registry.installedApps.sample()
            var apps = catalog.apps
            if let filter, !filter.isEmpty {
                apps = apps.filter { app in
                    app.name.lowercased().contains(filter)
                        || (app.bundleIdentifier?.lowercased().contains(filter) ?? false)
                }
            }
            return jsonResult(ListInstalledAppsResponse(
                generatedAt: catalog.generatedAt,
                totalMatched: apps.count,
                apps: apps.map(InstalledAppDTO.init)
            ))
        } catch {
            return errorResult("Failed to scan /Applications: \(error.localizedDescription)")
        }
    }
}
