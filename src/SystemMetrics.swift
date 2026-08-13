// =============================================================================
//  SystemMetrics.swift — SHARED between the app and lm-switcher-mcp
//  RAM / memory pressure / swap / per-process RSS (MCP_SPEC §3.6).
//  Clean-room implementations on public Apple APIs only.
//
//  This is the single deliberate exception to the spec's "MCP shares no
//  source files with the app" rule (noted in MCP_SPEC §3.1): read-only
//  metrics with no side effects and no protocol surface. The app uses it
//  for the menu footer memory line; the MCP for state snapshots.
// =============================================================================

import Foundation
import Darwin

struct SystemMetrics {
    let ramTotal: UInt64
    let ramUsed: UInt64
    let memoryPressure: String   // "normal" | "warning" | "critical" | "unknown"
    let swapTotal: UInt64
    let swapUsed: UInt64

    var ramAvailable: UInt64 { ramTotal > ramUsed ? ramTotal - ramUsed : 0 }

    static func read() -> SystemMetrics {
        SystemMetrics(
            ramTotal: ProcessInfo.processInfo.physicalMemory,
            ramUsed: Self.ramUsedBytes(),
            memoryPressure: Self.pressureLevel(),
            swapTotal: Self.swapUsage()?.total ?? 0,
            swapUsed: Self.swapUsage()?.used ?? 0
        )
    }

    /// used = total − (free + speculative + file-backed) × page_size —
    /// matches Activity Monitor (MCP_SPEC §3.6.1).
    private static func ramUsedBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        // The host port must be deallocated each call or it leaks.
        defer { mach_port_deallocate(mach_task_self_, host) }

        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }

        let pageSize = UInt64(vm_kernel_page_size)
        let total = ProcessInfo.processInfo.physicalMemory
        let notUsed = (UInt64(stats.free_count)
                     + UInt64(stats.speculative_count)
                     + UInt64(stats.external_page_count)) * pageSize
        return total > notUsed ? total - notUsed : 0
    }

    /// sysctl kern.memorystatus_vm_pressure_level: 1 → normal, 2 → warning,
    /// 4 → critical (MCP_SPEC §3.6.2).
    private static func pressureLevel() -> String {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return "unknown"
        }
        switch level {
        case 1: return "normal"
        case 2: return "warning"
        case 4: return "critical"
        default: return "unknown"
        }
    }

    /// sysctl vm.swapusage → xsw_usage (MCP_SPEC §3.6.3).
    private static func swapUsage() -> (total: UInt64, used: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (usage.xsu_total, usage.xsu_used)
    }

    /// Per-model RSS via `ps -o rss= -p <pid>` (KB → bytes, MCP_SPEC §3.6.4).
    static func rssBytes(pid: Int32) -> UInt64? {
        guard let out = runCapture("/bin/ps", ["-o", "rss=", "-p", "\(pid)"]),
              let kb = UInt64(out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return kb * 1024
    }
}

/// Run a subprocess with controlled argv (never a shell) and capture stdout.
/// Returns nil on spawn failure or non-zero exit with empty output.
func runCapture(_ path: String, _ args: [String], env: [String: String]? = nil) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let env { p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new } }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)
}
