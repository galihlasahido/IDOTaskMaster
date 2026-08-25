import Foundation
import MCP

/// `list_startup_items` and `list_services`.
enum StartupServicesHandlers {
    static func listStartupItems(registry: ProviderRegistry, arguments: [String: Value]?) async -> CallTool.Result {
        let filter = Args.string(arguments, "filter")?.lowercased()

        do {
            let catalog = try await registry.startup.sample()
            var items = catalog.items
            if let filter, !filter.isEmpty {
                items = items.filter { item in
                    item.displayName.lowercased().contains(filter)
                        || (item.programPath?.lowercased().contains(filter) ?? false)
                }
            }
            return jsonResult(ListStartupItemsResponse(
                generatedAt: catalog.generatedAt,
                totalMatched: items.count,
                items: items.map(StartupItemDTO.init)
            ))
        } catch {
            return errorResult("Failed to scan startup items: \(error.localizedDescription)")
        }
    }

    static func listServices(registry: ProviderRegistry, arguments: [String: Value]?) async -> CallTool.Result {
        let filter = Args.string(arguments, "filter")?.lowercased()

        do {
            let catalog = try await registry.services.sample()
            var items = catalog.items
            if let filter, !filter.isEmpty {
                items = items.filter { item in
                    item.label.lowercased().contains(filter)
                        || (item.programPath?.lowercased().contains(filter) ?? false)
                }
            }
            return jsonResult(ListServicesResponse(
                generatedAt: catalog.generatedAt,
                totalMatched: items.count,
                items: items.map(ServiceItemDTO.init)
            ))
        } catch {
            return errorResult("Failed to list services (launchctl print): \(error.localizedDescription)")
        }
    }
}
