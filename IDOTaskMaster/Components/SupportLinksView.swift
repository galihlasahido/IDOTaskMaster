import AppKit
import SwiftUI

/// The same two support links the README's shields.io badges point at
/// (PayPal, Lynk.id), rendered as native, brand-colored capsule buttons
/// rather than fetched images — this app has one deliberate exception to
/// "no hidden network requests" already (`CountryResolver`, explicitly
/// opt-in), and a background image fetch just to draw a settings row
/// isn't worth a second one. Colors are the same hex values the README
/// badges use (`00457C` PayPal blue, `FB6B35` Lynk.id orange) so the two
/// surfaces read as the same two links, just drawn natively here.
///
/// Shared between `GeneralSettingsTab` (Settings ▸ General) and
/// `AppCommands.showAboutPanel()` (the App menu's "About IDOTaskMaster")
/// — one place to add a third support link later, if there ever is one.
struct SupportLinksView: View {
    private static let links: [(title: String, systemImage: String, color: Color, url: String)] = [
        ("Support via PayPal", "heart.fill", Color(red: 0x00 / 255, green: 0x45 / 255, blue: 0x7C / 255), "https://paypal.me/abahido"),
        ("Support via Lynk.id", "cup.and.saucer.fill", Color(red: 0xFB / 255, green: 0x6B / 255, blue: 0x35 / 255), "https://lynk.id/abahido/s/z52m3ekew032"),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.links, id: \.title) { link in
                Button {
                    guard let url = URL(string: link.url) else { return }
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(link.title, systemImage: link.systemImage)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(link.color))
                }
                .buttonStyle(.plain)
                .help(link.url)
            }
        }
    }
}

#Preview {
    SupportLinksView()
        .padding()
}
