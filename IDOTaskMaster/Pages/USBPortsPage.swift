import SwiftUI

/// USB & Ports page — per-port USB-C/MagSafe status, live power draw,
/// cable e-marker identity, and the USB device tree, all fed by
/// `USBPortsProvider` (see that type's doc comment for the three data
/// sources and their limits).
///
/// One idea, many sub-readings — so the layout is the master-detail
/// pattern `PerformancePage` established rather than tabs or separate
/// pages: a selectable card per physical port up top (the master rail,
/// built from the same selectable `StatTile` Performance's rail uses),
/// the full `DetailPane` for whichever port is selected below it, and the
/// flat-but-indented USB device list alongside. Selecting a port is the
/// only navigation; every sub-feature is just a section of the one page.
///
/// Apple-silicon only, honestly: Intel Macs (and Apple-silicon desktops'
/// front ports) don't publish the port-controller registry nodes this
/// reads, and `unavailableState` says exactly that instead of showing an
/// empty shell — the same whole-domain honesty `PerformancePage` applies
/// when a provider throws.
struct USBPortsPage: View {
    @StateObject private var model = USBPortsViewModel()
    @State private var selectedPortID: String?
    @State private var isCableHealthSheetPresented = false

    var body: some View {
        Group {
            if let reason = model.unavailableReason {
                unavailableState(reason)
            } else {
                content
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - Layout

    private var content: some View {
        VStack(spacing: 0) {
            statTileRow
            Divider()
            portCardRow
            Divider()
            HSplitView {
                portDetail
                    .frame(minWidth: 320, idealWidth: 420)
                devicesSection
                    .frame(minWidth: 260)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func unavailableState(_ reason: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "cable.connector")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Per-Port Data Unavailable")
                .font(.title2)
                .fontWeight(.semibold)
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Stat tiles

    private static let tileGridColumns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    private var statTileRow: some View {
        LazyVGrid(columns: Self.tileGridColumns, spacing: 10) {
            StatTile(
                title: "Ports",
                systemImage: "cable.connector",
                color: DomainPalette.energy,
                value: model.snapshot.map { "\($0.ports.count)" } ?? "",
                secondaryText: "USB-C and MagSafe",
                isUnavailable: model.snapshot == nil
            )
            StatTile(
                title: "In Use",
                systemImage: "cable.connector.horizontal",
                color: DomainPalette.networkIn,
                value: model.snapshot.map { "\($0.ports.filter(\.isConnected).count)" } ?? "",
                secondaryText: "with something attached",
                isUnavailable: model.snapshot == nil
            )
            StatTile(
                title: "USB Devices",
                systemImage: "externaldrive.connected.to.line.below",
                color: DomainPalette.gpuSecondary,
                value: model.snapshot.map { "\($0.devices.count)" } ?? "",
                secondaryText: "on the bus, hubs included",
                isUnavailable: model.snapshot == nil
            )
            StatTile(
                title: "Port Power",
                systemImage: "bolt.fill",
                color: DomainPalette.energy,
                value: totalPortPowerText,
                secondaryText: "drawn across all ports",
                isUnavailable: model.snapshot == nil || totalPortPower == nil
            )
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var totalPortPower: Double? {
        guard let ports = model.snapshot?.ports else { return nil }
        let watts = ports.compactMap(\.watts)
        guard !watts.isEmpty else { return nil }
        return watts.reduce(0, +)
    }

    private var totalPortPowerText: String {
        guard let totalPortPower else { return "" }
        return String(format: "%.1f W", totalPortPower)
    }

    // MARK: - Port cards

    /// The selectable master rail — one `StatTile` per physical port,
    /// exactly the selectable-card mechanism `PerformancePage`'s rail
    /// uses (`isSelected` + `action`), so selection looks and behaves
    /// like something this app already does.
    private var portCardRow: some View {
        HStack(spacing: 10) {
            ForEach(model.snapshot?.ports ?? []) { port in
                StatTile(
                    title: port.name,
                    systemImage: port.portType.hasPrefix("MagSafe") ? "magsafe.batterypack" : "cable.connector",
                    color: port.isConnected ? DomainPalette.networkIn : DomainPalette.diskCapacity,
                    value: portHeadline(port),
                    secondaryText: portCaption(port),
                    isSelected: selectedPortID == port.id,
                    action: { selectedPortID = port.id }
                )
            }
        }
        .padding(10)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: model.snapshot?.ports.first?.id) { firstID in
            // Seed the selection once real data exists so the detail pane
            // is never an empty shell on arrival.
            if selectedPortID == nil { selectedPortID = firstID }
        }
    }

    private func portHeadline(_ port: USBPortSnapshot) -> String {
        guard port.isConnected else { return "Empty" }
        if let watts = port.watts, watts >= 0.5 {
            return String(format: "%.1f W", watts)
        }
        return port.connectString ?? "Connected"
    }

    private func portCaption(_ port: USBPortSnapshot) -> String {
        guard port.isConnected else { return "nothing attached" }
        let transports = port.activeTransports.filter { $0 != "CC" }
        return transports.isEmpty ? "connected" : transports.joined(separator: " · ")
    }

    // MARK: - Port detail

    @ViewBuilder
    private var portDetail: some View {
        if let port = selectedPort {
            VStack(spacing: 0) {
                DetailPane(
                    title: port.name,
                    subtitle: port.isConnected ? (port.connectString ?? "Connected") : "Nothing attached",
                    systemImage: port.portType.hasPrefix("MagSafe") ? "magsafe.batterypack" : "cable.connector",
                    sections: detailSections(for: port)
                )
                // Only where it makes sense: a connected USB-C port. The
                // test itself needs a writable volume on the attached
                // drive, which the sheet asks for — it never picks one on
                // its own.
                if port.isConnected, !port.portType.hasPrefix("MagSafe") {
                    Divider()
                    HStack {
                        Button("Test Cable Health\u{2026}") {
                            isCableHealthSheetPresented = true
                        }
                        .help("Measure whether this port\u{2019}s link stalls between transfers \u{2014} the signature of a marginal cable that a negotiated link rate can\u{2019}t show")
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                }
            }
            .sheet(isPresented: $isCableHealthSheetPresented) {
                CableHealthSheet(linkGbps: port.negotiatedLink?.gbps)
            }
        } else {
            DetailPane(emptyMessage: "Select a port to view its details.")
        }
    }

    private var selectedPort: USBPortSnapshot? {
        guard let selectedPortID else { return nil }
        return model.snapshot?.ports.first { $0.id == selectedPortID }
    }

    private func detailSections(for port: USBPortSnapshot) -> [DetailPaneSection] {
        var sections: [DetailPaneSection] = []

        var connectionFields: [DetailPaneField] = [
            DetailPaneField(label: "Status", value: port.isConnected ? "Connected" : "Empty"),
            DetailPaneField(
                label: "Active Transports",
                value: port.activeTransports.isEmpty ? "\u{2014}" : port.activeTransports.joined(separator: ", ")
            ),
            DetailPaneField(label: "Supported", value: port.supportedTransports.joined(separator: ", ")),
        ]
        if let link = port.negotiatedLink {
            var linkValue = link.rateDescription
            if let generation = link.generationDescription {
                linkValue += " (\(generation))"
            }
            connectionFields.append(DetailPaneField(label: "Link Speed", value: linkValue, isMonospaced: true))
        }
        if let orientation = port.plugOrientation {
            connectionFields.append(DetailPaneField(label: "Plug Orientation", value: orientation == 1 ? "Face up" : "Face down"))
        }
        sections.append(DetailPaneSection(title: "Connection", fields: connectionFields))

        // Power: real SMC channel readings, or an honest Unavailable when
        // no channel maps to this port.
        let powerFields: [DetailPaneField]
        if let volts = port.volts, let amps = port.amps {
            powerFields = [
                DetailPaneField(label: "Power", value: String(format: "%.2f W", volts * amps), isMonospaced: true),
                DetailPaneField(label: "Voltage", value: String(format: "%.2f V", volts), isMonospaced: true),
                DetailPaneField(label: "Current", value: String(format: "%.3f A", amps), isMonospaced: true),
            ]
        } else {
            powerFields = [DetailPaneField(label: "Power", value: "Unavailable", isUnavailable: true)]
        }
        sections.append(DetailPaneSection(title: "Power", fields: powerFields))

        // Cable: only when a marked cable's identity was actually read —
        // an unmarked cable is the honest common case, said plainly.
        if let cable = port.cable {
            var cableFields: [DetailPaneField] = []
            if let type = cable.productType {
                cableFields.append(DetailPaneField(label: "Type", value: type + (port.activeCable == true ? " (active)" : "")))
            }
            cableFields.append(DetailPaneField(
                label: "Max Speed",
                value: cable.maxSpeedLabel ?? "Unavailable",
                isUnavailable: cable.maxSpeedLabel == nil
            ))
            cableFields.append(DetailPaneField(
                label: "Current Rating",
                value: cable.currentRatingLabel ?? "Unavailable",
                isUnavailable: cable.currentRatingLabel == nil
            ))
            cableFields.append(DetailPaneField(
                label: "Chip Vendor ID",
                value: cable.vendorID.map { String(format: "0x%04X", $0) } ?? "Unregistered",
                isMonospaced: cable.vendorID != nil
            ))
            // The line that answers "the cable says 80 Gbps, why is my
            // drive slow?": the cable's rating is its own ceiling, while
            // the link runs at the slowest party's speed — say which side
            // is the limit when both numbers are known.
            if let diagnosis = linkDiagnosis(cable: cable, link: port.negotiatedLink) {
                cableFields.append(DetailPaneField(label: "Diagnosis", value: diagnosis))
            }
            // Trust signal — see `USBCableInfo.claimLooksImplausible` for
            // the (deliberately narrow) criteria and the empirical case
            // behind it. Hedged wording on purpose: a flag means "treat
            // this rating skeptically," never "this cable is fake."
            if cable.claimLooksImplausible {
                cableFields.append(DetailPaneField(
                    label: "Warning",
                    value: "\u{26A0}\u{FE0F} Claims 80 Gbps passive from an unregistered vendor \u{2014} treat this rating skeptically"
                ))
            }
            sections.append(DetailPaneSection(title: "Cable (e-marker)", fields: cableFields))
        } else if port.isConnected {
            // Not `isUnavailable` (which would render the literal
            // "Unavailable") — an unmarked cable is a normal state worth
            // an explanation, not a degraded reading.
            sections.append(DetailPaneSection(title: "Cable (e-marker)", fields: [
                DetailPaneField(
                    label: "Identity",
                    value: "No e-marker \u{2014} plain USB 2.0 cables don\u{2019}t carry one"
                ),
            ]))
        }

        if let partner = port.partner {
            var partnerFields: [DetailPaneField] = []
            if let type = partner.productType {
                partnerFields.append(DetailPaneField(label: "Type", value: type))
            }
            partnerFields.append(DetailPaneField(
                label: "Vendor ID",
                value: partner.vendorID.map { String(format: "0x%04X", $0) } ?? "Unavailable",
                isUnavailable: partner.vendorID == nil,
                isMonospaced: partner.vendorID != nil
            ))
            if let productID = partner.productID {
                partnerFields.append(DetailPaneField(label: "Product ID", value: String(format: "0x%04X", productID), isMonospaced: true))
            }
            sections.append(DetailPaneSection(title: "Attached Device (PD identity)", fields: partnerFields))
        }

        var healthFields: [DetailPaneField] = []
        if let liquidDetected = port.liquidDetected {
            healthFields.append(DetailPaneField(label: "Liquid Detection", value: liquidDetected ? "\u{26A0}\u{FE0F} Liquid detected" : "Dry"))
        }
        if let connectionCount = port.connectionCount {
            healthFields.append(DetailPaneField(label: "Connections Since Boot", value: "\(connectionCount)", isMonospaced: true))
        }
        if let overcurrentCount = port.overcurrentCount {
            healthFields.append(DetailPaneField(label: "Overcurrent Events", value: "\(overcurrentCount)", isMonospaced: true))
        }
        if !healthFields.isEmpty {
            sections.append(DetailPaneSection(title: "Port Health", fields: healthFields))
        }

        return sections
    }

    /// Compares the cable's rated ceiling against the link that actually
    /// came up. `nil` (no line at all) unless both numbers are known —
    /// never a guess. The wording is careful about what each case proves:
    /// a link *below* the cable's rating means the cable isn't the limit
    /// (the device or the port is); a link *at* the cable's rating means
    /// the cable is the ceiling being hit — it can't say what the device
    /// could have done with a faster one.
    private func linkDiagnosis(cable: USBCableInfo, link: USBLinkInfo?) -> String? {
        guard let cableGbps = cable.maxSpeedGbps, let link, let linkGbps = link.gbps else { return nil }
        if linkGbps < cableGbps {
            return "Link runs at \(link.rateDescription) \u{2014} limited by the attached device or port, not this cable"
        }
        return "Link runs at \(link.rateDescription) \u{2014} this cable\u{2019}s rated ceiling"
    }

    // MARK: - Devices

    /// The whole bus's device list, indented by topology depth — a plain
    /// indented `List` rather than a full `NSOutlineView` tree: the data
    /// is already flattened parent-before-child by the provider, and USB
    /// trees are shallow enough (a hub or two) that indentation reads
    /// fine without expand/collapse machinery.
    private var devicesSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("USB Devices")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            if let devices = model.snapshot?.devices, !devices.isEmpty {
                List(devices) { device in
                    deviceRow(device)
                }
                .listStyle(.inset)
            } else {
                VStack {
                    Text("No USB devices on the bus.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func deviceRow(_ device: USBDeviceSnapshot) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.callout)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let vendorName = device.vendorName {
                        Text(vendorName)
                    }
                    if let speedLabel = device.speedLabel {
                        Text(speedLabel)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(device.depth) * 18)
    }
}

// MARK: - Cable health test sheet

/// The explicit, user-driven flow around `CableHealthTester` — see that
/// type's doc comment for the method. This sheet's whole job is consent
/// and clarity: the user picks which (external, writable) volume the
/// 512 MB test file goes on, sees what will happen before starting, and
/// gets the verdict with its reasoning rather than a bare number.
private struct CableHealthSheet: View {
    let linkGbps: Double?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = CableHealthViewModel()
    @State private var selectedVolumePath: String?

    /// Every mounted non-system volume — the boot volume is excluded
    /// (testing the internal SSD says nothing about a USB cable), the
    /// rest are offered as-is since `DiskCapacity` doesn't carry an
    /// internal/external flag; the explanatory text tells the user to
    /// pick the volume on the drive behind this cable.
    private var volumes: [DiskCapacity] {
        DiskProvider.readVolumeCapacities().filter { !$0.isSystemVolume }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Test Cable Health")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Writes a temporary 512 MB file to the volume below, reads it back twice (once with 4 MB requests, once with 16 MB), and compares the two: a link that stalls between transfers \u{2014} the signature of a marginal cable \u{2014} shows up as large requests running far faster than small ones. The file is deleted afterwards.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Volume", selection: $selectedVolumePath) {
                ForEach(volumes) { volume in
                    Text(volume.volumeName ?? volume.id).tag(String?.some(volume.id))
                }
            }
            .disabled(model.isRunning)

            if volumes.isEmpty {
                Text("No external volume is mounted \u{2014} the test needs a writable volume on the drive attached through this cable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    if let fraction = model.progressFraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(model.progressPhase ?? "Running\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let result = model.result {
                resultView(result)
            }

            if let failureReason = model.failureReason {
                Text("Test failed: \(failureReason)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer(minLength: 0)
                Button(model.isRunning ? "Cancel Test" : "Close") {
                    if model.isRunning {
                        model.cancel()
                    } else {
                        dismiss()
                    }
                }
                Button("Run Test") {
                    guard let selectedVolumePath else { return }
                    model.run(folderPath: selectedVolumePath, linkGbps: linkGbps)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRunning || selectedVolumePath == nil)
            }
        }
        .padding(16)
        .frame(width: 480, height: 380)
        .onAppear {
            if selectedVolumePath == nil { selectedVolumePath = volumes.first?.id }
        }
    }

    private func resultView(_ result: CableHealthResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                result.verdict.title,
                systemImage: result.verdict == .healthy ? "checkmark.circle" : "exclamationmark.triangle"
            )
            .font(.callout)
            .fontWeight(.semibold)
            .foregroundStyle(result.verdict == .healthy ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange))

            Text(result.verdict.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                measurement("Write", result.writeMBps)
                measurement("Read (4 MB)", result.smallChunkReadMBps)
                measurement("Read (16 MB)", result.largeChunkReadMBps)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func measurement(_ label: String, _ mbps: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(String(format: "%.0f MB/s", mbps))
                .font(.callout)
                .fontWeight(.medium)
                .monospacedDigit()
        }
    }
}

@MainActor
private final class CableHealthViewModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var progressPhase: String?
    @Published private(set) var progressFraction: Double?
    @Published private(set) var result: CableHealthResult?
    @Published private(set) var failureReason: String?

    private let tester = CableHealthTester()
    private var runTask: Task<Void, Never>?

    func run(folderPath: String, linkGbps: Double?) {
        guard !isRunning else { return }
        isRunning = true
        result = nil
        failureReason = nil
        progressPhase = nil
        progressFraction = nil

        let stream = tester.run(folderPath: folderPath, linkGbps: linkGbps)
        runTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .progress(let phase, let fraction):
                    self.progressPhase = phase
                    self.progressFraction = fraction
                case .completed(let testResult):
                    self.result = testResult
                case .failed(let reason):
                    self.failureReason = reason
                case .cancelled:
                    break
                }
            }
            self?.isRunning = false
            self?.progressPhase = nil
            self?.progressFraction = nil
        }
    }

    func cancel() {
        tester.cancelActiveRun()
    }
}

// MARK: - View model

/// Polls `USBPortsProvider` every 2 seconds while the page is visible —
/// page-scoped (a `@StateObject`, started in `onAppear`, stopped in
/// `onDisappear`) rather than app-lifetime like `networkMonitor`: this is
/// live hardware state that's recomputed cheaply on arrival, with nothing
/// accumulated worth preserving across navigation.
@MainActor
final class USBPortsViewModel: ObservableObject {
    @Published private(set) var snapshot: USBPortsSnapshot?
    @Published private(set) var unavailableReason: String?

    private let provider = USBPortsProvider()
    private var pollTask: Task<Void, Never>?

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sampleOnce()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func sampleOnce() {
        do {
            snapshot = try provider.sample()
            unavailableReason = nil
        } catch {
            // Whole-domain failure (no port controllers at all) — keep
            // any prior snapshot off screen and say why.
            snapshot = nil
            unavailableReason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

#Preview {
    USBPortsPage()
        .frame(width: 1100, height: 760)
}
