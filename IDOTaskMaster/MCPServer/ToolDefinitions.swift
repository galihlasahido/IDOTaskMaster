import MCP

/// Every tool this server exposes, with a JSON Schema `inputSchema` and a
/// description honest about units and known limitations — read by the
/// `ListTools` handler in `main.swift`. Implementations live in
/// `Handlers/*.swift`, dispatched by name in `ToolDispatcher.swift`.
///
/// Every tool here is **read-only**: none of them kill/suspend/renice a
/// process, run a benchmark, toggle a startup item, uninstall an app, or
/// otherwise mutate system or app state — this server only ever calls a
/// provider's `sample()`/query methods, never one of its write methods
/// (`StartupProvider.setEnabled`, `InstalledAppsProvider.uninstall`, ...).
enum ToolDefinitions {
    static let all: [Tool] = [
        Tool(
            name: "get_summary",
            description: """
            One-shot snapshot of live system state: CPU/memory/GPU/disk/network/energy/\
            thermal/NPU utilization plus the current process count. Mirrors the GUI \
            app's Summary dashboard. Percentages are 0-100; byte-rate fields are \
            bytes/second; cumulative byte fields are totals since boot. Any domain this \
            Mac can't read this call (rare) comes back null with its reason under \
            `errors`, rather than failing the whole response.
            """,
            inputSchema: Schema.object(properties: [:])
        ),
        Tool(
            name: "list_processes",
            description: """
            Lists running processes (flattened from the Applications/Background tree), \
            with identity, lifetime, CPU/memory/disk-I/O readings. Excludes icon data. \
            `cpuPercent` follows `top`'s convention: not divided by core count, so a \
            process fully busy across two cores reads ~200%.
            """,
            inputSchema: Schema.object(properties: [
                "filter": Schema.string("Case-insensitive substring match against process name or owning username. Omit to list every process."),
                "limit": Schema.integer("Maximum rows to return, applied after filtering. Default 50."),
            ])
        ),
        Tool(
            name: "get_top_processes",
            description: """
            The Summary dashboard's "Top CPU processes" table: PID, name, CPU%, memory, \
            sorted by CPU usage descending. A narrower, cheaper read than list_processes \
            — no tree structure, no per-process disk I/O. `gpuPercent` is always null: \
            no public macOS API exposes per-process GPU utilization.
            """,
            inputSchema: Schema.object(properties: [
                "limit": Schema.integer("Maximum rows to return. Default 12.")
            ])
        ),
        Tool(
            name: "get_process_detail",
            description: """
            Full detail for one process by PID: identity/lifetime/CPU/memory/disk-I/O \
            (same fields as list_processes), plus code-signing status (signed/unsigned/\
            ad-hoc/notarized, team ID) and its open files & sockets (lsof-style). \
            Excludes icon data. If the pid has already exited, `process`/`processError` \
            (or `openFiles`/`openFilesError`) reports that honestly rather than \
            returning stale data.
            """,
            inputSchema: Schema.object(
                properties: ["pid": Schema.integer("Process ID to inspect.")],
                required: ["pid"]
            )
        ),
        Tool(
            name: "get_system_info",
            description: """
            The System Info page's Hardware/Network/Software catalog (`system_profiler \
            -json` under the hood) — chip, memory, serial number, network interfaces, \
            OS version, and similar key-value facts about this Mac. Can take a few \
            seconds since it shells out to system_profiler; not something to call \
            repeatedly.
            """,
            inputSchema: Schema.object(properties: [
                "section": Schema.string(
                    "Restrict to one top-level section. Omit for all three.",
                    enumValues: ["hardware", "network", "software"]
                ),
                "filter": Schema.string("Case-insensitive substring match against an item's name or any field's label/value."),
            ])
        ),
        Tool(
            name: "list_startup_items",
            description: """
            LaunchAgents/LaunchDaemons discovered on disk (user, global, and Apple's own \
            System domains), each with its live launchctl enabled/running state. \
            `isRunning` is null for jobs outside this process's own per-user domain — an \
            unprivileged process can't reliably see every domain's running state.
            """,
            inputSchema: Schema.object(properties: [
                "filter": Schema.string("Case-insensitive substring match against the item's display name or program path.")
            ])
        ),
        Tool(
            name: "list_services",
            description: """
            Every job `launchctl print` currently knows about in the system and this \
            user's GUI domains — the live, running-now counterpart to \
            list_startup_items' on-disk configured listing (this one also includes jobs \
            with no on-disk plist at all, e.g. ad hoc XPC services).
            """,
            inputSchema: Schema.object(properties: [
                "filter": Schema.string("Case-insensitive substring match against the job's label or program path.")
            ])
        ),
        Tool(
            name: "list_connections",
            description: """
            Every process's open network sockets (TCP/UDP/Unix-domain), with exposure \
            classification (loopback/LAN/internet). Falls back to lsof automatically if \
            the native per-process scan is unavailable system-wide — check \
            `usedFallback` if that matters to you.
            """,
            inputSchema: Schema.object(properties: [
                "filter": Schema.string(
                    "all: every socket. listening: TCP sockets in LISTEN state or peer-less bound UDP sockets. public: sockets exposed to the internet (not loopback/LAN). udp: UDP sockets only. Default all.",
                    enumValues: ["all", "listening", "public", "udp"]
                )
            ])
        ),
        Tool(
            name: "list_installed_apps",
            description: """
            Scans /Applications (one level deep) for .app bundles: name, bundle ID, \
            version, publisher (code-signing authority), and on-disk size. Excludes icon \
            data. Sizing every bundle with `du` means this can take a few seconds on a \
            Mac with many large apps.
            """,
            inputSchema: Schema.object(properties: [
                "filter": Schema.string("Case-insensitive substring match against the app's name or bundle identifier.")
            ])
        ),
        Tool(
            name: "list_history_series",
            description: """
            Lists every (domain, key) time series this Mac's persistent history database \
            has ever recorded — e.g. (cpu, total), (memory, usedPercent) — so you know \
            what to pass to query_history. Reads the SAME SQLite database \
            (~/Library/Application Support/IDOTaskMaster/History.sqlite) the GUI app \
            writes to every 30 seconds; requires the GUI app to have run at least once, \
            otherwise this returns an empty list rather than an error.
            """,
            inputSchema: Schema.object(properties: [:])
        ),
        Tool(
            name: "query_history",
            description: """
            Time-series history for one (domain, key) pair over the last 24 hours or 7 \
            days — downsampled with average/min/max per bucket the further back in time \
            you go. Call list_history_series first to see what's actually recorded. \
            Requires the GUI app to have run at least once; otherwise returns an empty \
            `points` array rather than an error.
            """,
            inputSchema: Schema.object(
                properties: [
                    "domain": Schema.string(
                        "Metric domain.",
                        enumValues: ["cpu", "memory", "gpu", "disk", "network", "energy", "thermal", "npu"]
                    ),
                    "key": Schema.string("Series key within the domain, e.g. \"total\" for cpu or \"usedPercent\" for memory — see list_history_series."),
                    "range": Schema.string("Lookback window. Default 24h.", enumValues: ["24h", "7d"]),
                ],
                required: ["domain", "key"]
            )
        ),
        Tool(
            name: "list_alert_rules",
            description: """
            The user's configured alert rules (CPU/memory-pressure/disk/battery \
            thresholds, new-public-port detection) from the GUI app's Alerts page, \
            including whether each is enabled and its condition in plain language. Shows \
            configured rules only — fired-alert history lives in the running GUI app \
            process's memory and isn't reachable from this separate CLI process.
            """,
            inputSchema: Schema.object(properties: [:])
        ),
    ]
}
