import SwiftUI

/// Root shell for the main window.
///
/// This is a placeholder for the M0 scaffold: the native sidebar nav,
/// page routing, and bottom info bar described in PLAN.md §3 arrive in
/// M1 ("Native sidebar shell with all pages routed"). For now it just
/// proves out the app target, window sizing, and system-appearance
/// behavior.
struct AppShell: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "gauge")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("IDOTaskMaster")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Scaffold ready — pages arrive in later milestones.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 600, minHeight: 400)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    AppShell()
}
