// =============================================================================
//  StateReader.swift — lm-switcher-mcp
//  Live-truth reads: PID files, ps, lsof, UserDefaults (MCP_SPEC §3.5).
//  The MCP holds NO state in memory between calls — everything here is
//  re-read per tool call so user actions in the app are seen immediately.
// =============================================================================

import Foundation
import CryptoKit

let prefsDomain = "local.llama-menubar" as CFString

/// State dir shared with the app and CLI (PID files, logs).
let llamaDir: String = ProcessInfo.processInfo.environment["LLAMA_DIR"]
    ?? (NSHomeDirectory() + "/.local/share/llama-menubar")

/// The `llama` CLI — the single battle-tested mutations path (§3.8).
let llamaCliPath: String = ProcessInfo.processInfo.environment["LLAMA_CLI"]
    ?? (NSHomeDirectory() + "/bin/llama")

// MARK: - Settings (fresh CFPreferences read, synced per call)

struct Prefs {
    /// Sync first, every call, so a toggle flip in the app is seen
    /// immediately (§3.5).
    static func sync() { CFPreferencesAppSynchronize(prefsDomain) }

    static func value(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, prefsDomain)
    }
    static func bool(_ key: String, default def: Bool = false) -> Bool {
        (value(key) as? Bool) ?? ((value(key) as? Int).map { $0 != 0 }) ?? def
    }
    static func int(_ key: String, default def: Int = 0) -> Int {
        (value(key) as? Int) ?? def
    }
    static func string(_ key: String, default def: String = "") -> String {
        (value(key) as? String) ?? def
    }
}

// MARK: - Model identity (must match app + CLI exactly)

/// First 12 hex chars of MD5 of the absolute path — identical to the app's
/// `perModelKey` and the CLI's `id_hash` (`md5 -q -s <path>`).
func idHash12(_ path: String) -> String {
    let digest = Insecure.MD5.hash(data: Data(path.utf8))
    return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
}

func perModelValue(_ suffix: String, hash: String) -> Any? {
    Prefs.value("model.\(hash).\(suffix)")
}

// MARK: - Discovery (mirrors the CLI's list_all_models)

struct DiscoveredModel {
    let backend: String   // "GGUF" | "MLX" | "oMLX"
    let path: String
    let name: String
    var hash: String { idHash12(path) }
}

