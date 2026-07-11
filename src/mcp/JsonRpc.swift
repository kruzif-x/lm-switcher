// =============================================================================
//  JsonRpc.swift — llm-switcher-mcp
//  Minimal JSON-RPC 2.0 over newline-delimited stdio (MCP_SPEC §3.2).
//  Dynamic [String: Any] payloads via JSONSerialization — the protocol
//  surface is small and schemaless enough that Codable buys nothing here.
// =============================================================================

import Foundation

struct RpcRequest {
    /// nil id ⇒ notification (no response may be sent).
    let id: Any?
    let method: String
    let params: [String: Any]

    static func parse(_ line: String) -> RpcRequest? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = obj["method"] as? String else { return nil }
        return RpcRequest(
            id: obj["id"],
            method: method,
            params: obj["params"] as? [String: Any] ?? [:]
        )
    }
}

enum RpcWriter {
    /// Serialize one JSON object as a single line on stdout and flush.
    private static func emit(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func result(id: Any, _ result: [String: Any]) {
        emit(["jsonrpc": "2.0", "id": id, "result": result])
    }

    /// Protocol-level error (unknown method, parse error) — NOT tool errors,
    /// which travel as results with isError: true (MCP_SPEC §3.4).
    static func error(id: Any?, code: Int, message: String) {
        emit(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }
}
