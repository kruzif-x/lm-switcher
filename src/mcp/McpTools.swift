// =============================================================================
//  McpTools.swift — lm-switcher-mcp
//  Tool registry, schemas, dispatch (MCP_SPEC §3.3–3.4).
//  Every response — success or error — embeds a fresh state snapshot.
// =============================================================================

import Foundation

enum McpTools {

    // MARK: - Registry (visible even when access is disabled — §9.3)

    static func toolsList() -> [[String: Any]] {
        func tool(_ name: String, _ desc: String, _ props: [String: Any], _ required: [String]) -> [String: Any] {
            ["name": name, "description": desc,
             "inputSchema": ["type": "object", "properties": props, "required": required]]
        }
        let name = ["type": "string", "description": "Model name — case-insensitive substring; exact match wins"]
        let ctx = ["type": "integer", "description": "Ephemeral context size for this launch only (never persisted)"]
        return [
            tool("status", "Fresh snapshot of running models, ports, and system memory. Call before acting on assumptions.", [:], []),
            tool("list_models", "All discovered models with backend, size, max context, running state, and pin status.", [:], []),
            tool("load_model", "Load a model and block until its endpoint is healthy. Refused if it would not fit in free RAM (unless the user allows swap loads).",
                 ["name": name, "ctx_size": ctx,
                  "port": ["type": "integer", "description": "Ephemeral port for this launch only"],
                  "timeout_s": ["type": "integer", "description": "Health-wait timeout, default 180, clamped 10–600"]],
                 ["name"]),
            tool("unload_model", "Unload one model. Pinned models are refused — the user pinned them.",
                 ["name": name], ["name"]),
            tool("unload_all", "Unload every running model except pinned ones (reported as skipped_pinned).", [:], []),
            tool("switch_model", "Load a model, verify it is healthy, then unload everything else (except pinned). Set unload_first when both do not fit in RAM together.",
                 ["name": name, "ctx_size": ctx,
                  "unload_first": ["type": "boolean", "description": "Unload current models before loading — frees RAM but has a downtime window"]],
                 ["name"]),
            tool("get_settings", "Read-only dump of global settings, per-model overrides, and toggle states.", [:], []),
        ]
    }

    // MARK: - Result plumbing

    private static func payload(_ dict: [String: Any], isError: Bool = false) -> [String: Any] {
        var body = dict
        body["state"] = stateSnapshot()
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
        return ["content": [["type": "text", "text": String(data: data, encoding: .utf8) ?? "{}"]],
                "isError": isError]
    }

    private static func failure(_ code: String, _ message: String, extra: [String: Any] = [:]) -> [String: Any] {
        var body: [String: Any] = ["error_code": code, "message": message]
        for (k, v) in extra { body[k] = v }
        return payload(body, isError: true)
    }

    // MARK: - Dispatch

    static func call(name: String, args: [String: Any]) -> [String: Any] {
        // Fresh gate read on EVERY call (§3.9); tools/list stays visible.
        Prefs.sync()
        guard Prefs.bool("mcpEnabled") else {
            return failure("agent_access_disabled",
                "Agent access is disabled. The user can enable it in LM Switcher → Settings → Global → Agent access (MCP). Running models are unaffected.")
        }
        switch name {
        case "status":        return payload(["ok": true])
        case "list_models":   return listModels()
        case "get_settings":  return getSettings()
        case "load_model":    return loadModel(args)
        case "unload_model":  return unloadModel(args)
        case "unload_all":    return unloadAll()
        case "switch_model":  return switchModel(args)
        default:
            return failure("not_found", "Unknown tool '\(name)'")
        }
    }

    // MARK: - Reads

