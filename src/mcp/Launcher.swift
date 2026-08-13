// =============================================================================
//  Launcher.swift — lm-switcher-mcp
//  Mutations shell out to the existing `llama` CLI (MCP_SPEC §3.8):
//  controlled argv, no shell interpolation of agent input. The MCP adds
//  pre-flight (swap guard) and post-flight (health wait) around it.
// =============================================================================

import Foundation

enum Launcher {

    struct CliResult { let status: Int32; let output: String }

    /// Wall-clock cap on any single `llama` CLI invocation. A hung child
    /// (blocking on a model download, a stuck mmap, a wedged pipe) must not
    /// freeze the MCP stdio loop — that makes the agent think the server is
    /// dead and may get it killed. We terminate the child if it exceeds this.
    static let cliTimeout: TimeInterval = 60

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

        // M1 fix: drain BOTH pipes concurrently. The previous code read stdout
        // to EOF, THEN stderr to EOF, then waited. If the child wrote more
        // than the ~64KB pipe buffer to stderr while we were blocked reading
        // stdout, the stderr write blocked forever and `readDataToEndOfFile`
        // on stdout never returned — a classic deadlock. Reading each pipe on
        // its own queue means neither pipe can fill and stall the child.
        var outData = Data()
        var errData = Data()
        let outGroup = DispatchGroup()
        let outQueue = DispatchQueue(label: "mcp.cli.stdout")
        let errQueue = DispatchQueue(label: "mcp.cli.stderr")
        outGroup.enter()
        outQueue.async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            outGroup.leave()
        }
        outGroup.enter()
        errQueue.async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            outGroup.leave()
        }

        // Bounded wait: if the child doesn't exit within `cliTimeout`,
        // terminate it so the MCP loop stays responsive. `waitUntilExit`
        // would otherwise block forever on a wedged child.
        let waitResult = outGroup.wait(timeout: .now() + cliTimeout)
        if waitResult == .timedOut {
            // Best-effort cleanup. Terminate and drain the rest so file
            // handles don't leak; the partial output may still be useful.
            if p.isRunning { p.terminate() }
            outGroup.wait()
        }
        p.waitUntilExit()

        // Close both read ends explicitly (resource hygiene).
        try? out.fileHandleForReading.close()
        try? err.fileHandleForReading.close()

        let text = [String(data: outData, encoding: .utf8) ?? "",
                    String(data: errData, encoding: .utf8) ?? ""]
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
