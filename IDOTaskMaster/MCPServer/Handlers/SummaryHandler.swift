import Darwin
import Foundation
import MCP

/// `get_summary` — samples all eight `CoreProviderHub` domains plus a live
/// process count, matching `Sampler.tick()`'s own "one bad provider must not
/// take the others down" per-domain isolation (see that method's doc
/// comment in `Core/Sampler.swift`).
enum SummaryHandler {
    static func handle(registry: ProviderRegistry) async -> CallTool.Result {
        var response = SummaryResponse(errors: [:])

        do {
            response.cpu = CPUDTO(try await registry.core.sampleCPU())
        } catch {
            response.errors["cpu"] = error.localizedDescription
        }
        do {
            response.memory = MemoryDTO(try await registry.core.sampleMemory())
        } catch {
            response.errors["memory"] = error.localizedDescription
        }
        do {
            response.gpu = GPUDTO(try await registry.core.sampleGPU())
        } catch {
            response.errors["gpu"] = error.localizedDescription
        }
        do {
            response.disk = DiskDTO(try await registry.core.sampleDisk())
        } catch {
            response.errors["disk"] = error.localizedDescription
        }
        do {
            response.network = NetworkDTO(try await registry.core.sampleNetwork())
        } catch {
            response.errors["network"] = error.localizedDescription
        }
        do {
            response.energy = EnergyDTO(try await registry.core.sampleEnergy())
        } catch {
            response.errors["energy"] = error.localizedDescription
        }
        do {
            response.thermal = ThermalDTO(try await registry.core.sampleThermal())
        } catch {
            response.errors["thermal"] = error.localizedDescription
        }
        do {
            response.npu = NPUDTO(try await registry.core.sampleNPU())
        } catch {
            response.errors["npu"] = error.localizedDescription
        }

        // Same cheap `proc_listallpids(nil, 0)` estimate call
        // `Core/Sampler.swift`'s `tick()` uses for its own `processCount`.
        let rawProcessCount = proc_listallpids(nil, 0)
        response.processCount = rawProcessCount > 0 ? Int(rawProcessCount) : nil

        return jsonResult(response)
    }
}