func discoverModels() -> [DiscoveredModel] {
    let fm = FileManager.default
    var out: [DiscoveredModel] = []
    // oMLX root known up front so the generic MLX scan below can skip it.
    let omlxDir = Prefs.string("omlxModelDir", default: NSHomeDirectory() + "/models/omlx")
    let modelsDir = Prefs.string("modelsDir")
    if !modelsDir.isEmpty {
        guard let en = fm.enumerator(atPath: modelsDir) else { return [] }
        var mlxDirs = Set<String>()
        for case let rel as String in en {
            let base = (rel as NSString).lastPathComponent
            if base.hasPrefix(".") { continue }
            let full = modelsDir + "/" + rel
            if base.hasSuffix(".gguf") {
                // Exclusions must stay in sync with the CLI + Swift ggufEntry.
                if base.hasPrefix("mmproj-") || base.hasPrefix("mtp-")
                    || base.hasPrefix("dflash-")
                    || base.hasPrefix("modernbert-embed-") { continue }
                out.append(DiscoveredModel(backend: "GGUF", path: full, name: base))
            } else if base == "config.json" {
                let dir = (full as NSString).deletingLastPathComponent
                if !mlxDirs.contains(dir),
                   !dir.hasPrefix(omlxDir + "/"),
                   let files = try? fm.contentsOfDirectory(atPath: dir),
                   files.contains(where: { $0.hasSuffix(".safetensors") }) {
                    // Skip MTPLX models (have mtplx_runtime.json) — they get .mtplx backend below.
                    if !files.contains(where: { $0.lowercased() == "mtplx_runtime.json" }) {
                        mlxDirs.insert(dir)
                        out.append(DiscoveredModel(backend: "MLX", path: dir,
                                                   name: (dir as NSString).lastPathComponent))
                    }
                }
            }
        }
    }

    // oMLX: models under the oMLX root (org/model nesting, depth <= 2).
    // One shared server on omlxPort serves all of them.
    if !omlxDir.isEmpty, fm.fileExists(atPath: omlxDir) {
        var visited = Set<String>()
        if let en = fm.enumerator(atPath: omlxDir) {
            for case let rel as String in en {
                let depth = rel.split(separator: "/").count
                guard depth <= 2 else { en.skipDescendants(); continue }
                if (rel as NSString).lastPathComponent.hasPrefix(".") { continue }
                let dir = omlxDir + "/" + rel
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue,
                      !visited.contains(dir) else { continue }
                if let files = try? fm.contentsOfDirectory(atPath: dir),
                   files.contains(where: { $0.lowercased() == "config.json" }),
                   files.contains(where: { $0.lowercased().hasSuffix(".safetensors") }) {
                    visited.insert(dir)
                    out.append(DiscoveredModel(backend: "oMLX", path: dir,
                                               name: (dir as NSString).lastPathComponent))
                }
            }
        }
    }

    // MTPLX: directories with config.json + safetensors + mtplx_runtime.json.
    // These sit inside modelsDir but were excluded from the MLX scan above.
    if !modelsDir.isEmpty {
        if let en = fm.enumerator(atPath: modelsDir) {
            var mtplxDirs = Set<String>()
            for case let rel as String in en {
                guard !rel.contains("/.") else { continue }
                let full = modelsDir + "/" + rel
                if (rel as NSString).lastPathComponent == "mtplx_runtime.json" {
                    let dir = (full as NSString).deletingLastPathComponent
                    guard !mtplxDirs.contains(dir) else { continue }
                    if let files = try? fm.contentsOfDirectory(atPath: dir),
                       files.contains(where: { $0.hasSuffix(".safetensors") }) {
                        mtplxDirs.insert(dir)
                        out.append(DiscoveredModel(backend: "MTPLX", path: dir,
                                                   name: (dir as NSString).lastPathComponent))
                    }
                }
            }
        }
    }
    return out.sorted { $0.name.lowercased() < $1.name.lowercased() }
}

// MARK: - Name resolution (mirrors the CLI: substring, exact wins)

enum Resolution {
    case one(DiscoveredModel)
    case none
    case ambiguous([DiscoveredModel])
}

func resolveModel(_ query: String) -> Resolution {
    let all = discoverModels()
    let q = query.lowercased()
    if let exact = all.first(where: { $0.name.lowercased() == q }) { return .one(exact) }
    let matches = all.filter { $0.name.lowercased().contains(q) }
    switch matches.count {
    case 0: return .none
    case 1: return .one(matches[0])
    default: return .ambiguous(matches)
    }
}

// MARK: - Running processes (PID files + ps, same truth as CLI/app)

struct RunningModel {
    let hash: String
    let pid: Int32
    let port: Int
    let model: DiscoveredModel?   // nil = external / not in current scan
    let displayName: String
    let backend: String
    let ctxSize: Int?
    /// true = CLI/MCP launch (PID file exists, `llama unload` works);
    /// false = ps-discovered (app/manual launch — must be TERMed directly).
    let fromPidFile: Bool
}

