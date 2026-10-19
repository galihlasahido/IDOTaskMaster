import Foundation

/// Registers the bundled `IDOTaskMasterMCP` helper with AI coding tools so
/// the user never has to hand-edit their configs, and repoints an existing
/// registration when the app is moved or updated.
///
/// Nothing here creates a registration on its own: `autoSyncOnLaunch()` only
/// rewrites an entry the user already created from Settings ▸ Integrations,
/// and only when it points somewhere other than this app's helper.

// MARK: - JSONC editing

/// Minimal text-level editor for JSON-with-comments files.
///
/// It edits the file as text instead of parsing and re-serializing it, so
/// comments, key order, indentation and every unrelated value (API keys
/// included) stay byte-for-byte identical.
enum JSONCEditor {
    enum EditError: Error, LocalizedError {
        case notAnObject
        case mcpIsNotAnObject
        case producedInvalidJSON

        var errorDescription: String? {
            switch self {
            case .notAnObject: return "The config file's top level is not a JSON object."
            case .mcpIsNotAnObject: return "The config's \"mcp\" entry exists but is not an object."
            case .producedInvalidJSON: return "The edit would have produced invalid JSON, so nothing was written."
            }
        }
    }

    private struct Member {
        let key: String
        let start: Int
        let valueStart: Int
        let valueEnd: Int
    }

    private struct ObjectScan {
        let open: Int
        let members: [Member]
    }

    // MARK: Public

    /// Returns `text` with `root[section][key] = valueJSON` set, creating the
    /// section when absent.
    static func upsert(_ text: String, section: String, key: String, valueJSON: String) throws -> String {
        var bytes = Array(text.utf8)
        guard let root = scanObject(bytes, from: firstSignificant(bytes, from: 0)) else { throw EditError.notAnObject }

        guard let sectionMember = root.members.first(where: { $0.key == section }) else {
            let entry = "\n  \"\(section)\": {\n    \"\(key)\": \(valueJSON)\n  }" + (root.members.isEmpty ? "\n" : ",")
            bytes.insert(contentsOf: Array(entry.utf8), at: root.open + 1)
            return try validated(bytes)
        }

        guard bytes[sectionMember.valueStart] == UInt8(ascii: "{"),
              let inner = scanObject(bytes, from: sectionMember.valueStart) else { throw EditError.mcpIsNotAnObject }

        if let existing = inner.members.first(where: { $0.key == key }) {
            bytes.replaceSubrange(existing.valueStart..<existing.valueEnd, with: Array(valueJSON.utf8))
        } else {
            let entry = "\n    \"\(key)\": \(valueJSON)" + (inner.members.isEmpty ? "\n  " : ",")
            bytes.insert(contentsOf: Array(entry.utf8), at: inner.open + 1)
        }
        return try validated(bytes)
    }

    /// Returns `text` without `root[section][key]`. A missing section or key
    /// returns `text` unchanged.
    static func remove(_ text: String, section: String, key: String) throws -> String {
        var bytes = Array(text.utf8)
        guard let root = scanObject(bytes, from: firstSignificant(bytes, from: 0)) else { throw EditError.notAnObject }
        guard let sectionMember = root.members.first(where: { $0.key == section }),
              bytes[sectionMember.valueStart] == UInt8(ascii: "{"),
              let inner = scanObject(bytes, from: sectionMember.valueStart),
              let found = inner.members.first(where: { $0.key == key }) else { return text }

        let removesWholeSection = inner.members.count == 1
        let target = removesWholeSection ? sectionMember : found

        var lower = target.start
        var upper = target.valueEnd

        let afterValue = firstSignificant(bytes, from: upper)
        if afterValue < bytes.count, bytes[afterValue] == UInt8(ascii: ",") {
            upper = afterValue + 1
        } else {
            var back = lower - 1
            while back >= 0, isWhitespace(bytes[back]) { back -= 1 }
            if back >= 0, bytes[back] == UInt8(ascii: ",") { lower = back }
        }

        var lineStart = lower
        while lineStart > 0, bytes[lineStart - 1] == UInt8(ascii: " ") || bytes[lineStart - 1] == UInt8(ascii: "\t") {
            lineStart -= 1
        }
        var lineEnd = upper
        while lineEnd < bytes.count, bytes[lineEnd] == UInt8(ascii: " ") || bytes[lineEnd] == UInt8(ascii: "\t") {
            lineEnd += 1
        }
        let ownsLine = (lineStart == 0 || bytes[lineStart - 1] == UInt8(ascii: "\n"))
            && lineEnd < bytes.count && bytes[lineEnd] == UInt8(ascii: "\n")
        if ownsLine {
            lower = lineStart
            upper = lineEnd + 1
        }

        bytes.removeSubrange(lower..<upper)
        return try validated(bytes)
    }

