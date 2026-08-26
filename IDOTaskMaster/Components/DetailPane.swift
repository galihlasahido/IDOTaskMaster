import SwiftUI

/// One label/value row inside a `DetailPaneSection`, e.g. "Parent" →
/// "launchd" in the Processes page's Identity section (PLAN.md §1.1).
struct DetailPaneField: Identifiable {
    let id: String
    let label: String
    let value: String
    /// Set when the underlying provider couldn't read this particular
    /// field this tick (or ever, on hardware that doesn't expose it).
    /// Per PLAN.md's "honest degradation" rule, `DetailPane` renders
    /// "Unavailable" in place of `value` — dimmed, matching
    /// `CapacityBar.isUnavailable` and `StatTile.isUnavailable` — rather
    /// than a blank or guessed reading. `value` is still required so a
    /// caller can carry a diagnostic string through without it being
    /// shown; pass `""` if there's nothing to carry.
    var isUnavailable: Bool = false
    /// Renders `value` with `.monospacedDigit()` — for numeric/PID/byte
    /// readings, matching the convention `DataTable` and `CapacityBar`
    /// use for their own numeric cells.
    var isMonospaced: Bool = false
    /// When set, `value` renders as a clickable link-style button instead
    /// of plain selectable text — e.g. `NetworkMonitorPage`'s PID field
    /// jumping straight to that process on the Processes page. `nil` (the
    /// default) keeps every existing field exactly as plain text; never
    /// applied when `isUnavailable` is true regardless of whether one is
    /// set, since there's nothing meaningful to jump to.
    var action: (() -> Void)?

    init(id: String? = nil, label: String, value: String, isUnavailable: Bool = false, isMonospaced: Bool = false, action: (() -> Void)? = nil) {
        self.id = id ?? label
        self.label = label
        self.value = value
        self.isUnavailable = isUnavailable
        self.isMonospaced = isMonospaced
        self.action = action
    }
}

/// One titled group of `DetailPaneField`s, e.g. Processes' "Identity",
/// "Lifetime", "Processor", "Memory", "Disk" sections (PLAN.md §1.1), or
/// Startup apps' single flat identity/publisher/status group.
struct DetailPaneSection: Identifiable {
    let id: String
    let title: String
    let fields: [DetailPaneField]

    init(id: String? = nil, title: String, fields: [DetailPaneField]) {
        self.id = id ?? title
        self.title = title
        self.fields = fields
    }
}

/// Native key/value inspector — PLAN.md §4's `DetailPane`. The shared
/// bottom/side panel every master-detail page in §1.1 opens on a
/// selection: Processes' "full path, Identity (parent, user, status,
/// architecture arm64), Lifetime (start time, uptime, threads, priority),
/// Processor (CPU %, CPU time, GPU, NPU), Memory (footprint, private, page
/// faults), Disk (R/W rates)"; Startup apps' "identity, publisher, status,
/// running state, file size/dates, owner, permissions"; Services' and
/// System Info's own key-value detail panes.
///
/// Pure in the same sense as `DataTable`/`HistoryGraph`/`CapacityBar`: it
/// only knows how to lay out a title plus whatever `DetailPaneSection`s
/// it's given — a page's provider (`ProcessProvider`, `StartupProvider`,
/// ...) is responsible for turning its own model into that shape. Nothing
/// about *which* fields a domain has belongs here, so the same view serves
/// every detail pane in PLAN.md §3 without a per-page subclass.
///
/// Two initializers mirror `DataTable`'s populated/`emptyMessage` split:
/// one for an active selection, one for the "nothing selected yet"
/// placeholder a master-detail page shows before the user picks a row.
struct DetailPane: View {
    private enum Content {
        case empty(message: String)
        case populated(title: String, subtitle: String?, systemImage: String?, sections: [DetailPaneSection])
    }

    private let content: Content

    /// Populated pane for the current selection.
    /// - Parameters:
    ///   - title: The selected item's name, e.g. a process name or
    ///     service label.
    ///   - subtitle: A secondary identifying line shown under `title`,
    ///     e.g. Processes' "full path" — selectable so it can be copied
    ///     (PLAN.md §2's process context menu includes "Copy path").
    ///   - systemImage: SF Symbol shown beside the title. `nil` omits the
    ///     icon, e.g. for domains without a natural per-item glyph.
    ///   - sections: The grouped fields to show, in display order.
    init(title: String, subtitle: String? = nil, systemImage: String? = nil, sections: [DetailPaneSection]) {
        content = .populated(title: title, subtitle: subtitle, systemImage: systemImage, sections: sections)
    }

