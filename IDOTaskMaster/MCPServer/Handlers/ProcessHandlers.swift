import Darwin
import Foundation
import MCP

/// `list_processes`, `get_top_processes`, and `get_process_detail`.
enum ProcessHandlers {
    static func listProcesses(registry: ProviderRegistry, arguments: [String: Value]?) async -> CallTool.Result {
        let filter = Args.string(arguments, "filter")?.lowercased()
        let limit = Args.int(arguments, "limit") ?? 50

        do {
            let forest = try await registry.process.sample()
            var matched = forest.all
            if let filter, !filter.isEmpty {
                matched = matched.filter { reading in
                    (reading.name?.lowercased().contains(filter) ?? false)
                        || (reading.userName?.lowercased().contains(filter) ?? false)
                }
            }
            matched.sort { ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending }
            let limited = limit > 0 ? Array(matched.prefix(limit)) : matched

            return jsonResult(ListProcessesResponse(
                totalMatched: matched.count,
                returned: limited.count,
                processes: limited.map(ProcessDTO.init)
            ))
        } catch {
            return errorResult("Failed to list processes: \(error.localizedDescription)")
        }
    }

    static func getTopProcesses(registry: ProviderRegistry, arguments: [String: Value]?) async -> CallTool.Result {
        let limit = Args.int(arguments, "limit") ?? 12

        do {
            var readings = try await registry.topProcesses.sample()
            readings.sort { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }
            let limited = limit > 0 ? Array(readings.prefix(limit)) : readings
            return jsonResult(limited.map(TopProcessDTO.init))
        } catch {
            return errorResult("Failed to sample top processes: \(error.localizedDescription)")
        }
    }

    static func getProcessDetail(registry: ProviderRegistry, arguments: [String: Value]?) async -> CallTool.Result {
        guard let pidValue = Args.requiredInt(arguments, "pid") else {
            return errorResult("Missing or invalid required argument \"pid\".")
        }
        let pid = pid_t(pidValue)

        var response = ProcessDetailResponse()

        do {
            let forest = try await registry.process.sample()
            if let reading = forest.all.first(where: { $0.pid == pid }) {
                response.process = ProcessDTO(reading)
            } else {
                response.processError = "No running process with pid \(pid) was found in this tick's process list."
            }
        } catch {
            response.processError = "Failed to sample the process list: \(error.localizedDescription)"
        }

        response.signing = SigningInfoDTO(await registry.signingInfo.signingInfo(forPID: pid))

        do {
            let catalog = try await registry.openFiles.openFiles(forPID: pid)
            response.openFiles = OpenFilesDTO(catalog)
        } catch {
            response.openFilesError = error.localizedDescription
        }

        return jsonResult(response)
    }
}