/// Union of two truth sources (§3.5, same as the app's mergeExternalStates):
/// PID files written by the CLI/MCP, plus a full `ps` scan that catches
/// models the APP launched (it writes no PID files) or any other
/// llama-server / mlx_lm.server whose model path is in our scan tree.
func readRunning(models: [DiscoveredModel]) -> [RunningModel] {
    let byHash = Dictionary(uniqueKeysWithValues: models.map { ($0.hash, $0) })
    let byPath = Dictionary(uniqueKeysWithValues: models.map { ($0.path, $0) })
    var out: [RunningModel] = []
    var seenPids = Set<Int32>()

    // Source 1: PID files (CLI/MCP launches).
    let pidsDir = llamaDir + "/pids"
    for f in (try? FileManager.default.contentsOfDirectory(atPath: pidsDir)) ?? []
    where f.hasSuffix(".pid") {
        // Stem is `<hash>` (legacy pre-8250ec5) or `<hash>.<basename>`
        // (current). Hash is always the first dot-separated component.
        let stem = String(f.dropLast(4))
        let hash = stem.split(separator: ".").first.map(String.init) ?? stem
        guard !hash.isEmpty,
              let content = try? String(contentsOfFile: pidsDir + "/" + f, encoding: .utf8),
              let first = content.split(separator: "\n").first,
              let pid = Int32(first.trimmingCharacters(in: .whitespaces)),
              kill(pid, 0) == 0 else { continue }   // stale PID file — skip

        let args = runCapture("/bin/ps", ["-o", "args=", "-p", "\(pid)"]) ?? ""
        let port = firstMatch(#"--port (\d+)"#, in: content).flatMap(Int.init)
            ?? firstMatch(#"--port (\d+)"#, in: args).flatMap(Int.init) ?? 0
        let ctx = firstMatch(#"--ctx-size (\d+)"#, in: args).flatMap(Int.init)
        let model = byHash[hash]
        let name = model?.name
            ?? firstMatch(#"(?:-m|--model) (\S+)"#, in: args)
                .map { ($0 as NSString).lastPathComponent }
            ?? hash
        let backend = model?.backend ?? (args.contains("mlx") ? "MLX" : "GGUF")
        out.append(RunningModel(hash: hash, pid: pid, port: port, model: model,
                                displayName: name, backend: backend, ctxSize: ctx,
                                fromPidFile: true))
        seenPids.insert(pid)
    }

    // Source 2: ps scan for servers whose model path is in our tree.
    if let psOut = runCapture("/bin/ps", ["ax", "-o", "pid=,args="]) {
        for line in psOut.split(separator: "\n") {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            guard text.contains("llama-server") || text.contains("mlx_lm")
                || text.contains("omlx serve") || text.contains("omlx-server")
                || text.contains("mtplx serve") else { continue }
            guard let sp = text.firstIndex(of: " "), let pid = Int32(text[..<sp]),
                  !seenPids.contains(pid) else { continue }
            let args = String(text[sp...])

            // oMLX: one server serves every model under the oMLX root —
            // map it onto all discovered oMLX entries (shared pid/port).
            if args.contains("omlx serve") {
                let omlxModels = models.filter { $0.backend == "oMLX" }
                guard !omlxModels.isEmpty else { continue }
                seenPids.insert(pid)
                let port = Prefs.int("omlxPort", default: 8000)
                for m in omlxModels {
                    out.append(RunningModel(hash: m.hash, pid: pid, port: port, model: m,
                                            displayName: m.name, backend: "oMLX", ctxSize: nil,
                                            fromPidFile: false))
                }
                continue
            }

            guard let path = firstMatch(#"(?:-m|--model) (\S+)"#, in: args),
                  let model = byPath[path] else { continue }   // not one of ours
            let port = firstMatch(#"--port (\d+)"#, in: args).flatMap(Int.init) ?? 0
            let ctx = firstMatch(#"--ctx-size (\d+)"#, in: args).flatMap(Int.init)
            out.append(RunningModel(hash: model.hash, pid: pid, port: port, model: model,
                                    displayName: model.name, backend: model.backend, ctxSize: ctx,
                                    fromPidFile: false))
            seenPids.insert(pid)
        }
    }
    return out.sorted { $0.port < $1.port }
}

func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
    return String(text[r])
}

// MARK: - Health probe

/// llama-server serves /health; mlx_lm.server and oMLX serve /v1/models (§3.3).
func probeHealthy(port: Int, backend: String) -> Bool {
    let path = (backend == "MLX" || backend == "oMLX") ? "/v1/models" : "/health"
    guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return false }
    var req = URLRequest(url: url)
    req.timeoutInterval = 2.0
    var ok = false
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { _, resp, _ in
        if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) { ok = true }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 3.0)
    return ok
}

// MARK: - Port occupancy (lsof)

func listeningPorts() -> [Int: String] {
    // pid→command for LISTEN sockets in the scan range.
    guard let out = runCapture("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]) else {
        return [:]
    }
    var ports: [Int: String] = [:]
    var pid = "", cmd = ""
    for line in out.split(separator: "\n") {
        let tag = line.first
        let val = String(line.dropFirst())
        switch tag {
        case "p": pid = val
        case "c": cmd = val
        case "n":
            if let colon = val.lastIndex(of: ":"), let port = Int(val[val.index(after: colon)...]) {
                ports[port] = "pid \(pid) (\(cmd))"
            }
        default: break
        }
    }
    return ports
}

// MARK: - State snapshot (§3.3 — embedded in every response)

func stateSnapshot() -> [String: Any] {
    Prefs.sync()
    let models = discoverModels()
    let running = readRunning(models: models)
    let metrics = SystemMetrics.read()
    let defaultPort = Prefs.int("defaultPort", default: 8080)

    var runningJson: [[String: Any]] = []
    for r in running {
        var entry: [String: Any] = [
            "name": r.displayName,
            "backend": r.backend,
            "port": r.port,
            "endpoint": "http://127.0.0.1:\(r.port)/v1",
            "pid": Int(r.pid),
            "state": probeHealthy(port: r.port, backend: r.backend) ? "ready" : "starting",
            "pinned": (perModelValue("pinned", hash: r.hash) as? Bool) ?? false,
        ]
        if let ctx = r.ctxSize { entry["ctx_size"] = ctx }
        if let rss = SystemMetrics.rssBytes(pid: r.pid) { entry["actual_rss"] = humanBytes(rss) }
        if let m = r.model {
            let est = FootprintEstimator.estimate(model: m, ctxSize: r.ctxSize ?? Prefs.int("defaultCtxSize", default: 4096))
            entry["estimated_footprint"] = humanBytes(est.footprint)
            if let mcw = est.maxContextWindow { entry["max_context_window"] = mcw }
        }
        runningJson.append(entry)
    }

    // Port map over the scan range [defaultPort, defaultPort+200],
    // plus the oMLX shared port (fixed at 8000 by convention, usually
    // outside the llama.cpp scan range).
    let omlxPort = Prefs.int("omlxPort", default: 8000)
    var portLo = defaultPort
    var portHi = defaultPort + 200
    if omlxPort < portLo { portLo = omlxPort }
    if omlxPort > portHi { portHi = omlxPort }
    let ourPorts = Dictionary(uniqueKeysWithValues: running.map { ($0.port, $0.displayName) })
    var portsJson: [String: Any] = [:]
    var nextFree = defaultPort
    let external = listeningPorts()
    for (port, occupant) in external where port >= portLo && port <= portHi {
        if let name = ourPorts[port] {
            portsJson["\(port)"] = ["occupied_by": name, "source": "lm-switcher"]
        } else {
            portsJson["\(port)"] = ["occupied_by": occupant, "source": "external"]
        }
    }
    while portsJson["\(nextFree)"] != nil || ourPorts[nextFree] != nil { nextFree += 1 }
    portsJson["next_free"] = nextFree

    return [
        "running": runningJson,
        "ports": portsJson,
        "system": [
            "ram_total": humanBytes(metrics.ramTotal),
            "ram_used": humanBytes(metrics.ramUsed),
            "ram_available": humanBytes(metrics.ramAvailable),
            "memory_pressure": metrics.memoryPressure,
            "swap_total": humanBytes(metrics.swapTotal),
            "swap_used": humanBytes(metrics.swapUsed),
            "allow_swap_loads": Prefs.bool("allowSwapLoads"),
        ] as [String: Any],
    ]
}
