// =============================================================================
//  DomainTypes.swift
//  LM Switcher — value types shared across the app
// =============================================================================
//  ModelBackend, ModelEntry, ModelState, and AppSettings. Extracted from the
//  former single-file LlamaMenubarApp.swift (audit A-1: split >3000-line file).
// =============================================================================

import Foundation


// MARK: - Model Domain Types
// -----------------------------------------------------------------------------
//  These types model the things this app cares about: which model engines
//  (backends) we support, the model entries themselves, and their runtime
//  state.

// MARK:   ModelBackend
/// Distinguishes the model file format / inference engine.
// MARK: - Model name parsing (redesign Phase 2)
//
//  Model filenames carry the metadata users scan for — family, size,
//  quant — but read as noise ("cerebras_Qwen3-Coder-REAP-25B-A3B-
//  Q4_K_M.gguf"). Parse them into a display name + quant token; the
//  raw name stays available as a tooltip. Best-effort: any surprise
//  falls back to the raw name with no quant chip.

struct ParsedModelName {
    let display: String
    let quant: String?      // "Q4_K_M", "Q8_0", "OQ4", "4-BIT", …
}

func parseModelName(_ raw: String) -> ParsedModelName {
    var name = raw
    for ext in [".gguf", ".GGUF"] where name.hasSuffix(ext) {
        name = String(name.dropLast(ext.count))
    }

    // Quant token FIRST — its underscores (q5_k_m) would otherwise fool
    // the publisher-prefix heuristic below. Last match wins (quants sit
    // near the end). Covers Q4_K_M / Q8_0 / IQ4_XS / oQ4 / 4-bit / f16.
    var quant: String? = nil
    let pattern = #"(?i)(?:^|[-_.])((?:i|o)?q\d(?:_[a-z0-9]+)*|\d+-?bit|b?f16)(?=$|[-_.])"#
    if let re = try? NSRegularExpression(pattern: pattern) {
        let ns = name as NSString
        let matches = re.matches(in: name, range: NSRange(location: 0, length: ns.length))
        if let m = matches.last, m.numberOfRanges > 1 {
            quant = ns.substring(with: m.range(at: 1)).uppercased()
            // Remove the token plus its leading separator from the name.
            name = ns.replacingCharacters(in: m.range, with: "")
        }
    }

    // Publisher prefix ("cerebras_", "deepreinforce-ai_"): strip when the
    // part before the first underscore is all lowercase slug characters.
    if let us = name.firstIndex(of: "_") {
        let prefix = name[..<us]
        let slugSet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        if !prefix.isEmpty, name.index(after: us) < name.endIndex,
           prefix.unicodeScalars.allSatisfy({ slugSet.contains($0) }) {
            name = String(name[name.index(after: us)...])
        }
    }

    // Tokenize on "-", drop noise tokens, rejoin with spaces.
    let noise: Set<String> = ["ud", "imat", "gguf", "mlx"]
    let tokens = name.split(whereSeparator: { $0 == "-" })
        .map(String.init)
        .filter { !$0.isEmpty && !noise.contains($0.lowercased()) }
    let display = tokens.joined(separator: " ")
        .trimmingCharacters(in: .whitespaces)

    guard display.count >= 3 else { return ParsedModelName(display: raw, quant: nil) }
    return ParsedModelName(display: display, quant: quant)
}


/// Each backend has its own launch command and SF Symbol icon.
enum ModelBackend: String, CaseIterable, Identifiable {
    /// GGUF format (used by `llama.cpp` / `llama-server`). One file per model.
    case gguf = "GGUF"
    /// Apple MLX format. A directory containing `*.safetensors` and
    /// `config.json`. Served by `mlx_lm.server`.
    case mlx = "MLX"

    /// `Identifiable` conformance uses the raw value (e.g. "GGUF").
    var id: String { rawValue }

