import SwiftUI
import UserNotifications

/// Alerts page — one of this app's own additions beyond the baseline
/// feature set (PLAN.md §2: "alert/notification rules") / §4 M9's first
/// task: "user-defined threshold rules ... → UserNotifications; rule
/// editor UI." Most comparable system monitors have no alerting at all.
///
/// Reads and edits the single app-lifetime `AlertsEngine` instance handed
/// down through the environment from `IDOTaskMasterApp` (the same
/// "started once at launch, independent of any window" ownership
/// `MenuBarStatusModel`/`DockIconRenderer` use — see `AlertsEngine`'s own
/// doc comment) — this page never starts or stops it, only reads its
/// `@Published` state and calls its rule-editing methods.
///
/// Layout mirrors `StartupPage`'s "table over `DetailPane`" shape (a
/// `DataTable` of rules with an inline Enabled checkbox column, matching
/// Startup's own toggle-in-table convention) plus one more section this
/// page alone needs: a "Recent Alerts" log under the detail pane, the
/// only place in the app that shows a rule actually having fired.
struct AlertsPage: View {
    @EnvironmentObject private var engine: AlertsEngine
    @State private var searchText = ""
    @State private var sort: DataTableSort? = DataTableSort(columnID: "name", ascending: true)
    @State private var selectedRuleID: UUID?
    @State private var editorTarget: AlertRuleEditorTarget?

    /// Matches `StartupPage.detailPaneHeight` in spirit — enough room for
    /// this domain's own detail sections without scrolling.
    private static let detailPaneHeight: CGFloat = 190
    private static let recentAlertsHeight: CGFloat = 170

