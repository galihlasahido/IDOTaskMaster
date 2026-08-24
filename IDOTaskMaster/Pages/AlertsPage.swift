import SwiftUI

/// Alerts page — one of this app's own beyond-[name removed] additions (PLAN.md
/// §2: "alert/notification rules") / §4 M9. Placeholder until M9 adds
/// `AlertsEngine` (threshold rules → `UserNotifications`) and the rule
/// editor UI.
struct AlertsPage: View {
    var body: some View {
        PlaceholderPageView(
            page: .alerts,
            detail: "User-defined threshold rules (CPU, memory pressure, low disk, low battery, new public port) and a rule editor."
        )
    }
}

#Preview {
    AlertsPage()
}
