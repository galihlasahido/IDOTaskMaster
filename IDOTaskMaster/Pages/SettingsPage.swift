import AppKit
import SwiftUI

/// Settings window content — PLAN.md §1.1 "Settings" / §4 M8's "Settings
/// window (⌘,): appearance, update speed (mirrored in View menu), default
/// start page, graph history options, update check." Hosted in a native
/// `Settings` scene (`IDOTaskMasterApp`), which is what actually gives this
/// content the standard ⌘, shortcut and the App menu's "Settings…" item —
/// this view only supplies the tab content, not the window chrome around
/// it, matching every native macOS preferences window.
///
/// Five tabs mirror the researched Settings sections from PLAN.md §1.1
/// (Appearance, Graphs, General, Updates, Window), each trimmed to what
/// this milestone's tasks actually scope in. The first four cover M8's
/// first task ("appearance, update speed ..., default start page, graph
/// history options, update check"); the fifth, added by M8's second task,
/// covers that task's "Global shortcut Ctrl+Shift+Esc (login item),
/// always-on-top, hide-on-close." Rows PLAN.md §2 drops outright
/// (Language/Display font/Popout, the mono "Colors" popover) or that
/// belong to this same milestone's *other* tasks (menu bar extra, Dock
/// icon, remote connections) aren't here — adding them is that sibling
/// task's job, not this one's.
///
/// `TabView` on macOS renders each `.tabItem` as a toolbar segment above a
/// content pane that resizes per tab — the standard System-Settings-style
/// preferences window — with no custom chrome needed to get that look.
struct SettingsPage: View {
    var body: some View {
        TabView {
            AppearanceSettingsTab()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }

            GraphsSettingsTab()
                .tabItem { Label("Graphs", systemImage: "chart.xyaxis.line") }

            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }

            UpdatesSettingsTab()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }

            WindowSettingsTab()
                .tabItem { Label("Window", systemImage: "macwindow") }
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Appearance

/// PLAN.md §1.1's Appearance section, trimmed per `SettingsStore.AppTheme`
/// and `highFrequencyVisuals`'s own doc comments to the two rows this app
/// actually has a use for: theme and motion style.
private struct AppearanceSettingsTab: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Picker("Appearance", selection: $settings.appTheme) {
                ForEach(SettingsStore.AppTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)

            Toggle("High Frequency Visuals", isOn: $settings.highFrequencyVisuals)
            Text("Smoothly interpolates graphs between updates instead of redrawing only when new data arrives.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

// MARK: - Graphs

/// PLAN.md §1.1's Graphs section: "Color Keyed Graphs, Compress Older
/// History (+ history multiplier, e.g. 15× with smooth time compression),
/// Pixels per update." None of these three are read by any `HistoryGraph`
/// call site yet — see `SettingsStore`'s doc comments on
/// `colorKeyedGraphs`/`compressOlderHistory`/`pixelsPerUpdate` for why
/// declaring the preference now, ahead of the milestone that wires it into
/// the graphs themselves, is this app's established pattern (`updateSpeed`
/// took the same path from M0 to this milestone).
private struct GraphsSettingsTab: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Toggle("Color Keyed Graphs", isOn: $settings.colorKeyedGraphs)

            Toggle("Compress Older History", isOn: $settings.compressOlderHistory)

            if settings.compressOlderHistory {
                LabeledSlider(
                    label: "History Multiplier",
                    value: $settings.historyMultiplier,
                    range: 2...30,
                    suffix: "×"
                )
            }

            LabeledSlider(
                label: "Pixels per Update",
                value: $settings.pixelsPerUpdate,
                range: 1...8,
                suffix: ""
            )
        }
        .padding(20)
    }
}

