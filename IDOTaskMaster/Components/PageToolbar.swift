import SwiftUI

/// Native per-page toolbar chrome — PLAN.md §4 M1's "Toolbar patterns:
/// search field, quit-process (ⓧ), inspect (ⓘ) buttons" and §2's "native
/// unified toolbar per page with search field and action buttons
/// (Activity Monitor's ⓧ quit-process, ⓘ inspect pattern)."
///
/// Reproduces Activity Monitor's own toolbar shape rather than a custom
/// bar drawn into the page body: a system `.searchable` field (so it gets
/// the same live-as-you-type field, Esc-to-clear, and Find-menu wiring
/// every other Mac app's toolbar search box gets for free) at the
/// toolbar's trailing edge, plus — for pages whose rows are things you can
/// act on, per PLAN.md's "process context menu (Quit, Force Quit,
/// Inspect, ...)" — the two leading-edge buttons Activity Monitor always
/// shows above its process table: ⓧ "Quit Process" and ⓘ "Inspect".
///
/// Like `DataTable`/`DetailPane`/`PageInfoBar`, this is pure shell chrome:
/// it only knows how to place a search field and (optionally) two action
/// buttons into the window toolbar. A page owns what "search" filters and
/// what the buttons do — today (M1) no page has a live selection to act
/// on yet, so every call site below passes `nil` actions, which reads
/// through `PageToolbar` as *present but disabled* rather than fabricating
/// a working Quit/Inspect before `ProcessProvider` exists (M4). A page
/// wires real closures once it has a selection to act on, with no change
/// needed here.
struct PageToolbar: ViewModifier {
    /// Live-bound filter text for the page's search field, e.g. Processes
    /// filtering "by name, user, or PID" (PLAN.md §1.1).
    @Binding var searchText: String
    /// Placeholder shown in the empty search field, e.g. "Filter Processes".
    var searchPrompt: String
    /// Set to include the ⓧ/ⓘ process-action buttons at all — `false` for
    /// list pages with nothing process-like to quit or inspect (Startup,
    /// Services, Connections, Installed Apps: filterable, but not process
    /// rows), matching PLAN.md §1.1's per-page action inventory rather than
    /// stamping every list page with buttons that would never do anything.
    var showsProcessActions: Bool
    /// `nil` renders the ⓧ button present but disabled — the honest state
    /// whenever nothing is selected, or the page's provider/selection
    /// model doesn't exist yet.
    var quitAction: (() -> Void)?
    var quitLabel: String
    /// `nil` renders the ⓘ button present but disabled, same rule as
    /// `quitAction`.
    var inspectAction: (() -> Void)?
    var inspectLabel: String

    func body(content: Content) -> some View {
        content
            .searchable(text: $searchText, placement: .toolbar, prompt: searchPrompt)
            .toolbar {
                if showsProcessActions {
                    ToolbarItemGroup(placement: .navigation) {
                        toolbarButton(
                            label: quitLabel,
                            systemImage: "xmark.circle",
                            action: quitAction
                        )
                        toolbarButton(
                            label: inspectLabel,
                            systemImage: "info.circle",
                            action: inspectAction
                        )
                    }
                }
            }
    }

    /// One toolbar icon button, shared by the ⓧ and ⓘ items: disabled
    /// (rather than omitted) when its action is `nil`, so the button's
    /// presence in the toolbar never depends on whether something happens
    /// to be selected right now — only on whether this page has that kind
    /// of action at all (`showsProcessActions`).
    private func toolbarButton(label: String, systemImage: String, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            Label(label, systemImage: systemImage)
        }
        .disabled(action == nil)
        .help(label)
    }
}

extension View {
    /// Attaches `PageToolbar`'s search field, and — when `showsProcessActions`
    /// is `true` — its ⓧ "Quit Process" / ⓘ "Inspect" buttons, to any page.
    ///
    /// - Parameters:
    ///   - searchText: The page's live filter-text binding.
    ///   - searchPrompt: Search field placeholder, e.g. "Filter Processes".
    ///   - showsProcessActions: Include the ⓧ/ⓘ buttons at all. Defaults to
    ///     `false` — a plain filterable list page opts into search alone;
    ///     a process-actionable page (Processes, Users) passes `true`.
    ///   - quitLabel / quitAction: The ⓧ button's tooltip and action.
    ///     `quitAction: nil` (the default) shows the button disabled.
    ///   - inspectLabel / inspectAction: The ⓘ button's tooltip and
    ///     action, same `nil`-disables rule as `quitAction`.
    func pageToolbar(
        searchText: Binding<String>,
        searchPrompt: String = "Filter",
        showsProcessActions: Bool = false,
        quitLabel: String = "Quit Process",
        quitAction: (() -> Void)? = nil,
        inspectLabel: String = "Inspect",
        inspectAction: (() -> Void)? = nil
    ) -> some View {
        modifier(PageToolbar(
            searchText: searchText,
            searchPrompt: searchPrompt,
            showsProcessActions: showsProcessActions,
            quitAction: quitAction,
            quitLabel: quitLabel,
            inspectAction: inspectAction,
            inspectLabel: inspectLabel
        ))
    }
}

// MARK: - Previews

/// `.searchable`/`.toolbar` only render into a real window toolbar inside
/// navigation chrome, so each preview below wraps its page in a
/// `NavigationStack` the way `AppShell`'s `NavigationSplitView` detail
/// column does at runtime.
private struct PageToolbarProcessPreview: View {
    @State private var searchText = ""
    @State private var selection: Int? = nil

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                ForEach([1421, 233, 88], id: \.self) { pid in
                    Text("Process \(pid)").tag(pid)
                }
            }
            .navigationTitle("Processes")
            .pageToolbar(
                searchText: $searchText,
                searchPrompt: "Filter Processes",
                showsProcessActions: true,
                quitAction: selection == nil ? nil : { },
                inspectAction: selection == nil ? nil : { }
            )
        }
    }
}

private struct PageToolbarSearchOnlyPreview: View {
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            Text("Startup agents/daemons table")
                .foregroundStyle(.secondary)
                .navigationTitle("Startup Apps")
                .pageToolbar(searchText: $searchText, searchPrompt: "Filter Startup Items")
        }
    }
}

#Preview("Process actions (selection-driven)") {
    PageToolbarProcessPreview()
        .frame(width: 520, height: 260)
}

#Preview("Search only") {
    PageToolbarSearchOnlyPreview()
        .frame(width: 520, height: 260)
}
