# IDOTaskMaster

A native macOS system monitor / task manager with **[name removed]'s feature depth**, presented in
**Activity Monitor's native visual language** — SF Pro, standard controls, subtle
filled-area graphs, correct light & dark appearance. No neon, no custom fonts, no
"Pro" upsells: every page is unlocked.

Built with SwiftUI + AppKit interop + Canvas drawing, reading live metrics straight from
`host_processor_info`, `vm_statistics64`, libproc, IOKit, and friends — no helper daemons,
no IPC. Providers that can't read a metric say **"Unavailable"** instead of guessing.

![Summary dashboard](docs/screenshots/summary.png)

## Features

**Live monitoring**
- **Summary** — dashboard with CPU/Temp/GPU capacity towers, a tabbed CPU Overview graph
  (Utilization / Temperature / Kernel), top CPU processes, memory utilization band, and a
  tile grid for Disks / Network / Energy / GPU / NPU / Thermals.
- **Performance** — master-detail page with a live sparkline rail (CPU, Memory, GPU, NPU,
  Disks, Network, Energy, Thermals) and rich per-domain detail: per-core CPU graphs, GPU
  Overall/Engines tabs, disk & network throughput, battery/power state, per-die thermal
  sensors.
- **Processes** and **Users** — grouped Applications/Background process tree with a full
  identity/lifetime/processor/memory/disk detail pane; per-user rollups.
- **System Info** — a `system_profiler`-style Hardware / Network / Software catalog with
  key-value detail and Reload.
- **Startup Apps** and **Services** — LaunchAgent/Daemon and `launchctl` listings with
  enable/disable and detail panes.

**Power-user tools** ([name removed]'s Pro pages — free here, no license required)
- **Power & Freq** — an HWiNFO-style live sensor tree (Value/Min/Max) for CPU/GPU/SSD.
- **Connections** — per-process socket table with exposure classification
  (loopback/LAN/Internet) and filter chips.
- **Installed Apps** — `/Applications` scan with sizes, related-files finder, and Uninstall.
- **Disk Space** — async scanner, bubble visualization, file-type legend, largest
  folders/files.
- **Benchmarks** — CPU (single/multi-core), GPU compute, Disk R/W, Internet down/up, plus
  an aggregate Score page with run history.

**Beyond [name removed]**
- Menu bar extra with a live compact readout and popover mini-dashboard (keeps collecting
  with the main window closed).
- Dock icon live graph.
- Alert rules (CPU/memory/disk/battery/new listening port thresholds) → native
  notifications.
- Persistent history (SQLite) with 24h/7d charts per domain.
- Per-process network traffic (Network Usage page).
- Extended process actions: suspend/resume, renice, kill tree, Open Files & Ports,
  code-signing status.
- ⌘K command palette, CSV/JSON export, one-click system snapshot report, battery health
  trend.

## Screenshots

| Performance | Processes |
|---|---|
| ![Performance](docs/screenshots/performance.png) | ![Processes](docs/screenshots/processes.png) |

| System Info | Benchmarks |
|---|---|
| ![System Info](docs/screenshots/systeminfo.png) | ![Benchmarks](docs/screenshots/benchmarks.png) |

## Requirements

- macOS 13.0 or later (Apple silicon is the primary target; Intel is best-effort).
- Xcode 15 or later to build.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) only if `IDOTaskMaster.xcodeproj`
  needs to be regenerated from `project.yml` (e.g. a fresh clone before the project file
  exists) — `brew install xcodegen`. The committed `.xcodeproj` is normally enough on its
  own.

## Building & running

All common tasks are one-line scripts in `scripts/` (see each file's header for details):

```sh
scripts/run.sh        # build (Debug) and launch, like a normal double-click
scripts/debug.sh       # build (Debug) and run under lldb — prints/NSLog stream here
scripts/build.sh       # just compile: scripts/build.sh [Debug|Release]
```

Or open `IDOTaskMaster.xcodeproj` in Xcode and hit Run — same target either way.

Some data (SMC sensors, other users' processes, full connection info) may be restricted
by macOS permissions; affected providers degrade gracefully instead of failing outright.

## Packaging for distribution

```sh
scripts/release.sh     # optimized Release build -> dist/IDOTaskMaster.app
scripts/dmg.sh          # -> dist/IDOTaskMaster-<version>.dmg (Finder drag-to-Applications)
scripts/pkg.sh          # -> dist/IDOTaskMaster-<version>.pkg (double-click installer)
```

`dmg.sh` and `pkg.sh` build a Release copy first if `dist/IDOTaskMaster.app` doesn't exist
yet. Builds are ad-hoc/unsigned by default, which is fine for running on the machine that
built them. To produce a properly signed build — required before notarizing or sharing
with another Mac under Gatekeeper — pass your Apple Developer Team ID:

```sh
DEVELOPMENT_TEAM=ABCDE12345 scripts/release.sh
INSTALLER_SIGN_IDENTITY="Developer ID Installer: Your Name (TEAMID)" scripts/pkg.sh
```

## Project structure

```
IDOTaskMaster/
├─ App/           # @main, window/menu/shortcut chrome, menu bar extra, Dock icon, settings
├─ Core/          # Sampler tick loop, Snapshot model, in-memory + SQLite history, alerts
├─ Providers/     # one type per metric domain (CPU, Memory, GPU, Disk, Network, …)
├─ Benchmarks/    # CPU/GPU/Disk/Internet benchmark runners
├─ Components/    # HistoryGraph, CapacityBar, DataTable, StatTile, DetailPane, Exporter…
├─ Pages/         # one SwiftUI view per sidebar page
└─ Theme/         # per-domain color tokens (macOS palette)
```

See [`../PLAN.md`](../PLAN.md) for the full product/architecture write-up and the
milestone-by-milestone progress checklist.

## Status

Feature-complete through M10 (all monitoring pages, power-user tools, alerts, history,
menu bar extra, and Dock icon are implemented). M11 (polish & release) is in progress —
see `PLAN.md` §4 for the current checklist.
