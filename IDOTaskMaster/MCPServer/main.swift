import Foundation
import MCP

// IDOTaskMasterMCP — a standalone, read-only MCP (Model Context Protocol)
// server exposing this Mac's live system-monitoring data (the same data
// IDOTaskMaster's GUI app collects, via the shared `Core/`/`Providers/`
// sources) over stdio to any MCP client (Claude Code, Claude Desktop, ...).
//
// This server never mutates system or app state: every tool in
// `ToolDefinitions.all` maps to a `sample()`/query call, never a write
// method (kill/suspend/renice a process, run a benchmark, toggle a startup
// item, uninstall an app). See `ProviderRegistry`/`Handlers/*.swift`.

let registry = await ProviderRegistry.make()

let server = Server(
    name: "idotaskmaster",
    version: "1.0.0",
    instructions: """
    Read-only access to this Mac's live system-monitoring data — CPU, memory, GPU, \
    disk, network, energy, thermal, and NPU utilization; running processes; startup \
    items and services; network connections; installed applications; persistent \
    history; and configured alert rules. Every tool here only reads state — none of \
    them can kill a process, change a setting, or otherwise modify this Mac.
    """,
    capabilities: .init(tools: .init(listChanged: false))
)

await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: ToolDefinitions.all)
}

await server.withMethodHandler(CallTool.self) { params in
    await ToolDispatcher.dispatch(name: params.name, arguments: params.arguments, registry: registry)
}

let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