/// One "label, slider, numeric readout" row shared by both Graphs sliders
/// so their layout stays identical.
private struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let suffix: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
            Slider(value: $value, in: range, step: 1)
            Text("\(Int(value))\(suffix)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

// MARK: - General

/// PLAN.md §1.1's General section, scoped to this task's two items: update
/// speed and default start page. ("show-in-reports" is a per-metric
/// toggle from the researched inventory with no "reports" feature in
/// this app to attach to, so it's dropped rather than faked.)
private struct GeneralSettingsTab: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Picker("Update Speed", selection: $settings.updateSpeed) {
                ForEach(SettingsStore.UpdateSpeed.allCases) { speed in
                    Text(speed.displayName).tag(speed)
                }
            }
            Text("Also set from the View menu (⌘1 Fast, ⌘2 Normal, ⌘3 Slow) — both change the same preference.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Default Start Page", selection: $settings.defaultStartPage) {
                ForEach(SidebarPage.allCases) { page in
                    Text(page.title).tag(page)
                }
            }
            Text("The page shown when the app launches.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

// MARK: - Updates

/// PLAN.md §1.1's Updates section, scoped to this task's "update check" —
/// now backed by a real source, `Core/UpdateChecker.swift`, which reads
/// this project's public GitHub Releases feed rather than a Sparkle
/// appcast. "Download & Install…" downloads the release's `.dmg` and
/// opens it (the same as double-clicking a Safari download), so the user
/// lands straight at the familiar drag-the-app-into-Applications window —
/// see that type's own doc comment for why this app still never installs
/// anything itself past that point.
private struct UpdatesSettingsTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var updateChecker: UpdateChecker

    var body: some View {
        Form {
            Toggle("Check for Updates on Launch", isOn: $settings.checkForUpdatesOnLaunch)

            HStack {
                Button(action: runCheck) {
                    if updateChecker.isChecking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Check for Updates Now")
                    }
                }
                .disabled(updateChecker.isChecking)

                if case .updateAvailable(_, let releaseURL, let dmgURL) = updateChecker.lastResult {
                    if let dmgURL {
                        Button(action: { downloadAndInstall(from: dmgURL) }) {
                            if updateChecker.downloadState == .downloading {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Download & Install…")
                            }
                        }
                        .disabled(updateChecker.downloadState == .downloading)
                    }

                    Button("Release Notes…") {
                        NSWorkspace.shared.open(releaseURL)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(versionText)
                Text(statusText)
                if case .failed(let reason) = updateChecker.downloadState {
                    Text("Couldn't download the update: \(reason)")
                }
                if let lastChecked = settings.lastUpdateCheckDate {
                    Text("Last checked \(Self.checkedAtFormatter.string(from: lastChecked)).")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private func runCheck() {
        Task {
            await updateChecker.check()
            settings.recordUpdateCheck()
        }
    }

    private func downloadAndInstall(from url: URL) {
        Task {
            await updateChecker.downloadAndOpenInstaller(from: url)
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String,
              let build = info?["CFBundleVersion"] as? String else {
            return "Version Unavailable"
        }
        return "Version \(version) (\(build))"
    }

    private var statusText: String {
        switch updateChecker.lastResult {
        case .none:
            return "Not checked yet."
        case .upToDate(let current):
            return "You're up to date (v\(current))."
        case .updateAvailable(let latest, _, _):
            return "A new version is available: v\(latest)."
        case .failed(let reason):
            return "Couldn't check for updates: \(reason)"
        }
    }

    private static let checkedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Window

/// PLAN.md §1.1's Global-shortcut and Window-management rows — §4 M8's
/// second task: "Global shortcut Ctrl+Shift+Esc (login item),
/// always-on-top, hide-on-close with background collection." The
/// researched design shows these as top-level Settings rows rather than
/// grouped under one of its four named sections; this app gives them
/// their own tab instead of
/// wedging them into General, since none of General's other rows
/// (`updateSpeed`, `defaultStartPage`) are about the window or the app's
/// lifecycle the way these four are.
///
/// Every row here is backed by `AppDelegate`/`MainWindowController`, which
/// observe the same `SettingsStore` published here via `@EnvironmentObject`
/// and apply each change live — see those types' doc comments for exactly
/// how (Carbon `RegisterEventHotKey`, `SMAppService.mainApp`, `NSWindow.level`,
/// `NSWindowDelegate.windowShouldClose`).
private struct WindowSettingsTab: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Toggle("Global Shortcut (⌃⇧⎋)", isOn: $settings.globalShortcutEnabled)
            Text("Press Control-Shift-Escape from any app to bring IDOTaskMaster to the front.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Launch at Login", isOn: $settings.launchAtLogin)
            Text("Keeps IDOTaskMaster running in the background so the global shortcut always works, even right after starting up.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Always on Top", isOn: $settings.alwaysOnTop)

            Toggle("Hide on Close", isOn: $settings.hideOnClose)
            Text("When on, closing the window hides it instead of quitting — IDOTaskMaster keeps collecting data in the background until you reopen it (global shortcut or Dock icon) or quit it explicitly (⌘Q).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

// MARK: - Previews

#Preview {
    SettingsPage()
        .environmentObject(SettingsStore(defaults: UserDefaults(suiteName: "SettingsPage.preview")!))
        .environmentObject(UpdateChecker())
}
