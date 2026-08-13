// =============================================================================
//  main.swift — lm-switcher-mcp
//  MCP over stdio: newline-delimited JSON-RPC 2.0 (MCP_SPEC §3.2).
//  Handles initialize, notifications/initialized, ping, tools/list,
//  tools/call. Unknown methods → JSON-RPC method-not-found.
//
//  Standalone by construction: shares no source files with the app.
//  Registration: hermes mcp add lm-switcher --command ~/bin/lm-switcher-mcp
// =============================================================================

import Foundation

let serverVersion = "1.3.0"

/// M6 fix: advertise a version WE actually support, rather than echoing
/// whatever protocolVersion the client sends. Echoing an attacker-chosen
/// string let a client believe the server agreed to a protocol version it
/// doesn't implement. 2024-11-05 is the MCP version this server targets.
let supportedProtocolVersion = "2024-11-05"

let serverInstructions = """
Models can be loaded and unloaded by the user from the menu bar at any \
time — never assume state persists between your calls. Call `status` \
before acting on assumptions. Every mutation response includes a fresh \
state snapshot; treat it as the current truth. Do not load models when \
memory_pressure is "warning" or "critical". Agent access can be disabled \
by the user at any time in LM Switcher settings.
"""

setvbuf(stdout, nil, _IONBF, 0)   // unbuffered — every response flushes

// M2 fix: read stdio with a per-line size cap instead of `readLine()`,
// which buffers an entire line into memory with no bound. A single huge
// line (or deeply nested JSON) from a buggy/compromised client could
// OOM-kill this process and take down the agent's connection. We cap each
// line at 1 MiB; anything larger gets a parse error and is discarded.
let maxLineBytes = 1 << 20

/// Read one newline-terminated line from stdin, capped at `maxLineBytes`.
/// Returns nil at EOF. Lines exceeding the cap return the partial buffer
/// flagged as truncated (caller emits a parse error and continues).
func readBoundedLine() -> (line: String?, truncated: Bool) {
    var buf = [UInt8]()
    buf.reserveCapacity(256)
    var truncated = false
    while true {
        var b = UInt8(0)
        let n = read(STDIN_FILENO, &b, 1)
        if n <= 0 {
            if buf.isEmpty { return (nil, false) }
            break   // EOF mid-line: return what we have
        }
        if b == 0x0A { break }   // newline
        buf.append(b)
        if buf.count > maxLineBytes {
            truncated = true
            break
        }
    }
    // If truncated, drain the rest of the oversized line so the next read
    // starts at a clean line boundary.
    if truncated {
        var b = UInt8(0)
        while read(STDIN_FILENO, &b, 1) > 0, b != 0x0A {}
    }
    return (String(bytes: buf, encoding: .utf8), truncated)
}

while true {
    let (rawLine, truncated) = readBoundedLine()
    guard let line = rawLine else { break }   // EOF — client gone
    if truncated {
        FileHandle.standardError.write("oversized line (>1 MiB) skipped\n".data(using: .utf8) ?? Data())
        RpcWriter.error(id: nil, code: -32700, message: "Parse error: line too long")
        continue
    }
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    guard let req = RpcRequest.parse(line) else {
        RpcWriter.error(id: nil, code: -32700, message: "Parse error")
        continue
    }

    switch req.method {
    case "initialize":
        RpcWriter.result(id: req.id ?? NSNull(), [
            "protocolVersion": supportedProtocolVersion,
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": ["name": "lm-switcher", "version": serverVersion],
            "instructions": serverInstructions,
        ])

    case "notifications/initialized", "notifications/cancelled":
        break   // notifications get no response

    case "ping":
        RpcWriter.result(id: req.id ?? NSNull(), [:])

    case "tools/list":
        // Stays visible when agent access is disabled (§9.3) — schema
        // discovery is harmless and avoids stale tool caches.
        RpcWriter.result(id: req.id ?? NSNull(), ["tools": McpTools.toolsList()])

    case "tools/call":
        // M7 fix: validate params at the RPC layer. A missing/empty `name`
        // or a non-object `arguments` is a client bug, not a "tool not
        // found" — return JSON-RPC -32602 Invalid params so well-behaved
        // clients can distinguish protocol errors from tool errors.
        guard let name = req.params["name"] as? String, !name.isEmpty else {
            RpcWriter.error(id: req.id, code: -32602,
                            message: "Invalid params: 'name' must be a non-empty string")
            continue
        }
        if req.params["arguments"] != nil, !(req.params["arguments"] is [String: Any]) {
            RpcWriter.error(id: req.id, code: -32602,
                            message: "Invalid params: 'arguments' must be an object")
            continue
        }
        let args = req.params["arguments"] as? [String: Any] ?? [:]
        RpcWriter.result(id: req.id ?? NSNull(), McpTools.call(name: name, args: args))

    default:
        if req.id != nil {
            RpcWriter.error(id: req.id, code: -32601, message: "Method not found: \(req.method)")
        }
    }
}