    private static func listModels() -> [String: Any] {
        let models = discoverModels()
        let running = Dictionary(uniqueKeysWithValues: readRunning(models: models).map { ($0.hash, $0) })
        let fm = FileManager.default
        let items: [[String: Any]] = models.map { m in
            let est = FootprintEstimator.estimate(model: m, ctxSize: Prefs.int("defaultCtxSize", default: 4096))
            var size: UInt64 = est.weights
            if size == 0 { size = ((try? fm.attributesOfItem(atPath: m.path))?[.size] as? UInt64) ?? 0 }
            var entry: [String: Any] = [
                "name": m.name,
                "backend": m.backend,
                "file_size": humanBytes(size),
                "running": running[m.hash] != nil,
                "pinned": (perModelValue("pinned", hash: m.hash) as? Bool) ?? false,
                "has_overrides": (perModelValue("overrideEnabled", hash: m.hash) as? Bool) ?? false,
            ]
            if let mcw = est.maxContextWindow { entry["max_context_window"] = mcw }
            if m.backend == "GGUF" {
                let dir = (m.path as NSString).deletingLastPathComponent
                let vision = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
                    .contains { $0.hasPrefix("mmproj-") && $0.hasSuffix(".gguf") }
                entry["vision"] = vision
            }
            return entry
        }
        return payload(["models": items])
    }

    private static func getSettings() -> [String: Any] {
        var global: [String: Any] = [:]
        let stringKeys = ["modelsDir", "llamaServerPath", "mlxServerPath", "chatTemplatePath",
                          "globalExtraArgs", "kvCacheTypeK", "kvCacheTypeV"]
        let intKeys = ["defaultPort", "defaultCtxSize", "topK", "seed", "cpuThreads", "batchSize",
                       "mlxMaxKvSize", "ttlMinutes"]
        // Per-key defaults — matching AppSettings' Swift-side defaults
        // (DomainTypes.swift). A blanket `false` here previously made
        // every true-by-default toggle (MTP, flash attention, thinking,
        // suppress reasoning, notify-on-agent-actions) report as OFF to
        // agents whenever the user had never touched it in Settings.
        let boolDefaults: [String: Bool] = [
            "enableMtp": true, "enableDflash": true, "mcpEnabled": false, "allowSwapLoads": false,
            "flashAttention": true, "thinkingEnabled": true, "suppressReasoning": true,
            "mlock": false, "noMmap": false, "notifyAgentActions": true,
        ]
        for k in stringKeys { global[k] = Prefs.string(k) }
        for k in intKeys { global[k] = Prefs.int(k) }
        for (k, def) in boolDefaults { global[k] = Prefs.bool(k, default: def) }
        for k in ["temperature", "topP", "repeatPenalty"] { global[k] = (Prefs.value(k) as? Double) ?? 0 }

        let suffixes = ["overrideEnabled", "port", "ctx", "temperature", "topP", "topK",
                        "repeatPenalty", "kvCacheTypeK", "kvCacheTypeV", "thinkingEnabled",
                        "suppressReasoning", "enableMtp", "enableDflash", "extraArgs", "pinned"]
        var perModel: [String: Any] = [:]
        for m in discoverModels() {
            var overrides: [String: Any] = [:]
            for s in suffixes {
                if let v = perModelValue(s, hash: m.hash) { overrides[s] = v }
            }
            if !overrides.isEmpty { perModel[m.name] = overrides }
        }
        return payload(["global": global, "per_model_overrides": perModel,
                        "note": "Settings are read-only for agents."])
    }

    // MARK: - Shared mutation helpers

    private enum Resolved {
        case model(DiscoveredModel)
        case fail([String: Any])
    }

    private static func resolveOrFail(_ args: [String: Any]) -> Resolved {
        guard let q = args["name"] as? String, !q.isEmpty else {
            return .fail(failure("not_found", "Missing required parameter 'name'"))
        }
        switch resolveModel(q) {
        case .one(let m): return .model(m)
        case .none: return .fail(failure("not_found", "No model matches '\(q)'"))
        case .ambiguous(let ms):
            return .fail(failure("ambiguous_name", "Multiple models match '\(q)'",
                                 extra: ["candidates": ms.map { $0.name }]))
        }
    }

