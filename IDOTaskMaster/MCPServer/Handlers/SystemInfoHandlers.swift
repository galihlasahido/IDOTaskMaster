import Foundation
import MCP

/// `get_system_info`.
enum SystemInfoHandlers {
    static func getSystemInfo(registry: ProviderRegistry, arguments: [String: Value]?) async -> CallTool.Result {
        let section = Args.string(arguments, "section")?.lowercased()
        let filter = Args.string(arguments, "filter")?.lowercased()

        do {
            let catalog = try await registry.systemInfo.sample()
            var categories = catalog.categories
            if let section {
                categories = categories.filter { $0.id.lowercased() == section }
            }
            if let filter, !filter.isEmpty {
                categories = categories.compactMap { category -> SystemInfoCategory? in
                    let items = category.items.filter { item in
                        if item.name.lowercased().contains(filter) { return true }
                        return item.groups.contains { group in
                            group.fields.contains { field in
                                field.label.lowercased().contains(filter) || field.value.lowercased().contains(filter)
                            }
                        }
                    }
                    guard !items.isEmpty else { return nil }
                    return SystemInfoCategory(id: category.id, title: category.title, systemImage: category.systemImage, items: items)
                }
            }

            return jsonResult(SystemInfoResponse(
                generatedAt: catalog.generatedAt,
                categories: categories.map(SystemInfoCategoryDTO.init)
            ))
        } catch {
            return errorResult("Failed to read system info (system_profiler): \(error.localizedDescription)")
        }
    }
}
