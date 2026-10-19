import Foundation
import MCP

/// `get_disk_health` and `get_usb_ports`.
enum HardwareHandlers {
    static func getDiskHealth(registry: ProviderRegistry) async -> CallTool.Result {
        do {
            var snapshot = try await registry.core.sampleDisk()
            // The provider fills SMART status on a background queue; a disk
            // seen for the first time reads nil until that check returns.
            if snapshot.units.contains(where: { $0.smartStatus == nil }) {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                snapshot = try await registry.core.sampleDisk()
            }
            let disks = snapshot.units.map {
                DiskHealthEntryDTO(
                    disk: $0.id,
                    mediaName: $0.mediaName,
                    isInternal: $0.isInternal,
                    smartStatus: $0.smartStatus?.displayLabel
                )
            }
            return jsonResult(DiskHealthResponse(
                disks: disks,
                note: "smartStatus is null when diskutil hadn't answered yet; call again to retry."
            ))
        } catch {
            return errorResult("Failed to read disk health: \(error.localizedDescription)")
        }
    }

    static func getUSBPorts(registry: ProviderRegistry) async -> CallTool.Result {
        do {
            let snapshot = try registry.usbPorts.sample()
            return jsonResult(USBPortsResponse(
                ports: snapshot.ports.map(USBPortDTO.init),
                devices: snapshot.devices.map(USBDeviceDTO.init)
            ))
        } catch {
            return errorResult("Failed to read USB ports: \(error.localizedDescription)")
        }
    }
}
