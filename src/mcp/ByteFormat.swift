// =============================================================================
//  ByteFormat.swift — llm-switcher-mcp
//  Base-1024 human formatting (MCP_SPEC §3.6.5): one decimal below 10,
//  none at or above.
// =============================================================================

import Foundation

func humanBytes(_ bytes: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var idx = 0
    while value >= 1024, idx < units.count - 1 {
        value /= 1024
        idx += 1
    }
    if idx == 0 { return "\(bytes) B" }
    return value < 10
        ? String(format: "%.1f %@", value, units[idx])
        : String(format: "%.0f %@", value, units[idx])
}