    /// Parses JSON-with-comments (comments and trailing commas allowed).
    static func parse(_ text: String) -> [String: Any]? {
        let cleaned = stripped(Array(text.utf8))
        return (try? JSONSerialization.jsonObject(with: Data(cleaned))) as? [String: Any]
    }

    // MARK: Scanning

    private static func isWhitespace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
    }

    /// First index at or after `index` that is neither whitespace nor inside a comment.
    private static func firstSignificant(_ bytes: [UInt8], from index: Int) -> Int {
        var i = index
        while i < bytes.count {
            let b = bytes[i]
            if isWhitespace(b) {
                i += 1
            } else if b == UInt8(ascii: "/"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "/") {
                while i < bytes.count, bytes[i] != 0x0A { i += 1 }
            } else if b == UInt8(ascii: "/"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "*") {
                i += 2
                while i + 1 < bytes.count, !(bytes[i] == UInt8(ascii: "*") && bytes[i + 1] == UInt8(ascii: "/")) { i += 1 }
                i += 2
            } else {
                break
            }
        }
        return min(i, bytes.count)
    }

    /// Index just past the string literal that opens at `index`.
    private static func skipString(_ bytes: [UInt8], from index: Int) -> Int {
        var i = index + 1
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "\\") { i += 2; continue }
            if bytes[i] == UInt8(ascii: "\"") { return i + 1 }
            i += 1
        }
        return bytes.count
    }

    /// Index just past the JSON value that starts at `index`.
    private static func skipValue(_ bytes: [UInt8], from index: Int) -> Int {
        guard index < bytes.count else { return index }
        let first = bytes[index]
        if first == UInt8(ascii: "\"") { return skipString(bytes, from: index) }
        if first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
            var depth = 0
            var i = index
            while i < bytes.count {
                let b = bytes[i]
                if b == UInt8(ascii: "\"") { i = skipString(bytes, from: i); continue }
                if b == UInt8(ascii: "/"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "/") || bytes[i + 1] == UInt8(ascii: "*") {
                    i = firstSignificant(bytes, from: i)
                    continue
                }
                if b == UInt8(ascii: "{") || b == UInt8(ascii: "[") { depth += 1 }
                if b == UInt8(ascii: "}") || b == UInt8(ascii: "]") {
                    depth -= 1
                    if depth == 0 { return i + 1 }
                }
                i += 1
            }
            return bytes.count
        }
        var i = index
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: ",") || b == UInt8(ascii: "}") || b == UInt8(ascii: "]") || isWhitespace(b) || b == UInt8(ascii: "/") { break }
            i += 1
        }
        return i
    }

    private static func scanObject(_ bytes: [UInt8], from open: Int) -> ObjectScan? {
        guard open < bytes.count, bytes[open] == UInt8(ascii: "{") else { return nil }
        var members: [Member] = []
        var i = firstSignificant(bytes, from: open + 1)
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "}") { return ObjectScan(open: open, members: members) }
            guard bytes[i] == UInt8(ascii: "\"") else { return nil }
            let keyEnd = skipString(bytes, from: i)
            let keyBytes = Array(bytes[(i + 1)..<(keyEnd - 1)])
            let key = String(decoding: keyBytes, as: UTF8.self)
            let colon = firstSignificant(bytes, from: keyEnd)
            guard colon < bytes.count, bytes[colon] == UInt8(ascii: ":") else { return nil }
            let valueStart = firstSignificant(bytes, from: colon + 1)
            let valueEnd = skipValue(bytes, from: valueStart)
            members.append(Member(key: key, start: i, valueStart: valueStart, valueEnd: valueEnd))
            i = firstSignificant(bytes, from: valueEnd)
            if i < bytes.count, bytes[i] == UInt8(ascii: ",") { i = firstSignificant(bytes, from: i + 1) }
        }
        return nil
    }

    /// Removes comments and trailing commas so `JSONSerialization` can read the text.
    private static func stripped(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "\"") {
                let end = skipString(bytes, from: i)
                out.append(contentsOf: bytes[i..<end])
                i = end
            } else if b == UInt8(ascii: "/"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "/") || bytes[i + 1] == UInt8(ascii: "*") {
                i = firstSignificant(bytes, from: i)
                out.append(0x20)
            } else if b == UInt8(ascii: ",") {
                let next = firstSignificant(bytes, from: i + 1)
                if next < bytes.count, bytes[next] == UInt8(ascii: "}") || bytes[next] == UInt8(ascii: "]") {
                    i += 1
                } else {
                    out.append(b)
                    i += 1
                }
            } else {
                out.append(b)
                i += 1
            }
        }
        return out
    }

    private static func validated(_ bytes: [UInt8]) throws -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        guard parse(text) != nil else { throw EditError.producedInvalidJSON }
        return text
    }
}