    var body: some View {
        VStack(spacing: 0) {
            statusLine
            Divider()
            table
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            detailPane
                .frame(height: Self.detailPaneHeight)
            Divider()
            recentAlertsSection
                .frame(height: Self.recentAlertsHeight)
        }
        .pageToolbar(searchText: $searchText, searchPrompt: "Filter Rules")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                addButton
                editButton
                testButton
                deleteButton
                ExportMenu(
                    columns: Self.columns(
                        lastFired: { engine.lastFiredDate(forRuleID: $0.id) },
                        toggle: { rule, enabled in engine.setEnabled(enabled, forRuleID: rule.id) }
                    ),
                    rows: filteredRules,
                    suggestedName: "Alert Rules"
                )
            }
        }
        .sheet(item: $editorTarget) { target in
            AlertRuleEditorView(existingRule: target.rule) { rule in
                if target.rule == nil {
                    engine.addRule(rule)
                    selectedRuleID = rule.id
                } else {
                    engine.updateRule(rule)
                }
            }
        }
        .task {
            await engine.refreshAuthorizationStatus()
        }
    }

    // MARK: - Toolbar

    private var addButton: some View {
        Button {
            editorTarget = .new
        } label: {
            Label("Add Rule\u{2026}", systemImage: "plus")
        }
        .help("Add a new alert rule")
    }

    private var editButton: some View {
        Button {
            if let rule = selectedRule { editorTarget = .edit(rule) }
        } label: {
            Label("Edit Rule\u{2026}", systemImage: "pencil")
        }
        .disabled(selectedRule == nil)
        .help("Edit the selected rule")
    }

    private var testButton: some View {
        Button {
            if let rule = selectedRule { engine.sendTestNotification(for: rule) }
        } label: {
            Label("Send Test Notification", systemImage: "bell.badge")
        }
        .disabled(selectedRule == nil)
        .help("Post a test notification for the selected rule, and run its command if one\u{2019}s configured")
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            if let id = selectedRuleID {
                engine.deleteRule(id: id)
                selectedRuleID = nil
            }
        } label: {
            Label("Delete Rule", systemImage: "trash")
        }
        .disabled(selectedRule == nil)
        .help("Delete the selected rule")
    }

    // MARK: - Status line

    /// Mirrors `StartupPage.statusLine`'s "as of / problem" caption, plus
    /// this page's own notification-authorization disclosure — PLAN.md's
    /// honest-degradation rule applies to this engine's own delivery
    /// mechanism, not just provider readings (see `AlertsEngine
    /// .authorizationStatus`'s own doc comment).
    private var statusLine: some View {
        HStack(spacing: 4) {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(authorizationIsProblem ? Color(nsColor: .tertiaryLabelColor) : .secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var statusText: String {
        let enabledCount = engine.rules.filter(\.isEnabled).count
        let ruleText = engine.rules.count == 1 ? "1 rule" : "\(engine.rules.count) rules"
        var text = "\(ruleText) \u{2014} \(enabledCount) enabled \u{2014} notifications \(authorizationText)"
        if let lastEvaluatedAt = engine.lastEvaluatedAt {
            text += " \u{2014} watching, last checked \(Self.timeFormatter.string(from: lastEvaluatedAt))"
        }
        return text
    }

    private var authorizationText: String {
        switch engine.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return "enabled"
        case .denied:
            return "denied \u{2014} enable in System Settings \u{2192} Notifications"
        case .notDetermined:
            return "not yet requested"
        @unknown default:
            return "unknown"
        }
    }

    private var authorizationIsProblem: Bool {
        engine.authorizationStatus == .denied
    }

    // MARK: - Table

    private var table: some View {
        DataTable(
            columns: Self.columns(
                lastFired: { engine.lastFiredDate(forRuleID: $0.id) },
                toggle: { rule, enabled in engine.setEnabled(enabled, forRuleID: rule.id) }
            ),
            rows: filteredRules,
            sort: $sort,
            selection: $selectedRuleID,
            emptyMessage: emptyMessage
        )
    }

    private var emptyMessage: String {
        searchText.isEmpty
            ? "No alert rules yet. Click Add Rule\u{2026} to create one."
            : "No rules match \u{201C}\(searchText)\u{201D}."
    }

    private var filteredRules: [AlertRule] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return engine.rules }
        let needle = searchText.lowercased()
        return engine.rules.filter { rule in
            rule.name.lowercased().contains(needle) || rule.kind.conditionSummary.lowercased().contains(needle)
        }
    }

    private static func columns(
        lastFired: @escaping (AlertRule) -> Date?,
        toggle: @escaping (AlertRule, Bool) -> Void
    ) -> [DataTableColumn<AlertRule>] {
        [
            // `Bool` isn't `Comparable`, so this column uses the general
            // initializer with an explicit `comparator: nil` (unsortable),
            // matching `StartupPage`'s own Enabled column.
            DataTableColumn(id: "enabled", title: "Enabled", width: 60, alignment: .center, comparator: nil) { rule in
                Toggle("", isOn: Binding(
                    get: { rule.isEnabled },
                    set: { newValue in toggle(rule, newValue) }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help(rule.isEnabled ? "Disable this rule" : "Enable this rule")
                .accessibilityLabel("Enabled, \(rule.name)")
            },
            DataTableColumn(id: "name", title: "Name", value: { $0.name }) { rule in
                Label {
                    Text(rule.name).lineLimit(1)
                } icon: {
                    Image(systemName: rule.kind.tag.systemImage)
                        .foregroundStyle(.secondary)
                }
            },
            DataTableColumn(id: "condition", title: "Condition", value: { $0.kind.conditionSummary }) { rule in
                Text(rule.kind.conditionSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            },
            DataTableColumn(
                id: "lastFired",
                title: "Last Fired",
                width: 130,
                alignment: .trailing,
                value: { lastFired($0)?.timeIntervalSinceReferenceDate ?? Date.distantPast.timeIntervalSinceReferenceDate }
            ) { rule in
                Group {
                    if let date = lastFired(rule) {
                        Text(Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))
                    } else {
                        Text("Never")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            },
        ]
    }

    // MARK: - Detail pane

    private var selectedRule: AlertRule? {
        guard let selectedRuleID else { return nil }
        return engine.rules.first(where: { $0.id == selectedRuleID })
    }

    @ViewBuilder
    private var detailPane: some View {
        if let rule = selectedRule {
            DetailPane(
                title: rule.name,
                subtitle: rule.kind.conditionSummary,
                systemImage: rule.kind.tag.systemImage,
                sections: detailSections(for: rule)
            )
        } else {
            DetailPane(emptyMessage: "Select a rule to view its details, or click Add Rule\u{2026} to create one.")
        }
    }

    private func detailSections(for rule: AlertRule) -> [DetailPaneSection] {
        let lastFired = engine.lastFiredDate(forRuleID: rule.id)
        return [
            DetailPaneSection(title: "Condition", fields: [
                DetailPaneField(label: "Type", value: rule.kind.tag.title),
                DetailPaneField(label: "Threshold", value: rule.kind.conditionSummary),
            ]),
            DetailPaneSection(title: "Notification", fields: [
                DetailPaneField(label: "Enabled", value: rule.isEnabled ? "Yes" : "No"),
                DetailPaneField(label: "Cooldown", value: "\(Int(rule.cooldownMinutes)) min between repeats"),
                DetailPaneField(
                    label: "Last Fired",
                    value: lastFired.map { Self.dateTimeFormatter.string(from: $0) } ?? "",
                    isUnavailable: lastFired == nil
                ),
                DetailPaneField(
                    label: "Command",
                    value: rule.commandToRun ?? "",
                    isUnavailable: rule.commandToRun == nil,
                    isMonospaced: true
                ),
            ]),
        ]
    }

    // MARK: - Recent alerts

    /// This page's own bottom section — not `DetailPane`, since it isn't
    /// keyed to the table's selection: PLAN.md's rule-editor task calls
    /// for a rule editor, but a rule with no visible evidence it ever
    /// fired would be trust-me-it-works. This is the one place in the app
    /// that shows `AlertsEngine.firedAlerts`.
    private var recentAlertsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("RECENT ALERTS")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
            if engine.firedAlerts.isEmpty {
                Spacer(minLength: 0)
                Text("No alerts have fired yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                List(engine.firedAlerts) { alert in
                    recentAlertRow(alert)
                }
                .listStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func recentAlertRow(_ alert: FiredAlert) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: alert.isTest ? "bell.badge" : "bell.fill")
                .foregroundStyle(alert.severity == .critical ? StatusPalette.critical : StatusPalette.warning)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(alert.ruleName)
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if alert.isTest {
                        Text("TEST")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text(Self.relativeFormatter.localizedString(for: alert.firedAt, relativeTo: Date()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(alert.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Formatting

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

// MARK: - Rule editor sheet target

/// Which sheet `AlertsPage`'s "Add Rule…"/"Edit Rule…" toolbar buttons
/// are presenting — `.sheet(item:)`'s identity, distinguishing "editing
/// nothing yet" (`.new`) from "editing this specific rule" (`.edit`) so
/// `AlertRuleEditorView` can seed its fields from an existing rule's
/// values when there is one.
private enum AlertRuleEditorTarget: Identifiable {
    case new
    case edit(AlertRule)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let rule): return rule.id.uuidString
        }
    }

    var rule: AlertRule? {
        if case .edit(let rule) = self { return rule }
        return nil
    }
}

// MARK: - Rule editor

/// The "rule editor UI" PLAN.md §4 M9 calls for — a plain `Form` sheet
/// covering every `AlertRuleKind` case's own parameters, switched on the
/// picked `AlertRuleKindTag`. Deleting a rule is deliberately not offered
/// here — `AlertsPage`'s own toolbar Delete button (which needs no sheet)
/// already covers it — so this view is only ever about one rule's fields.
private struct AlertRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let existingRule: AlertRule?
    let onSave: (AlertRule) -> Void

    @State private var name: String
    @State private var tag: AlertRuleKindTag
    @State private var cpuPercent: Double
    @State private var cpuMinutes: Double
    @State private var pressureLevel: AlertMemoryPressureLevel
    @State private var diskPercent: Double
    @State private var batteryPercent: Double
    @State private var isEnabled: Bool
    @State private var cooldownMinutes: Double
    @State private var commandToRun: String

    init(existingRule: AlertRule?, onSave: @escaping (AlertRule) -> Void) {
        self.existingRule = existingRule
        self.onSave = onSave

        let kind = existingRule?.kind ?? .cpuAbove(percent: 90, sustainedMinutes: 5)
        _name = State(initialValue: existingRule?.name ?? "")
        _tag = State(initialValue: kind.tag)

        if case .cpuAbove(let percent, let minutes) = kind {
            _cpuPercent = State(initialValue: percent)
            _cpuMinutes = State(initialValue: minutes)
        } else {
            _cpuPercent = State(initialValue: 90)
            _cpuMinutes = State(initialValue: 5)
        }
        if case .memoryPressureAtLeast(let level) = kind {
            _pressureLevel = State(initialValue: level)
        } else {
            _pressureLevel = State(initialValue: .critical)
        }
        if case .lowDiskFreePercent(let percent) = kind {
            _diskPercent = State(initialValue: percent)
        } else {
            _diskPercent = State(initialValue: 10)
        }
        if case .lowBatteryPercent(let percent) = kind {
            _batteryPercent = State(initialValue: percent)
        } else {
            _batteryPercent = State(initialValue: 20)
        }
        _isEnabled = State(initialValue: existingRule?.isEnabled ?? true)
        _cooldownMinutes = State(initialValue: existingRule?.cooldownMinutes ?? 15)
        _commandToRun = State(initialValue: existingRule?.commandToRun ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                Section("Rule") {
                    TextField("Name", text: $name, prompt: Text(tag.title))
                    Picker("Type", selection: $tag) {
                        ForEach(AlertRuleKindTag.allCases) { tag in
                            Text(tag.title).tag(tag)
                        }
                    }
                }
                Section("Condition") {
                    conditionFields
                }
                Section("Notification") {
                    Toggle("Enabled", isOn: $isEnabled)
                    Stepper(cooldownLabel, value: $cooldownMinutes, in: 1...240, step: 1)
                }
                Section {
                    TextField("Command", text: $commandToRun, prompt: Text("e.g. /usr/bin/say \"CPU is high\""))
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Run a Command")
                } footer: {
                    Text("Runs alongside the notification every time this rule fires (and when you send a test). The rule\u{2019}s name, message, and severity are passed as environment variables (IDOTASKMASTER_ALERT_\u{2026}).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 420, height: 560)
    }

    private var header: some View {
        Text(existingRule == nil ? "New Alert Rule" : "Edit Alert Rule")
            .font(.headline)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var conditionFields: some View {
        switch tag {
        case .cpuAbove:
            Stepper("Above \(Int(cpuPercent))%", value: $cpuPercent, in: 1...100, step: 1)
            Stepper(cpuMinutesLabel, value: $cpuMinutes, in: 0.5...60, step: 0.5)
        case .memoryPressure:
            Picker("Pressure Level", selection: $pressureLevel) {
                ForEach(AlertMemoryPressureLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
        case .lowDisk:
            Stepper("Free space at or below \(Int(diskPercent))%", value: $diskPercent, in: 1...50, step: 1)
        case .lowBattery:
            Stepper("Battery at or below \(Int(batteryPercent))%", value: $batteryPercent, in: 1...100, step: 1)
        case .newPublicPort:
            Text("Fires whenever a process starts listening on a port reachable from outside your local network.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var cpuMinutesLabel: String {
        cpuMinutes == cpuMinutes.rounded()
            ? "Sustained for \(Int(cpuMinutes)) min"
            : String(format: "Sustained for %.1f min", cpuMinutes)
    }

    private var cooldownLabel: String {
        "Cooldown: \(Int(cooldownMinutes)) min between repeats"
    }

    private var footer: some View {
        HStack {
            Spacer(minLength: 0)
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                onSave(makeRule())
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private func makeRule() -> AlertRule {
        let kind: AlertRuleKind
        switch tag {
        case .cpuAbove: kind = .cpuAbove(percent: cpuPercent, sustainedMinutes: cpuMinutes)
        case .memoryPressure: kind = .memoryPressureAtLeast(level: pressureLevel)
        case .lowDisk: kind = .lowDiskFreePercent(percent: diskPercent)
        case .lowBattery: kind = .lowBatteryPercent(percent: batteryPercent)
        case .newPublicPort: kind = .newPublicListeningPort
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = commandToRun.trimmingCharacters(in: .whitespacesAndNewlines)
        return AlertRule(
            id: existingRule?.id ?? UUID(),
            name: trimmedName.isEmpty ? tag.title : trimmedName,
            kind: kind,
            isEnabled: isEnabled,
            cooldownMinutes: cooldownMinutes,
            commandToRun: trimmedCommand.isEmpty ? nil : trimmedCommand
        )
    }
}

#Preview {
    AlertsPage()
        .environmentObject(AlertsEngine(defaults: UserDefaults(suiteName: "AlertsPage.preview")!))
        .frame(width: 860, height: 720)
}