    /// No-selection placeholder — the state a master-detail page's pane
    /// starts in before anything is picked from its `DataTable`/outline
    /// view.
    init(emptyMessage: String = "No selection.") {
        content = .empty(message: emptyMessage)
    }

    var body: some View {
        switch content {
        case .empty(let message):
            emptyState(message)
        case .populated(let title, let subtitle, let systemImage, let sections):
            populated(title: title, subtitle: subtitle, systemImage: systemImage, sections: sections)
        }
    }

    // MARK: - Populated

    private func populated(title: String, subtitle: String?, systemImage: String?, sections: [DetailPaneSection]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(title: title, subtitle: subtitle, systemImage: systemImage)
            Divider()
            if sections.isEmpty {
                emptyState("No details available.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(sections) { section in
                            sectionView(section)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func header(title: String, subtitle: String?, systemImage: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .accessibilityElement(children: .combine)
    }

    private func sectionView(_ section: DetailPaneSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title.uppercased())
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                ForEach(section.fields) { field in
                    GridRow {
                        Text(field.label)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        fieldValue(field)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func fieldValue(_ field: DetailPaneField) -> some View {
        if let action = field.action, !field.isUnavailable {
            Button(action: action) { valueText(field) }
                .buttonStyle(.link)
        } else {
            valueText(field)
        }
    }

    @ViewBuilder
    private func valueText(_ field: DetailPaneField) -> some View {
        let text = Text(field.isUnavailable ? "Unavailable" : field.value)
            .font(.callout)
            .foregroundStyle(field.isUnavailable ? Color(nsColor: .tertiaryLabelColor) : .primary)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
        if field.isMonospaced && !field.isUnavailable {
            text.monospacedDigit()
        } else {
            text
        }
    }

    // MARK: - Empty state

    private func emptyState(_ message: String) -> some View {
        VStack {
            Spacer(minLength: 0)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Previews

#Preview("Process selected") {
    DetailPane(
        title: "Xcode",
        subtitle: "/Applications/Xcode.app/Contents/MacOS/Xcode",
        systemImage: "app.fill",
        sections: [
            DetailPaneSection(title: "Identity", fields: [
                DetailPaneField(label: "Parent", value: "launchd"),
                DetailPaneField(label: "User", value: "prog1"),
                DetailPaneField(label: "Status", value: "Running"),
                DetailPaneField(label: "Architecture", value: "arm64"),
            ]),
            DetailPaneSection(title: "Lifetime", fields: [
                DetailPaneField(label: "Started", value: "9:14 AM"),
                DetailPaneField(label: "Uptime", value: "2:41:08", isMonospaced: true),
                DetailPaneField(label: "Threads", value: "38", isMonospaced: true),
                DetailPaneField(label: "Priority", value: "Normal"),
            ]),
            DetailPaneSection(title: "Processor", fields: [
                DetailPaneField(label: "CPU", value: "48.2%", isMonospaced: true),
                DetailPaneField(label: "CPU Time", value: "12:04.31", isMonospaced: true),
                DetailPaneField(label: "GPU", value: "3.1%", isMonospaced: true),
                DetailPaneField(label: "NPU", value: "", isUnavailable: true),
            ]),
            DetailPaneSection(title: "Memory", fields: [
                DetailPaneField(label: "Footprint", value: "1.8 GB", isMonospaced: true),
                DetailPaneField(label: "Private", value: "1.6 GB", isMonospaced: true),
                DetailPaneField(label: "Page Faults", value: "204,113", isMonospaced: true),
            ]),
            DetailPaneSection(title: "Disk", fields: [
                DetailPaneField(label: "Reads", value: "12 KB/s", isMonospaced: true),
                DetailPaneField(label: "Writes", value: "0 KB/s", isMonospaced: true),
            ]),
        ]
    )
    .frame(width: 320, height: 420)
}

#Preview("No selection") {
    DetailPane(emptyMessage: "Select a process to view its details.")
        .frame(width: 320, height: 200)
}
