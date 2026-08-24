import SwiftUI

/// Settings page — PLAN.md §1.1 "Settings" / §4 M8. Routed from
/// `AppShell`'s fixed sidebar-footer button rather than a `SidebarPage`
/// row (see that type's doc comment for why), so it can't reuse
/// `PlaceholderPageView`'s `SidebarPage`-keyed initializer — this is a
/// small hand-written twin of that same placeholder look instead.
///
/// Placeholder until M8 adds the real Settings window content:
/// Appearance (theme, language, display font, High Frequency Visuals),
/// Graphs (color-keyed graphs, history compression, pixels per update),
/// General (update speed — mirroring `SettingsStore.updateSpeed`,
/// default start page, show-in-reports), and Updates (check on start,
/// auto update).
struct SettingsPage: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "gearshape")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Appearance, update speed, graph history options, and update-check preferences. Arrives in M8.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Settings. Not yet implemented.")
    }
}

#Preview {
    SettingsPage()
        .frame(width: 520, height: 340)
}
