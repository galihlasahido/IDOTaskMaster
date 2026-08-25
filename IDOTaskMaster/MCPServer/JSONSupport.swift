import Foundation
import MCP

/// Shared JSON encoding + MCP `Tool.Content`/`Value` plumbing used by every
/// tool handler in `MCPServer/Handlers/*.swift`. Kept in one small file so
/// every handler formats its response the same way rather than each
/// reinventing pretty-printing/date-formatting choices.
enum JSON {
    /// `.iso8601` dates (readable timestamps, per the brief) and
    /// `.prettyPrinted, .sortedKeys` output (readable, deterministic key
    /// order) for every tool response this server returns.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// Encodes `value` as a pretty-printed JSON string. Never throws: an
    /// encoding failure (shouldn't happen for these hand-built DTOs, but
    /// this server's own "honest degradation" for its own plumbing) becomes
    /// a small JSON error object instead of crashing the process.
    static func string<T: Encodable>(_ value: T) -> String {
        guard let data = try? encoder.encode(value) else {
            return "{\"error\":\"Failed to encode response as JSON\"}"
        }
        return String(data: data, encoding: .utf8)
            ?? "{\"error\":\"Failed to decode encoded JSON as UTF-8\"}"
    }
}

/// Builds a successful `tools/call` result carrying `value` as one
/// pretty-printed JSON text content block.
func jsonResult<T: Encodable>(_ value: T) -> CallTool.Result {
    CallTool.Result(content: [.text(text: JSON.string(value), annotations: nil, _meta: nil)], isError: false)
}

/// Builds a failed `tools/call` result — `isError: true` with a plain-text
/// explanation, per the MCP spec's convention for a tool-level failure
/// (distinct from a JSON-RPC protocol error).
func errorResult(_ message: String) -> CallTool.Result {
    CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
}

// MARK: - Argument decoding

/// `CallTool.Parameters.arguments` is `[String: Value]?`; these helpers pull
/// out a typed argument leniently (a client that sends a number as a JSON
/// string, e.g. `"50"` instead of `50`, still works) rather than requiring
/// the caller to match `Value`'s exact case.
enum Args {
    static func string(_ arguments: [String: Value]?, _ key: String) -> String? {
        guard let value = arguments?[key], !value.isNull else { return nil }
        return value.stringValue
    }

    static func int(_ arguments: [String: Value]?, _ key: String) -> Int? {
        guard let value = arguments?[key], !value.isNull else { return nil }
        if let intValue = value.intValue { return intValue }
        if let doubleValue = value.doubleValue { return Int(doubleValue) }
        if let stringValue = value.stringValue { return Int(stringValue) }
        return nil
    }

    static func requiredInt(_ arguments: [String: Value]?, _ key: String) -> Int? {
        int(arguments, key)
    }
}

// MARK: - JSON Schema helpers

/// Small builders over `Value` for writing `Tool.inputSchema` literals
/// (plain JSON Schema, draft-agnostic subset) without hand-nesting
/// `.object([...])` everywhere in `ToolDefinitions.swift`.
enum Schema {
    static func object(properties: [String: Value], required: [String] = []) -> Value {
        var fields: [String: Value] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false,
        ]
        if !required.isEmpty {
            fields["required"] = .array(required.map { Value.string($0) })
        }
        return .object(fields)
    }

    static func string(_ description: String, enumValues: [String]? = nil) -> Value {
        var fields: [String: Value] = ["type": "string", "description": .string(description)]
        if let enumValues {
            fields["enum"] = .array(enumValues.map { Value.string($0) })
        }
        return .object(fields)
    }

    static func integer(_ description: String) -> Value {
        .object(["type": "integer", "description": .string(description)])
    }
}
