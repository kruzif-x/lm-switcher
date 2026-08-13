// =============================================================================
//  Launcher.swift — lm-switcher-mcp
//  Mutations shell out to the existing `llama` CLI (MCP_SPEC §3.8):
//  controlled argv, no shell interpolation of agent input. The MCP adds
//  pre-flight (swap guard) and post-flight (health wait) around it.
// =============================================================================

import Foundation

enum Launcher {

    struct CliResult { let status: Int32; let output: String }

    static func runCli(_ args: [String]) -> CliResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: llamaCliPath)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            return CliResult(status: 127, output: "failed to launch \(llamaCliPath): \(error.localizedDescription)")
        }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = [String(data: o, encoding: .utf8) ?? "", String(data: e, encoding: .utf8) ?? ""]
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return CliResult(status: p.terminationStatus, output: text)
    }

    /// Tail of CLI output for load_failed diagnostics.
    static func tail(_ text: String, lines: Int = 12) -> String {
        text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }

    enum LoadOutcome {
        case ready(port: Int, pid: Int32)
        case timeout
        case died(pid: Int32?)
    }

    /// Poll every 500 ms until the model is healthy, its process dies, or
    /// `timeoutS` elapses (§3.8). Re-reads PID files each tick — the user
    /// may unload from the menu bar mid-wait.
    static func waitHealthy(hash: String, backend: String, timeoutS: Int) -> LoadOutcome {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutS))
        var lastPid: Int32? = nil
        while Date() < deadline {
            let running = readRunning(models: discoverModels())
            if let r = running.first(where: { $0.hash == hash }) {
                lastPid = r.pid
                if r.port > 0, probeHealthy(port: r.port, backend: backend),
                   portOwnedBy(pid: r.pid, port: r.port) {
                    // The identity check stops a false "ready" when some
                    // OTHER process already serves that port and our spawn
                    // is about to die on the bind conflict.
                    return .ready(port: r.port, pid: r.pid)
                }
            } else if lastPid != nil {
                return .died(pid: lastPid)   // was up, gone now
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return .timeout
    }

    /// lsof: is `pid` the process listening on `port`?
    static func portOwnedBy(pid: Int32, port: Int) -> Bool {
        guard let occupant = listeningPorts()[port] else { return false }
        return occupant.hasPrefix("pid \(pid) ")
    }
}