    /// The SF Symbol used to represent this backend in the UI.
    /// `doc.text` for GGUF (a generic file icon).
    /// `cpu`      for MLX (a chip icon, evoking Apple Silicon).
    var sfSymbol: String {
        switch self {
        case .gguf: return "doc.text"
        case .mlx: return "cpu"
        }
    }
}

// MARK:   ModelEntry
/// A discovered model on disk. This is a *value type* — instances are
/// immutable. The `id` is the absolute path, which is stable across launches
/// (a model's name/filename doesn't change unless the file moves).
///
/// Used as the element type of `ServerManager.models` and as the parameter
/// for `loadModel` / `unloadModel`.
struct ModelEntry: Identifiable, Hashable {

    /// Stable unique identifier. Currently the absolute path, which is
    /// unique and survives across app launches.
    let id: String

    /// Human-readable name shown in menus. Usually the filename for GGUF,
    /// the directory name for MLX.
    let name: String

    /// Where the model lives on disk:
    /// - For GGUF: a file URL pointing at the `.gguf` file.
    /// - For MLX: a directory URL pointing at the model directory.
    let path: URL

    /// Which backend the model belongs to.
    let backend: ModelBackend

    // MARK:   Hashable / Equatable
    // Two entries are equal iff their ids match. We only hash the id, not
    // the full URL, for performance and stability.

    static func == (lhs: ModelEntry, rhs: ModelEntry) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK:   ModelState
/// Runtime state for a single model: whether it's running, its PID, port,
/// context size, and any extra args. Stored in `ServerManager.modelStates`
/// keyed by `ModelEntry.id`.
///
/// This is a *mutable* struct (despite being in SwiftUI land) because it's
/// stored in a dictionary in a class; SwiftUI views observe the class's
/// `@Observable` properties, so changes propagate.
struct ModelState {
    /// True if the server process for this model is currently running.
    var isRunning: Bool = false

    /// PID of the running process. `nil` when not running.
    var pid: Int32? = nil

    /// TCP port the server is listening on.
    var port: Int = 0

    /// Context size (in tokens) the server was started with.
    var ctxSize: Int = 0

    /// Last spawn/runtime error for this model, if any. Set when
    /// `Process.run()` throws (e.g. wrong binary path). Surfaced in the
    /// menu so the user gets feedback instead of a silent no-op. Cleared
    /// on a successful load. `nil` when there's nothing to report.
    var lastError: String? = nil
}


/// One MCP-agent action (load/unload), drained from events.jsonl and
/// retained for the menu's Agent Activity view (redesign Phase 5).
/// Independent of the "Notify on agent actions" toggle — that controls
/// whether a macOS notification is also POSTED, not whether history is
/// kept for this on-demand feed.
struct AgentEvent: Identifiable {
    let id = UUID()
    let action: String     // "loaded" | "unloaded"
    let model: String      // raw filename, as the MCP wrote it
    let port: Int?
    let timestamp: Date
}


// MARK:   AppSettings
// -----------------------------------------------------------------------------
//  Plain data type for global app settings. Mutated in place by both
//  the SwiftUI views and the companion CLI (via UserDefaults).

struct AppSettings {
    /// Root directory to scan for models (recursively).
    var modelsDir: String = ""

    /// Default TCP port. Used when a model has no per-model port set.
    var defaultPort: Int = 8080

    /// Default context size in tokens. Used when a model has no per-model
    /// context size set.
    var defaultCtxSize: Int = 4096

    /// Absolute path to the `llama-server` binary.
    var llamaServerPath: String = "/opt/homebrew/bin/llama-server"

    /// Absolute path to the `mlx_lm.server` entry point script.
    var mlxServerPath: String = ""

    /// Free-form string of extra args passed to every server process.
    /// Parsed with `parseArgs` in `ServerManager` to handle quoting.
    var globalExtraArgs: String = ""

    /// Optional path to a custom chat template file (.jinja or .json).
    /// When set, passed as `--chat-template` to llama-server. Useful for
    /// agentic harnesses (opencode, pi) that need custom tool-calling
    /// templates. Empty string = use the model's built-in template.
    var chatTemplatePath: String = ""