// MARK: - Targets

enum MCPTarget: String, CaseIterable, Identifiable {
    case claudeCode
    case openCode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .openCode: return "OpenCode"
        }
    }
}

struct MCPTargetState: Equatable {
    enum Status: Equatable {
        /// The tool isn't installed on this Mac.
        case notInstalled
        case notRegistered
        case registered
        /// Registered, but pointing at a different binary than this app's helper.
        case stale(registeredPath: String)
    }

    var status: Status
    /// Where the registration lives, shown to the user so nothing is hidden.
    var location: String
}

enum MCPIntegrationError: Error, LocalizedError {
    case helperMissing
    case toolMissing(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "This build has no bundled MCP helper. Use a release build of the app."
        case .toolMissing(let name):
            return "\(name) wasn't found on this Mac."
        case .commandFailed(let message):
            return message
        }
    }
}

// MARK: - Integration logic

enum MCPIntegration {
    static let serverName = "idotaskmaster"
    static let autoSyncDefaultsKey = "mcpAutoSync"

    static var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/IDOTaskMasterMCP").path
    }

    static var helperAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: helperPath)
    }

    /// Debug builds run from DerivedData; auto-sync must not repoint a user's
    /// registration at a path that disappears on the next clean.
    static var runsFromInstalledLocation: Bool {
        let path = Bundle.main.bundleURL.path
        let home = homeDirectory
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    static var autoSyncEnabled: Bool {
        get { UserDefaults.standard.object(forKey: autoSyncDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoSyncDefaultsKey) }
    }

    // MARK: Claude Code

    /// The directory every config path hangs off. Tests point it at a scratch
    /// directory; `NSHomeDirectory()` ignores the `HOME` environment variable.
    static var homeDirectory = NSHomeDirectory()
    private static var home: String { homeDirectory }
    private static var claudeConfigPath: String { home + "/.claude.json" }

    static func claudeExecutable() -> String? {
        let candidates = [
            home + "/.local/bin/claude",
            home + "/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }
        let found = run("/bin/zsh", ["-lc", "command -v claude"])
        let path = found.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if found.status == 0, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) { return path }
        return nil
    }

    static func claudeState() -> MCPTargetState {
        let location = "Claude Code user config (~/.claude.json)"
        guard claudeExecutable() != nil else { return MCPTargetState(status: .notInstalled, location: location) }
        guard let data = FileManager.default.contents(atPath: claudeConfigPath),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let entry = servers[serverName] as? [String: Any] else {
            return MCPTargetState(status: .notRegistered, location: location)
        }
        let command = entry["command"] as? String ?? ""
        return MCPTargetState(status: command == helperPath ? .registered : .stale(registeredPath: command), location: location)
    }

    static func registerClaude() throws {
        guard helperAvailable else { throw MCPIntegrationError.helperMissing }
        guard let claude = claudeExecutable() else { throw MCPIntegrationError.toolMissing("Claude Code") }
        _ = run(claude, ["mcp", "remove", serverName, "-s", "user"])
        let result = run(claude, ["mcp", "add", "-s", "user", serverName, "--", helperPath])
        guard result.status == 0 else {
            throw MCPIntegrationError.commandFailed(result.output.isEmpty ? "claude mcp add failed (exit \(result.status))." : result.output)
        }
    }

    static func unregisterClaude() throws {
        guard let claude = claudeExecutable() else { throw MCPIntegrationError.toolMissing("Claude Code") }
        let result = run(claude, ["mcp", "remove", serverName, "-s", "user"])
        guard result.status == 0 else {
            throw MCPIntegrationError.commandFailed(result.output.isEmpty ? "claude mcp remove failed (exit \(result.status))." : result.output)
        }
    }

    // MARK: OpenCode

    private static var openCodeDirectory: String { home + "/.config/opencode" }

    private static func openCodeConfigPath() -> String {
        let jsonc = openCodeDirectory + "/opencode.jsonc"
        let json = openCodeDirectory + "/opencode.json"
        if FileManager.default.fileExists(atPath: jsonc) { return jsonc }
        if FileManager.default.fileExists(atPath: json) { return json }
        return json
    }

    private static func openCodeInstalled() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: openCodeDirectory) { return true }
        return [home + "/.opencode/bin/opencode", "/opt/homebrew/bin/opencode", "/usr/local/bin/opencode"]
            .contains { fm.isExecutableFile(atPath: $0) }
    }

    static func openCodeState() -> MCPTargetState {
        let path = openCodeConfigPath()
        let location = path.replacingOccurrences(of: home, with: "~")
        guard openCodeInstalled() else { return MCPTargetState(status: .notInstalled, location: location) }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let root = JSONCEditor.parse(text),
              let servers = root["mcp"] as? [String: Any],
              let entry = servers[serverName] as? [String: Any] else {
            return MCPTargetState(status: .notRegistered, location: location)
        }
        let command = (entry["command"] as? [String])?.first ?? ""
        return MCPTargetState(status: command == helperPath ? .registered : .stale(registeredPath: command), location: location)
    }

    private static func openCodeEntryJSON() -> String {
        let escaped = helperPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "{ \"type\": \"local\", \"command\": [\"\(escaped)\"], \"enabled\": true }"
    }

    static func registerOpenCode() throws {
        guard helperAvailable else { throw MCPIntegrationError.helperMissing }
        let path = openCodeConfigPath()
        let existing = try? String(contentsOfFile: path, encoding: .utf8)
        let base = existing ?? "{\n  \"$schema\": \"https://opencode.ai/config.json\"\n}\n"
        let updated = try JSONCEditor.upsert(base, section: "mcp", key: serverName, valueJSON: openCodeEntryJSON())
        try writeOpenCodeConfig(updated, to: path, backingUp: existing != nil)
    }

    static func unregisterOpenCode() throws {
        let path = openCodeConfigPath()
        guard let existing = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let updated = try JSONCEditor.remove(existing, section: "mcp", key: serverName)
        guard updated != existing else { return }
        try writeOpenCodeConfig(updated, to: path, backingUp: true)
    }

    /// Keeps the very first copy of the user's config as `<name>.idotaskmaster.bak`
    /// and never overwrites it, so the pre-integration file is always recoverable.
    private static func writeOpenCodeConfig(_ text: String, to path: String, backingUp: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: openCodeDirectory, withIntermediateDirectories: true)
        let backup = path + ".idotaskmaster.bak"
        if backingUp, fm.fileExists(atPath: path), !fm.fileExists(atPath: backup) {
            try fm.copyItem(atPath: path, toPath: backup)
        }
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: Generic

    static func state(for target: MCPTarget) -> MCPTargetState {
        switch target {
        case .claudeCode: return claudeState()
        case .openCode: return openCodeState()
        }
    }

    static func register(_ target: MCPTarget) throws {
        switch target {
        case .claudeCode: try registerClaude()
        case .openCode: try registerOpenCode()
        }
    }

    static func unregister(_ target: MCPTarget) throws {
        switch target {
        case .claudeCode: try unregisterClaude()
        case .openCode: try unregisterOpenCode()
        }
    }

    /// Repoints registrations the user already made. Never creates new ones.
    static func autoSyncOnLaunch() {
        guard autoSyncEnabled, runsFromInstalledLocation, helperAvailable else { return }
        DispatchQueue.global(qos: .utility).async {
            for target in MCPTarget.allCases {
                if case .stale = state(for: target).status {
                    try? register(target)
                }
            }
        }
    }

    // MARK: Process helper

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = homeDirectory
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
