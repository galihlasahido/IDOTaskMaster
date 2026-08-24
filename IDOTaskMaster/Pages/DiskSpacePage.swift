import SwiftUI

/// Disk Space page — PLAN.md §1.1 "Disk Space" (a former [name removed] Pro page,
/// unlocked here per §2) / §4 M6. Placeholder until M6 adds
/// `DiskSpaceScanner` (async recursive scan + file-type classification),
/// the bubble-chart visualization, file-type legend, and largest
/// folders/files lists.
struct DiskSpacePage: View {
    var body: some View {
        PlaceholderPageView(
            page: .diskSpace,
            detail: "Async disk scanner with a bubble view, file-type legend, and largest folders/files."
        )
    }
}

#Preview {
    DiskSpacePage()
}