    /// Enable MTP (Multi-Token Prediction) for GGUF models on macOS.
    /// MTP was historically a net loss on Apple Silicon Metal, but recent
    /// llama.cpp builds (9859+) have fixed the GPU memory duplication bug.
    /// ON by default — silently skipped for models without MTP support.
    var enableMtp: Bool = true

    /// DFlash block-diffusion speculative decoding (Muse Glimmer's
    /// dflash-kquant.gguf companion drafter). ON by default — silently
    /// skipped for models without a dflash-*.gguf companion.
    var enableDflash: Bool = true

    /// Master toggle for MCP agent access (MCP_SPEC §3.9). The external
    /// lm-switcher-mcp server re-reads this key on every tools/call and
    /// refuses all tools while OFF. The app itself never acts on it.
    var mcpEnabled: Bool = false

    /// Permit agent-initiated loads that exceed free RAM (MCP_SPEC §3.7).
    /// OFF (default): the MCP swap guard refuses loads that would swap.
    /// Consumed only by lm-switcher-mcp; the app itself never acts on it.
    var allowSwapLoads: Bool = false

    /// Post a macOS notification when an agent loads/unloads a model via
    /// the MCP. The MCP writes events to events.jsonl; the app posts them.
    var notifyAgentActions: Bool = true

    /// Auto-unload GGUF models idle for this many minutes (0 = off).
    /// Idle = /slots response unchanged between polls. Pinned models and
    /// MLX models (no slots endpoint) are exempt.
    var ttlMinutes: Int = 0

    /// KV cache type for K cache. q8_0 is the community default for Mac
    /// (halves KV memory with minimal quality loss). f16 is full precision.
    var kvCacheTypeK: String = "q8_0"

    /// KV cache type for V cache. q4_0 is more aggressive (quarters memory).
    /// q8_0 is the balanced choice. f16 is full precision.
    var kvCacheTypeV: String = "q4_0"

    /// Flash attention. Reduces KV memory and speeds up long context.
    /// On by default — no reason to disable on Apple Silicon.
    var flashAttention: Bool = true

    /// Enable Qwen thinking mode. When ON, model generates reasoning tokens
    /// before responding. Better for coding/tools, worse for latency.
    /// When OFF, model responds directly — faster but less thorough.
    var thinkingEnabled: Bool = true

    /// Suppress Gemma 4 reasoning_content field that breaks OpenAI-compatible
    /// clients (opencode, pi, OpenClaw). On by default — only disable if
    /// you're using a client that handles reasoning_content natively.
    var suppressReasoning: Bool = true

    // MARK: - Sampling Defaults
    // Shared between llama-server and mlx_lm.server.

    /// Sampling temperature. Lower = more focused, higher = more creative.
    /// 0.6 for coding/tools, 0.8 for chat, 1.0 for research.
    var temperature: Double = 0.8

    /// Nucleus sampling threshold.
    var topP: Double = 0.95

    /// Top-K sampling. Qwen recommends 20 for all workloads.
    var topK: Int = 20

    /// Penalize repeated tokens. 1.0 = no penalty, 1.1-1.5 = mild.
    var repeatPenalty: Double = 1.0

    /// Random seed. Empty/0 = random each run.
    var seed: Int = 0

    // MARK: - Performance (llama-server only)
    // These are ignored by mlx_lm.server.

    /// CPU threads for prefill. 0 = auto (all cores).
    var cpuThreads: Int = 0

    /// Logical batch size for prompt processing.
    var batchSize: Int = 2048

    /// Lock model in RAM to prevent swap.
    var mlock: Bool = false

    /// Don't memory-map the model file. Faster load, more RAM.
    var noMmap: Bool = false

    // MARK: - MLX-specific
    // Only applied to mlx_lm.server.

    /// Max KV cache size for MLX. 0 = unlimited (use model default).
    var mlxMaxKvSize: Int = 0
}
