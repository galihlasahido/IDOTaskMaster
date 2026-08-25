import Foundation
import MCP

/// `list_connections`.
enum ConnectionsHandlers {
    static func listConnections(registry: ProviderRegistry, arguments: [String: Value]?) async -> CallTool.Result {
        let filter = (Args.string(arguments, "filter") ?? "all").lowercased()

        do {
            let catalog = try await registry.connections.sample()
            let sockets: [ConnectionSocket]
            switch filter {
            case "listening":
                sockets = catalog.sockets.filter(\.isListening)
            case "public":
                sockets = catalog.sockets.filter { $0.exposure == .internet }
            case "udp":
                sockets = catalog.sockets.filter { $0.transport == .udp }
            default:
                sockets = catalog.sockets
            }

            return jsonResult(ListConnectionsResponse(
                generatedAt: catalog.generatedAt,
                usedFallback: catalog.usedFallback,
                scannedProcessCount: catalog.scannedProcessCount,
                totalMatched: sockets.count,
                sockets: sockets.map(ConnectionSocketDTO.init)
            ))
        } catch {
            return errorResult("Failed to list connections: \(error.localizedDescription)")
        }
    }
}