    private static func isPinned(_ m: DiscoveredModel) -> Bool {
        (perModelValue("pinned", hash: m.hash) as? Bool) ?? false
    }

    /// Append one JSONL event for the app to turn into a macOS
    /// notification (consumed + truncated by its sync tick).
    private static func logAgentEvent(_ action: String, model: String, port: Int? = nil) {
        var obj: [String: Any] = ["ts": Date().timeIntervalSince1970,
                                  "action": action, "model": model]
        if let port { obj["port"] = port }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let path = llamaDir + "/events.jsonl"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.write(Data([0x0A]))
            try? fh.close()
        }
    }

    /// Stop one running model and VERIFY it stopped. CLI-launched models go
    /// through `llama unload`; app-launched ones (no PID file — invisible to
    /// the CLI) are TERMed directly, exactly what the app's own Unload does.
    private static func unloadRunning(_ r: RunningModel) -> Bool {
        if r.fromPidFile {
            guard Launcher.runCli(["unload", r.displayName]).status == 0 else { return false }
        } else {
            kill(r.pid, SIGTERM)
        }
        for _ in 0..<20 {
            if kill(r.pid, 0) != 0 {
                logAgentEvent("unloaded", model: r.displayName)
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if kill(r.pid, 0) != 0 {
            logAgentEvent("unloaded", model: r.displayName)
            return true
        }
        return false
    }

    private static func backendBinaryMissing(_ m: DiscoveredModel) -> String? {
        let path: String
        if m.backend == "GGUF" {
            let p = Prefs.string("llamaServerPath")
            path = p.isEmpty ? "/opt/homebrew/bin/llama-server" : p
        } else {
            let p = Prefs.string("mlxServerPath")
            path = p.isEmpty ? NSHomeDirectory() + "/Library/Python/3.14/bin/mlx_lm.server" : p
        }
        return FileManager.default.isExecutableFile(atPath: path) ? nil : path
    }

    /// Swap guard (§3.7). Returns a failure payload, or nil to proceed;
    /// `warning` is set when proceeding with allowSwapLoads ON past the limit.
    private static func swapGuard(model: DiscoveredModel, ctx: Int,
                                  extraResident: UInt64 = 0) -> (block: [String: Any]?, warning: [String: Any]?) {
        let est = FootprintEstimator.estimate(model: model, ctxSize: ctx)
        let metrics = SystemMetrics.read()
        let available = metrics.ramAvailable > extraResident ? metrics.ramAvailable : 0
        let allowSwap = Prefs.bool("allowSwapLoads")
        let limit = FootprintEstimator.headroom
        let fits = est.footprint + limit <= available

        if metrics.memoryPressure == "critical", !allowSwap {
            return (failure("insufficient_memory",
                "Memory pressure is critical; refusing to load. Free memory or enable 'Allow swap for agent loads'."), nil)
        }
        if fits { return (nil, nil) }

        if allowSwap {
            let overshoot = est.footprint + limit > available ? est.footprint + limit - available : 0
            var warn: [String: Any] = [
                "message": "\(model.name) at ctx \(ctx) needs ~\(humanBytes(est.footprint)); projected overshoot \(humanBytes(overshoot)) will swap. Swap used now: \(humanBytes(metrics.swapUsed)).",
            ]
            if metrics.memoryPressure == "critical" {
                warn["message"] = (warn["message"] as? String ?? "") + " MEMORY PRESSURE IS CRITICAL."
            }
            return (nil, warn)
        }

        var msg = "\(model.name) at ctx \(ctx) needs ~\(humanBytes(est.footprint)); "
            + "\(humanBytes(available)) available (\(humanBytes(limit)) headroom reserved)."
        var extra: [String: Any] = ["estimate_quality": est.quality]
        if let maxCtx = FootprintEstimator.maxCtxThatFits(est, available: available), maxCtx > 0 {
            msg += " Fits at ctx <= \(maxCtx)."
            extra["max_ctx_that_fits"] = maxCtx
        }
        let unloadable = readRunning(models: discoverModels())
            .filter { $0.model.map { !isPinned($0) } ?? true }
            .compactMap { r -> String? in
                guard let rss = SystemMetrics.rssBytes(pid: r.pid) else { return nil }
                return "\(r.displayName) (\(humanBytes(rss)))"
            }
        if !unloadable.isEmpty { msg += " Or unload " + unloadable.joined(separator: ", ") + "." }
        if Prefs.bool("mlock") {
            msg += " Note: mlock is ON — an over-RAM load would likely fail outright rather than swap."
        }
        return (failure("insufficient_memory", msg, extra: extra), nil)
    }

    private static func effectiveCtx(_ m: DiscoveredModel, requested: Int?) -> Int {
        if let c = requested, c > 0 { return c }
        if let c = perModelValue("ctx", hash: m.hash) as? Int, c > 0 { return c }
        return Prefs.int("defaultCtxSize", default: 4096)
    }

    // MARK: - load_model

    private static func loadModel(_ args: [String: Any]) -> [String: Any] {
        let model: DiscoveredModel
        switch resolveOrFail(args) {
        case .fail(let f): return f
        case .model(let m): model = m
        }

        let running = readRunning(models: discoverModels())
        if let r = running.first(where: { $0.hash == model.hash }) {
            if probeHealthy(port: r.port, backend: r.backend) {
                return payload(["message": "\(model.name) already running on :\(r.port)",
                                "endpoint": "http://127.0.0.1:\(r.port)/v1"])
            }
            return failure("already_loading", "\(model.name) is mid-load (pid \(r.pid)); poll status.")
        }

        if let missing = backendBinaryMissing(model) {
            return failure("backend_missing", "\(model.backend) server binary not found at \(missing).")
        }

        // Preflight the EFFECTIVE port — an explicit request or the user's
        // saved per-model port — against live listeners. Without this the
        // spawn dies on the bind conflict and the failure is opaque.
        let requestedPort = args["port"] as? Int
        let effectivePort = requestedPort ?? (perModelValue("port", hash: model.hash) as? Int)
        if let port = effectivePort, port > 0 {
            let occupied = listeningPorts()
            if let occupant = running.first(where: { $0.port == port }).map({ $0.displayName })
                ?? occupied[port] {
                let source = requestedPort != nil ? "requested" : "the user's saved per-model"
                return failure("port_conflict",
                    "Port \(port) (\(source) port for \(model.name)) is occupied by \(occupant).")
            }
        }

        let ctx = effectiveCtx(model, requested: args["ctx_size"] as? Int)
        let guardResult = swapGuard(model: model, ctx: ctx)
        if let block = guardResult.block { return block }

        var cliArgs = ["load"]
        if let c = args["ctx_size"] as? Int, c > 0 { cliArgs += ["--ctx", "\(c)"] }
        if let p = requestedPort, p > 0 { cliArgs += ["--port", "\(p)"] }
        cliArgs.append(model.name)
        let cli = Launcher.runCli(cliArgs)
        if cli.status != 0 {
            return failure("load_failed", "llama load failed: \(Launcher.tail(cli.output))")
        }

        let timeout = min(600, max(10, args["timeout_s"] as? Int ?? 180))
        switch Launcher.waitHealthy(hash: model.hash, backend: model.backend, timeoutS: timeout) {
        case .ready(let port, _):
            logAgentEvent("loaded", model: model.name, port: port)
            var body: [String: Any] = [
                "message": "\(model.name) ready on :\(port)",
                "endpoint": "http://127.0.0.1:\(port)/v1",
                "model_id": model.name,
            ]
            if let warn = guardResult.warning { body["warning"] = warn }
            return payload(body)
        case .timeout:
            return failure("load_timeout", "\(model.name) spawned but was not healthy after \(timeout)s.")
        case .died:
            let log = llamaDir + "/logs"
            return failure("load_failed",
                "\(model.name) exited before becoming healthy. CLI output: \(Launcher.tail(cli.output)). Logs: \(log)/")
        }
    }

    // MARK: - unload_model / unload_all

    private static func unloadModel(_ args: [String: Any]) -> [String: Any] {
        let model: DiscoveredModel
        switch resolveOrFail(args) {
        case .fail(let f): return f
        case .model(let m): model = m
        }
        let running = readRunning(models: discoverModels())
        guard let r = running.first(where: { $0.hash == model.hash }) else {
            return payload(["message": "\(model.name) is not running — nothing to do."])
        }
        if isPinned(model) {
            return failure("model_pinned",
                "\(model.name) is pinned by the user; agents cannot unload it.")
        }
        guard unloadRunning(r) else {
            return failure("load_failed", "\(model.name) (pid \(r.pid)) did not stop.")
        }
        return payload(["message": "\(model.name) unloaded."])
    }

    private static func unloadAll() -> [String: Any] {
        let running = readRunning(models: discoverModels())
        var unloaded: [String] = []
        var skippedPinned: [String] = []
        var errors: [String] = []
        for r in running {
            if let m = r.model, isPinned(m) { skippedPinned.append(r.displayName); continue }
            if unloadRunning(r) { unloaded.append(r.displayName) }
            else { errors.append("\(r.displayName): did not stop (pid \(r.pid))") }
        }
        var body: [String: Any] = ["unloaded": unloaded, "skipped_pinned": skippedPinned]
        if !errors.isEmpty { body["errors"] = errors }
        return payload(body, isError: false)
    }

    // MARK: - switch_model

    private static func switchModel(_ args: [String: Any]) -> [String: Any] {
        let model: DiscoveredModel
        switch resolveOrFail(args) {
        case .fail(let f): return f
        case .model(let m): model = m
        }
        let unloadFirst = args["unload_first"] as? Bool ?? false
        let ctx = effectiveCtx(model, requested: args["ctx_size"] as? Int)
        var others = readRunning(models: discoverModels()).filter { $0.hash != model.hash }

        // Overlap guard: new + old are transiently co-resident (§3.7).
        if !unloadFirst {
            let guardResult = swapGuard(model: model, ctx: ctx)
            if guardResult.block != nil {
                // Would it pass with the others unloaded?
                let freeable = others.reduce(0 as UInt64) { $0 + (SystemMetrics.rssBytes(pid: $1.pid) ?? 0) }
                let est = FootprintEstimator.estimate(model: model, ctxSize: ctx)
                let projected = SystemMetrics.read().ramAvailable + freeable
                if est.footprint + FootprintEstimator.headroom <= projected {
                    return failure("insufficient_memory",
                        "\(model.name) does not fit alongside the running models, but would fit alone. Retry with unload_first: true (brief downtime; a failed load then leaves nothing running).",
                        extra: ["suggest_unload_first": true])
                }
                return guardResult.block!
            }
        } else {
            for r in others {
                if let m = r.model, isPinned(m) { continue }
                _ = unloadRunning(r)
            }
            others = []
        }

        var loadArgs = args
        loadArgs["timeout_s"] = args["timeout_s"] ?? 180
        let loadResult = loadModel(loadArgs)
        if loadResult["isError"] as? Bool == true { return loadResult }

        var skippedPinned: [String] = []
        for r in others {
            if let m = r.model, isPinned(m) { skippedPinned.append(r.displayName); continue }
            _ = unloadRunning(r)
        }

        var body: [String: Any] = ["message": "Switched to \(model.name)."]
        if unloadFirst { body["note"] = "unload_first was used — there was a downtime window during the load." }
        if !skippedPinned.isEmpty { body["skipped_pinned"] = skippedPinned }
        // Endpoint from the (fresh) load result content.
        if let content = (loadResult["content"] as? [[String: Any]])?.first?["text"] as? String,
           let data = content.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let endpoint = obj["endpoint"] as? String {
            body["endpoint"] = endpoint
        }
        return payload(body)
    }
}
