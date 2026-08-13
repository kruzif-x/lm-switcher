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

let serverInstructions = """
Models can be loaded and unloaded by the user from the menu bar at any \
time — never assume state persists between your calls. Call `status` \
before acting on assumptions. Every mutation response includes a fresh \
state snapshot; treat it as the current truth. Do not load models when \
memory_pressure is "warning" or "critical". Agent access can be disabled \
by the user at any time in LM Switcher settings.
"""

setvbuf(stdout, nil, _IONBF, 0)   // unbuffered — every response flushes

while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    guard let req = RpcRequest.parse(line) else {
        RpcWriter.error(id: nil, code: -32700, message: "Parse error")
        continue
    }

    switch req.method {
    case "initialize":
        let proto = req.params["protocolVersion"] as? String ?? "2024-11-05"
        RpcWriter.result(id: req.id ?? NSNull(), [
            "protocolVersion": proto,
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
        let name = req.params["name"] as? String ?? ""
        let args = req.params["arguments"] as? [String: Any] ?? [:]
        RpcWriter.result(id: req.id ?? NSNull(), McpTools.call(name: name, args: args))

    default:
        if req.id != nil {
            RpcWriter.error(id: req.id, code: -32601, message: "Method not found: \(req.method)")
        }
    }
}
