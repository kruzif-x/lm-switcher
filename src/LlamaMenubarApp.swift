// =============================================================================
//  LlamaMenubarApp.swift
//  LLM Switcher — a macOS menu bar app for managing local LLM models
// =============================================================================
//
//  PURPOSE
//  -------
//  This file is the entire source of the menu bar (status bar) component of
//  "LLM Switcher". It runs as a `MenuBarExtra` (a SwiftUI scene introduced in
//  macOS 13) and lives in the system menu bar next to the clock.
//
//  WHAT IT DOES
//  -------------
//  - Discovers `.gguf` files and MLX model directories under a configurable
//    "models" directory (recursively, with a few exclusions for system files).
//  - Spawns `llama-server` (GGUF) or `mlx_lm.server` (MLX) processes on demand
//    — one process per model, each on its own port.
//  - Tracks running processes, their PIDs, ports, and context sizes.
//  - Auto-loads matching `mmproj-*.gguf` projection models for vision-capable
//    GGUF models (e.g. gemma-3 vision). Uses a name-based + fallback strategy
//    to handle non-standard naming (e.g. QAT builds with `mmproj-BF16.gguf`).
//  - Configurable chat template override for agentic harnesses (opencode, pi)
//    that need custom tool-calling templates.
//  - Detects externally-launched server processes (e.g. started by the
//    companion `llama` CLI) by scanning `ps` output and reconciles state.
//  - Persists all settings via `UserDefaults` (same domain as the CLI so they
//    share configuration).
//  - Watches the models directory with a `DispatchSource` so newly added or
//    removed models appear/disappear from the menu live.
//  - Handles macOS sleep/wake: tears down the FS watcher before I/O
//    suspends, recreates it after wake, and reconciles PIDs of child
//    processes that the OS may have killed during deep sleep.
//
//  ARCHITECTURE OVERVIEW
//  ---------------------
//  - `LlamaMenubarApp`     — `@main` entry point. Holds the singleton
//                             `ServerManager` and a `SettingsWindowHost`.
//  - `MenuView`            — The dropdown menu content (model list, status,
//                             buttons, settings link, quit).
//  - `SettingsView`        — A two-tab settings window (Global / Per-Model).
//  - `SettingsWindowHost`  — Manages the lifecycle of the settings NSWindow
//                             (so it isn't torn down when the SwiftUI view
//                             re-renders).
//  - `ServerManager`       — The brain. Owns model discovery, lifecycle,
//                             state, and persistence. Marked `@Observable`
//                             so SwiftUI views auto-redraw on changes.
//  - `ModelBackend`        — Enum: `.gguf` or `.mlx`. Each backend has its
//                             own SF Symbol and launch command.
//  - `ModelEntry`          — Value type: a discovered model. Stable `id` is
//                             the absolute path, used for state lookup.
//  - `ModelState`          — Per-model runtime state (isRunning, pid, port,
//                             ctxSize). Stored in a `[String: ModelState]`
//                             keyed by `ModelEntry.id`.
//  - `AppSettings`         — Persisted global settings (models dir, default
//                             port/ctx, server binary paths, global args).
//
//  BUILD
//  -----
//  Compiled with `swiftc -parse-as-library` (the `-parse-as-library` flag is
//  required because we use `@main`; without it the compiler treats the file
//  as a script and `@main` is rejected). See `scripts/install.sh` for the
//  full build + .app bundle creation pipeline.
//
//  TARGET
//  ------
//  macOS 13+ (uses `MenuBarExtra`, `@Observable`, `Settings` scene).
//  Intel or Apple Silicon (universal via `swiftc` defaults).
// =============================================================================


// MARK: - Imports
// -----------------------------------------------------------------------------
//  SwiftUI      — declarative UI (`View`, `Scene`, `MenuBarExtra`, etc.)
//  AppKit       — needed for `NSWindow`, `NSOpenPanel`, `NSApplication`.
//                 SwiftUI exposes a lot of AppKit but not all of it.
//  Darwin       — POSIX APIs (`kill(2)`, `SIGTERM`, `open(2)`, `close(2)`).
//  UniformTypeIdentifiers — used implicitly by file pickers (UTType .folder).
import SwiftUI
import AppKit
import Darwin
import UniformTypeIdentifiers
import CryptoKit


// MARK: - App Entry Point
// -----------------------------------------------------------------------------
//  `LlamaMenubarApp` is the `@main` struct. SwiftUI's `App` protocol requires
//  a single `body` returning one or more `Scene` types. Here we return a
//  `MenuBarExtra` scene (the only scene — there is no main window).
//
//  The `@State` properties hold the two long-lived app objects:
//  - `manager`    — all model/server state.
//  - `settingsHost` — keeps the settings NSWindow alive across re-renders.
@main
struct LlamaMenubarApp: App {
    /// All model state, settings, server processes. See `ServerManager` below.
    @State private var manager = ServerManager()

    /// Retains the settings NSWindow so it isn't released when SwiftUI
    /// re-evaluates the body. See `SettingsWindowHost` for details.
    @State private var settingsHost = SettingsWindowHost()

    /// The single scene: a menu bar extra (no dock icon, no main window).
    /// `LSUIElement=true` in Info.plist hides the app from the Dock and
    /// from the Cmd-Tab app switcher; only the menu bar item is visible.
    var body: some Scene {
        MenuBarExtra {
            // The dropdown menu content shown when the user clicks our
            // menu bar icon.
            MenuView(manager: manager, settingsHost: settingsHost)
        } label: {
            // The menu bar icon. We use the `Image(systemName:)` overload
            // rather than a custom `View` body (which previously held an
            // `HStack` with a gradient and a conditional `Text`). On
            // macOS 26/Tahoe, custom `View` labels for `MenuBarExtra`
            // can fail to register with the status bar — the app stays
            // running but no status item is shown. The simpler
            // `Image(systemName:)` form is reliably picked up by the
            // NSStatusItem machinery across macOS versions.
            Image(systemName: manager.anyRunning ? "bolt.fill" : "bolt")
        }
        // Window-based style keeps the panel open after each selection.
        // The panel closes on click-outside or Escape (standard macOS
        // panel behavior), instead of closing on every button/toggle
        // click like the default menu-based style.
        .menuBarExtraStyle(.window)
    }
}


// MARK: - Settings Window Host
// -----------------------------------------------------------------------------
//  We can't use SwiftUI's `Settings` scene for a menu-bar-only app: the system
//  action `showSettingsWindow:` isn't wired up because there's no standard app
//  menu (File / Edit / etc). Attempting to use it from a `MenuBarExtra` ends
//  up calling `NSApp.activate(...)` which can terminate an `LSUIElement` app.
//
//  Solution: manage the settings NSWindow manually. We hold a strong
//  reference to it (so it doesn't get released), and use `orderFrontRegardless`
//  to show it without activating the app process. The window is created
//  lazily on first use and reused for subsequent opens.
//
//  `ObservableObject` lets us observe this from SwiftUI (`@ObservedObject`)
//  in case we ever need to react to show/hide events.
final class SettingsWindowHost: ObservableObject {

    /// The single settings window. Held strongly so SwiftUI re-renders
    /// don't deallocate it. `nil` until the user opens settings the first
    /// time.
    private var window: NSWindow?

    /// Show the settings window, or bring it to front if already open.
    /// - Parameter manager: the shared `ServerManager` instance that the
    ///   settings view reads/writes.
    func show(manager: ServerManager, initialTab: Int = 0) {
        // If the window is already open and visible, just focus it.
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // Build a SwiftUI -> AppKit hosting controller for the SwiftUI view.
        let view = SettingsView(manager: manager, initialTab: initialTab)
        let hosting = NSHostingController(rootView: view)

        // Construct a basic titled window. We deliberately do NOT use
        // `.resizable` because we set a fixed content size and don't want
        // the user to be able to mess with it.
        let win = NSWindow(contentViewController: hosting)
        win.title = "LLM Switcher Settings"
        win.setContentSize(NSSize(width: 580, height: 520))
        win.styleMask = [.titled, .closable, .miniaturizable]

        // `isReleasedWhenClosed = false` means closing the window (red X)
        // doesn't deallocate it — we keep it around so re-opening is fast.
        // `hidesOnDeactivate = false` keeps the window visible when the
        // user clicks another app.
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate = false

        // Center on screen.
        win.center()

        // Make the window float above normal windows. This keeps it visible
        // even if the user is focused on another app's window.
        win.level = .floating

        // Show without activating the app. This is the critical line for
        // a menu-bar-only app: `makeKeyAndOrderFront(nil)` would activate
        // the process and macOS would then try to give us a dock icon,
        // which can cause the app to terminate since we have no main window.
        win.orderFrontRegardless()

        // Defer the `makeKey()` call so the window appears immediately but
        // becomes the key window (so it receives keyboard input) on the
        // next runloop tick. This is more reliable than calling it directly
        // during view construction.
        DispatchQueue.main.async {
            win.makeKey()
        }

        window = win
    }
}


// MARK: - Model Domain Types
// -----------------------------------------------------------------------------
//  These types model the things this app cares about: which model engines
//  (backends) we support, the model entries themselves, and their runtime
//  state.

// MARK:   ModelBackend
/// Distinguishes the model file format / inference engine.
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


// MARK: - Menu View
// -----------------------------------------------------------------------------
//  `MenuView` is the SwiftUI body of the dropdown menu that appears when the
//  user clicks the menu bar icon. It's a vertical stack of sections:
//
//      ┌─────────────────────────────────┐
//      │  ◉ 2 models loaded              │  <- header
//      │  ─────────────────────────────  │  <- divider
//      │  ☐ cerebras...                  │  <- model list (each row is
//      │  ☑ gemma-4-12B-it   [GGUF]  ●8080│    a Toggle with checkbox style)
//      │  ☐ GLM-4.7-Flash...            │
//      │  ☑ omnicoder...       [GGUF]  ●8081│
//      │  ─────────────────────────────  │
//      │  [Load Selected (2)]   [Clear]  │  <- bulk actions
//      │  ─────────────────────────────  │
//      │  [⏹ Unload All]   [↻ Refresh]  │
//      │  ─────────────────────────────  │
//      │  ● 2 on :8080, 8081            │  <- summary
//      │  ─────────────────────────────  │
//      │  ⚙ Settings…                   │
//      │  Quit                           │
//      └─────────────────────────────────┘
struct MenuView: View {
    /// The shared `ServerManager`. `@Bindable` lets us use `$manager.foo`
    /// for two-way bindings. The view is re-evaluated whenever any
    /// `@Observable` property of `manager` changes.
    @Bindable var manager: ServerManager

    /// Settings window host. Observed so SwiftUI re-renders if the window
    /// is opened/closed (mostly future-proofing; not strictly required).
    @ObservedObject var settingsHost: SettingsWindowHost

    /// The set of model IDs the user has ticked with their checkboxes.
    /// We use a local `@State` set (not a server property) because this is
    /// purely view-level state — the checkboxes reset when the menu closes.


    var body: some View {
        VStack(alignment: .leading) {
            // Header section: shows what's currently loaded.
            header

            Divider()

            // Scrollable list of all discovered models.
            modelList

            if manager.models.isEmpty {
                // Friendly message if the user has no models yet.
                Text("No models found")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            } else {
                // Bulk action row.
                HStack {
                    Button("Load Selected (\(manager.selected.count))") {
                        let toLoad = manager.models.filter { manager.selected.contains($0.id) }
                

                        for m in toLoad {

                            manager.loadModel(m)
                        }
                    }
                    .disabled(manager.selected.isEmpty)
                    Spacer()
                    Button("Clear") { manager.selected.removeAll() }
                        .disabled(manager.selected.isEmpty)
                }
                .padding(.horizontal, 4)
            }

            Divider()

            // Bottom: status + actions in one compact row.
            HStack {
                Circle()
                    .fill(manager.anyRunning ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(manager.summaryText)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("↻") { manager.refreshModels() }
                    .help("Refresh models")
                Button("⏹") { manager.unloadAll() }
                    .disabled(!manager.anyRunning)
                    .help("Unload all models")
            }
            .padding(.horizontal, 4)

            Divider()

            // Bottom row: Settings, Help, About, Quit side by side.
            HStack {
                Button("⚙") { settingsHost.show(manager: manager) }
                    .keyboardShortcut(",")
                    .help("Settings")
                Button("?") { settingsHost.show(manager: manager, initialTab: 2) }
                    .help("Help")
                Button("ℹ") { settingsHost.show(manager: manager, initialTab: 3) }
                    .help("About")
                Spacer()
                Button("Quit") {
                    manager.unloadAll()
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(.horizontal, 4)
        }
        .padding(4)
    }

    /// Header text: shows the count of running models and (for multi-model
    /// scenarios) the list of currently loaded model names + ports.
    @ViewBuilder
    private var header: some View {
        // Filter the model list down to those that are currently running.
        let running = manager.models.filter { manager.state(for: $0).isRunning }

        if running.isEmpty {
            // Nothing loaded.
            Text("◌ No models loaded")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        } else if running.count == 1 {
            // One model: show its name and backend.
            Text("◉ \(running[0].name) [\(running[0].backend.rawValue)]")
                .font(.headline)
                .padding(.horizontal, 4)
        } else {
            // Multiple: show a small list of "name :port" lines.
            VStack(alignment: .leading, spacing: 2) {
                Text("◉ \(running.count) models loaded")
                    .font(.headline)
                    .padding(.horizontal, 4)
                ForEach(running, id: \.id) { m in
                    Text("  • \(m.name) [\(m.backend.rawValue)] :\(manager.state(for: m).port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    /// Renders one row per model. Each row is a `Toggle` styled as a
    /// checkbox. The toggle drives both the local `selected` set (for
    /// bulk "Load Selected") and visual state.
    @ViewBuilder
    private var modelList: some View {
        ForEach(manager.models) { model in
            modelRow(for: model)
        }
    }

    /// One row of the model list: a checkbox toggle + a horizontal stack
    /// with the model's icon, name, backend badge, and a status indicator.
    ///
    /// A model is "checked" in the UI if either:
    ///   - the user has ticked it in this session (`selected` set), OR
    ///   - the model is already running (visual hint that it's loaded).
    ///
    /// Note: the toggle is *display-only* for running models — clicking
    /// it doesn't actually unload. Use the context menu or Settings
    /// window for that. (We could change this; it's intentional because
    /// the toggle is meant for *selection*, not state.)
    private func modelRow(for model: ModelEntry) -> some View {
        let state = manager.state(for: model)
        let isChecked = manager.selected.contains(model.id) || state.isRunning

        return Toggle(isOn: Binding(
            get: { isChecked },
            set: { isOn in
                if isOn { manager.selected.insert(model.id) } else { manager.selected.remove(model.id) }
            }
        )) {
            HStack(spacing: 6) {
                // Backend icon (small, colored).
                Image(systemName: model.backend.sfSymbol)
                    .imageScale(.small)
                    .foregroundColor(model.backend == .mlx ? .purple : .blue)

                // Model name (truncates with ellipsis if too long).
                Text(model.name)
                    .lineLimit(1)

                Spacer()

                // Backend badge: a small pill with the backend name.
                Text(model.backend.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            // Light tinted background.
                            .fill(model.backend == .mlx
                                  ? Color.purple.opacity(0.2)
                                  : Color.blue.opacity(0.2))
                    )
                    .foregroundStyle(.secondary)

                // Status indicator: green filled dot + port if running,
                // hollow gray dot if not. If the last load attempt failed
                // (C-1), show a red warning triangle with the error as a
                // help tooltip so the user knows *why* it didn't start.
                if state.isRunning {
                    Image(systemName: "circle.fill")
                        .foregroundColor(.green)
                        .imageScale(.small)
                    Text(":\(String(state.port))")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                } else if let err = state.lastError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .imageScale(.small)
                        .help("Failed to load: \(err)")
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.secondary)
                        .imageScale(.small)
                }
            }
        }
        .toggleStyle(.checkbox)
        // Right-click context menu: quickly load or unload a single model
        // without going through the checkbox + "Load Selected" flow.
        .contextMenu {
            Button(state.isRunning ? "Unload" : "Load") {
                if state.isRunning { manager.unloadModel(model) }
                else { manager.loadModel(model) }
            }
            // "Switch to" — atomically unload all other models and load
            // this one. Only shown when the target isn't already running
            // and at least one other model is loaded.
            if !state.isRunning && manager.anyRunning {
                Button("Switch to") { manager.switchModel(model) }
            }
        }
    }
}


// MARK: - Settings View
// -----------------------------------------------------------------------------
//  The settings window. Two tabs:
//
//    [Global]              [Per-Model]
//    ┌───────────────┐     ┌────────────────────────────┐
//    │ Models Dir    │     │ (per-model editable rows)  │
//    │ Default Port  │     │ name  backend  port  ctx  …│
//    │ Default Ctx   │     │ ...                       │
//    │ Extra Args    │     │                           │
//    │               │     │                           │
//    │ Backend paths │     │                           │
//    └───────────────┘     └────────────────────────────┘
// ViewModifier that holds all onChange handlers for global settings.
// Extracting these from the Form body helps Swift's type checker.
private struct GlobalSettingsModifier: ViewModifier {
    @Bindable var manager: ServerManager
    @Binding var modelsDir: String
    @Binding var defaultPort: String
    @Binding var defaultCtxSize: String
    @Binding var globalExtraArgs: String
    @Binding var enableMtp: Bool
    @Binding var kvCacheTypeK: String
    @Binding var kvCacheTypeV: String
    @Binding var flashAttention: Bool
    @Binding var thinkingEnabled: Bool
    @Binding var suppressReasoning: Bool
    @Binding var llamaServerPath: String
    @Binding var mlxServerPath: String
    @Binding var chatTemplatePath: String
    @Binding var temperature: Double
    @Binding var topP: Double
    @Binding var topK: Int
    @Binding var repeatPenalty: Double
    @Binding var seedStr: String
    @Binding var cpuThreadsStr: String
    @Binding var batchSizeStr: String
    @Binding var mlock: Bool
    @Binding var noMmap: Bool
    @Binding var mlxMaxKvSizeStr: String

    func body(content: Content) -> some View {
        content
            .modifier(ServerDefaultsModifier(manager: manager, modelsDir: $modelsDir, defaultPort: $defaultPort, defaultCtxSize: $defaultCtxSize, globalExtraArgs: $globalExtraArgs, enableMtp: $enableMtp))
            .modifier(KvCacheModifier(manager: manager, kvCacheTypeK: $kvCacheTypeK, kvCacheTypeV: $kvCacheTypeV, flashAttention: $flashAttention, thinkingEnabled: $thinkingEnabled, suppressReasoning: $suppressReasoning, llamaServerPath: $llamaServerPath, mlxServerPath: $mlxServerPath, chatTemplatePath: $chatTemplatePath))
            .modifier(PerfSamplingModifier(manager: manager, temperature: $temperature, topP: $topP, topK: $topK, repeatPenalty: $repeatPenalty, seedStr: $seedStr, cpuThreadsStr: $cpuThreadsStr, batchSizeStr: $batchSizeStr, mlock: $mlock, noMmap: $noMmap, mlxMaxKvSizeStr: $mlxMaxKvSizeStr))
    }
}

private struct ServerDefaultsModifier: ViewModifier {
    @Bindable var manager: ServerManager
    @Binding var modelsDir: String
    @Binding var defaultPort: String
    @Binding var defaultCtxSize: String
    @Binding var globalExtraArgs: String
    @Binding var enableMtp: Bool
    func body(content: Content) -> some View {
        content
            .onChange(of: modelsDir) { _, v in manager.settings.modelsDir = v; manager.refreshModels(); manager.startWatching() }
            .onChange(of: defaultPort) { _, v in if let p = Int(v), p > 0, p < 65536 { manager.settings.defaultPort = p } }
            .onChange(of: defaultCtxSize) { _, v in if let c = manager.parseCtxInput(v) { manager.settings.defaultCtxSize = c } }
            .onChange(of: globalExtraArgs) { _, v in manager.settings.globalExtraArgs = v }
            .onChange(of: enableMtp) { _, v in manager.settings.enableMtp = v }
    }
}

private struct KvCacheModifier: ViewModifier {
    @Bindable var manager: ServerManager
    @Binding var kvCacheTypeK: String
    @Binding var kvCacheTypeV: String
    @Binding var flashAttention: Bool
    @Binding var thinkingEnabled: Bool
    @Binding var suppressReasoning: Bool
    @Binding var llamaServerPath: String
    @Binding var mlxServerPath: String
    @Binding var chatTemplatePath: String
    func body(content: Content) -> some View {
        content
            .onChange(of: kvCacheTypeK) { _, v in manager.settings.kvCacheTypeK = v }
            .onChange(of: kvCacheTypeV) { _, v in manager.settings.kvCacheTypeV = v }
            .onChange(of: flashAttention) { _, v in manager.settings.flashAttention = v }
            .onChange(of: thinkingEnabled) { _, v in manager.settings.thinkingEnabled = v }
            .onChange(of: suppressReasoning) { _, v in manager.settings.suppressReasoning = v }
            .onChange(of: llamaServerPath) { _, v in manager.settings.llamaServerPath = v }
            .onChange(of: mlxServerPath) { _, v in manager.settings.mlxServerPath = v }
            .onChange(of: chatTemplatePath) { _, v in manager.settings.chatTemplatePath = v }
    }
}

private struct PerfSamplingModifier: ViewModifier {
    @Bindable var manager: ServerManager
    @Binding var temperature: Double
    @Binding var topP: Double
    @Binding var topK: Int
    @Binding var repeatPenalty: Double
    @Binding var seedStr: String
    @Binding var cpuThreadsStr: String
    @Binding var batchSizeStr: String
    @Binding var mlock: Bool
    @Binding var noMmap: Bool
    @Binding var mlxMaxKvSizeStr: String
    func body(content: Content) -> some View {
        content
            .onChange(of: temperature) { _, v in manager.settings.temperature = v }
            .onChange(of: topP) { _, v in manager.settings.topP = v }
            .onChange(of: topK) { _, v in manager.settings.topK = v }
            .onChange(of: repeatPenalty) { _, v in manager.settings.repeatPenalty = v }
            .onChange(of: seedStr) { _, v in manager.settings.seed = Int(v) ?? 0 }
            .modifier(PerfExtraModifier(manager: manager, cpuThreadsStr: $cpuThreadsStr, batchSizeStr: $batchSizeStr, mlock: $mlock, noMmap: $noMmap, mlxMaxKvSizeStr: $mlxMaxKvSizeStr))
    }
}

private struct PerfExtraModifier: ViewModifier {
    @Bindable var manager: ServerManager
    @Binding var cpuThreadsStr: String
    @Binding var batchSizeStr: String
    @Binding var mlock: Bool
    @Binding var noMmap: Bool
    @Binding var mlxMaxKvSizeStr: String
    func body(content: Content) -> some View {
        content
            .onChange(of: cpuThreadsStr) { _, v in manager.settings.cpuThreads = Int(v) ?? 0 }
            .onChange(of: batchSizeStr) { _, v in manager.settings.batchSize = Int(v) ?? 2048 }
            .onChange(of: mlock) { _, v in manager.settings.mlock = v }
            .onChange(of: noMmap) { _, v in manager.settings.noMmap = v }
            .onChange(of: mlxMaxKvSizeStr) { _, v in manager.settings.mlxMaxKvSize = Int(v) ?? 0 }
    }
}

struct SettingsView: View {
    @Bindable var manager: ServerManager
    @State private var selectedTab: Int

    // Local @State mirrors of the manager's settings.
    @State private var modelsDir: String
    @State private var defaultPort: String
    @State private var defaultCtxSize: String
    @State private var llamaServerPath: String
    @State private var mlxServerPath: String
    @State private var globalExtraArgs: String
    @State private var chatTemplatePath: String
    @State private var enableMtp: Bool
    @State private var kvCacheTypeK: String
    @State private var kvCacheTypeV: String
    @State private var flashAttention: Bool
    @State private var thinkingEnabled: Bool
    @State private var suppressReasoning: Bool
    @State private var temperature: Double
    @State private var topP: Double
    @State private var topK: Int
    @State private var repeatPenalty: Double
    @State private var seedStr: String
    @State private var cpuThreadsStr: String
    @State private var batchSizeStr: String
    @State private var mlock: Bool
    @State private var noMmap: Bool
    @State private var mlxMaxKvSizeStr: String
    @State private var savedFeedback: Bool = false
    @State private var perModelSavedFeedback: Bool = false

    init(manager: ServerManager, initialTab: Int = 0) {
        self.manager = manager
        _selectedTab = State(initialValue: initialTab)
        _modelsDir = State(initialValue: manager.settings.modelsDir)
        _defaultPort = State(initialValue: "\(manager.settings.defaultPort)")
        _defaultCtxSize = State(initialValue: manager.formatCtxDisplay(manager.settings.defaultCtxSize))
        _llamaServerPath = State(initialValue: manager.settings.llamaServerPath)
        _mlxServerPath = State(initialValue: manager.settings.mlxServerPath)
        _globalExtraArgs = State(initialValue: manager.settings.globalExtraArgs)
        _chatTemplatePath = State(initialValue: manager.settings.chatTemplatePath)
        _enableMtp = State(initialValue: manager.settings.enableMtp)
        _kvCacheTypeK = State(initialValue: manager.settings.kvCacheTypeK)
        _kvCacheTypeV = State(initialValue: manager.settings.kvCacheTypeV)
        _flashAttention = State(initialValue: manager.settings.flashAttention)
        _thinkingEnabled = State(initialValue: manager.settings.thinkingEnabled)
        _suppressReasoning = State(initialValue: manager.settings.suppressReasoning)
        _temperature = State(initialValue: manager.settings.temperature)
        _topP = State(initialValue: manager.settings.topP)
        _topK = State(initialValue: manager.settings.topK)
        _repeatPenalty = State(initialValue: manager.settings.repeatPenalty)
        _seedStr = State(initialValue: manager.settings.seed == 0 ? "" : "\(manager.settings.seed)")
        _cpuThreadsStr = State(initialValue: manager.settings.cpuThreads == 0 ? "" : "\(manager.settings.cpuThreads)")
        _batchSizeStr = State(initialValue: "\(manager.settings.batchSize)")
        _mlock = State(initialValue: manager.settings.mlock)
        _noMmap = State(initialValue: manager.settings.noMmap)
        _mlxMaxKvSizeStr = State(initialValue: manager.settings.mlxMaxKvSize == 0 ? "" : "\(manager.settings.mlxMaxKvSize)")
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            globalPane.tabItem { Label("Global", systemImage: "gear") }.tag(0)
            modelsPane.tabItem { Label("Per-Model", systemImage: "cube") }.tag(1)
            helpPane.tabItem { Label("Help", systemImage: "questionmark.circle") }.tag(2)
            aboutPane.tabItem { Label("About", systemImage: "info.circle") }.tag(3)
        }
        .padding()
        .frame(width: 580, height: 520)
    }

    /// "Global" tab: basic settings visible by default, advanced settings
    /// hidden inside a DisclosureGroup.
    private var globalPane: some View {
        ScrollView {
            Form {
                // --- Basic settings (always visible) ---
                basicSection
                backendsSection
                chatTemplateSection

                // --- Advanced settings (collapsed by default) ---
                DisclosureGroup("Advanced Settings") {
                    kvCacheSection
                    samplingSection
                    performanceSection
                    mlxSection
                }

                // --- Save / Restore ---
                saveSection
            }
            .padding(.bottom, 8)
        }
        .modifier(GlobalSettingsModifier(manager: manager,
            modelsDir: $modelsDir, defaultPort: $defaultPort,
            defaultCtxSize: $defaultCtxSize, globalExtraArgs: $globalExtraArgs,
            enableMtp: $enableMtp, kvCacheTypeK: $kvCacheTypeK,
            kvCacheTypeV: $kvCacheTypeV, flashAttention: $flashAttention,
            thinkingEnabled: $thinkingEnabled, suppressReasoning: $suppressReasoning,
            llamaServerPath: $llamaServerPath, mlxServerPath: $mlxServerPath,
            chatTemplatePath: $chatTemplatePath,
            temperature: $temperature, topP: $topP, topK: $topK,
            repeatPenalty: $repeatPenalty, seedStr: $seedStr,
            cpuThreadsStr: $cpuThreadsStr, batchSizeStr: $batchSizeStr,
            mlock: $mlock, noMmap: $noMmap, mlxMaxKvSizeStr: $mlxMaxKvSizeStr))
    }

    // MARK: - Global pane sections (split to help Swift's type checker)

    // Basic settings: models directory, port, context size, extra args, MTP.
    private var basicSection: some View {
        Section("Server Defaults") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Models Directory:")
                HStack {
                    TextField("~/models", text: $modelsDir)
                        .help("Root directory containing your .gguf files and MLX model folders.")
                    Button("Browse…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.directoryURL = URL(fileURLWithPath: modelsDir)
                        if panel.runModal() == .OK, let url = panel.url {
                            modelsDir = url.path
                            manager.settings.modelsDir = url.path
                            manager.refreshModels()
                            manager.startWatching()
                        }
                    }
                }
            }
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Default Port:")
                    TextField("8080", text: $defaultPort)
                        .frame(width: 120)
                        .help("TCP port for the first model launched. Subsequent models increment from here.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Default Ctx Size:")
                    TextField("4k", text: $defaultCtxSize)
                        .frame(width: 120)
                        .help("Context window in tokens. Accepts k-suffix (e.g. 4k, 8k) or plain integers (8192).")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Global Extra Args:")
                TextField("--no-mmap", text: $globalExtraArgs)
                    .help("Extra CLI arguments appended to every server launch (both GGUF and MLX).")
            }
            Toggle(isOn: $enableMtp) {
                HStack(spacing: 6) {
                    Text("MTP Enable")
                    Text(enableMtp ? "ON" : "OFF")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(enableMtp ? .orange : .secondary)
                }
            }
            .toggleStyle(.switch)
            .help("Multi-Token Prediction. Enables speculative decoding for faster generation on supported models.")
        }
    }

    private var kvCacheSection: some View {
        Section("KV Cache") {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("K Cache Type:")
                    Picker("", selection: $kvCacheTypeK) {
                        Text("f16 (full)").tag("f16")
                        Text("q8_0 (half)").tag("q8_0")
                        Text("q4_0 (quarter)").tag("q4_0")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 160)
                    .help("Key cache quantization. Lower = less memory, slight quality loss.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("V Cache Type:")
                    Picker("", selection: $kvCacheTypeV) {
                        Text("f16 (full)").tag("f16")
                        Text("q8_0 (half)").tag("q8_0")
                        Text("q4_0 (quarter)").tag("q4_0")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 160)
                    .help("Value cache quantization. q8_0 K + q4_0 V is the Mac default.")
                }
            }
            Toggle(isOn: $flashAttention) {
                HStack(spacing: 6) {
                    Text("Flash Attention")
                    Text(flashAttention ? "ON" : "OFF")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(flashAttention ? .green : .secondary)
                }
            }
            .toggleStyle(.switch)
            .help("Hardware-accelerated attention. Improves speed and reduces memory on Apple Silicon.")
            Toggle(isOn: $thinkingEnabled) {
                HStack(spacing: 6) {
                    Text("Thinking Mode")
                    Text(thinkingEnabled ? "ON" : "OFF")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(thinkingEnabled ? .blue : .secondary)
                }
            }
            .toggleStyle(.switch)
            .help("ON: model reasons before responding (better for coding). OFF: faster, direct answers.")
            Toggle(isOn: $suppressReasoning) {
                HStack(spacing: 6) {
                    Text("Suppress Reasoning Content")
                    Text(suppressReasoning ? "ON" : "OFF")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(suppressReasoning ? .green : .secondary)
                }
            }
            .toggleStyle(.switch)
            .help("Suppresses Gemma 4 reasoning_content that breaks OpenAI-compatible clients.")
        }
    }

    private var samplingSection: some View {
        Section("Sampling") {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Temperature:")
                    TextField("0.8", value: $temperature, format: .number)
                        .frame(width: 80)
                        .help("Randomness: 0.6 coding / 0.8 chat / 1.0 research. Shared by both backends.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top-P:")
                    TextField("0.95", value: $topP, format: .number)
                        .frame(width: 80)
                        .help("Nucleus sampling threshold. 1.0 = off.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top-K:")
                    TextField("20", value: $topK, format: .number)
                        .frame(width: 80)
                        .help("Limits sampling to top K tokens. 0 = off.")
                }
            }
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repeat Penalty:")
                    TextField("1.0", value: $repeatPenalty, format: .number)
                        .frame(width: 80)
                        .help("Penalizes repeated tokens. 1.0 = off, 1.1 = mild.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Seed:")
                    TextField("random", text: $seedStr)
                        .frame(width: 80)
                        .help("Fixed seed for reproducible output. Empty = random.")
                }
            }
        }
    }

    private var performanceSection: some View {
        Section("Performance (llama-server)") {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CPU Threads:")
                    TextField("auto", text: $cpuThreadsStr)
                        .frame(width: 100)
                        .help("Number of CPU threads for GGUF inference. Empty = auto-detect.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Batch Size:")
                    TextField("2048", text: $batchSizeStr)
                        .frame(width: 100)
                        .help("Prompt processing batch size. Larger = faster prompt eval, more memory.")
                }
            }
            Toggle(isOn: $mlock) {
                HStack(spacing: 6) {
                    Text("Mlock")
                    Text(mlock ? "ON" : "OFF")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(mlock ? .green : .secondary)
                }
            }
            .toggleStyle(.switch)
            .help("Lock model in RAM to prevent swapping. Increases memory usage but avoids slowdowns.")
            Toggle(isOn: $noMmap) {
                HStack(spacing: 6) {
                    Text("No-MMap")
                    Text(noMmap ? "ON" : "OFF")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(noMmap ? .green : .secondary)
                }
            }
            .toggleStyle(.switch)
            .help("Disable memory-mapped file loading. Can improve speed on some systems. GGUF only.")
        }
    }

    private var mlxSection: some View {
        Section("MLX") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Max KV Size:")
                TextField("0 = unlimited", text: $mlxMaxKvSizeStr)
                    .frame(width: 120)
                    .help("Caps KV cache memory for MLX. 0 = use model default. Critical on 16GB Macs.")
            }
        }
    }

    private var chatTemplateSection: some View {
        Section("Chat Template") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Template Override:")
                HStack {
                    TextField("Leave empty for built-in template", text: $chatTemplatePath)
                        .help("Custom Jinja/JSON chat template for agentic harnesses (opencode, pi). Leave empty for built-in.")
                    Button("Browse…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        panel.allowedContentTypes = [
                            UTType(filenameExtension: "jinja") ?? .data,
                            UTType(filenameExtension: "json") ?? .data,
                            .data
                        ]
                        if panel.runModal() == .OK, let url = panel.url {
                            chatTemplatePath = url.path
                            manager.settings.chatTemplatePath = url.path
                        }
                    }
                }
            }
        }
    }

    private var backendsSection: some View {
        Section("Backends") {
            VStack(alignment: .leading, spacing: 4) {
                Text("llama-server")
                HStack {
                    TextField("", text: $llamaServerPath)
                        .help("Path to the llama-server binary for GGUF inference.")
                    Button("Browse…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            llamaServerPath = url.path
                            manager.settings.llamaServerPath = url.path
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("mlx_lm.server")
                HStack {
                    TextField("", text: $mlxServerPath)
                        .help("Path to the mlx_lm.server binary for MLX inference.")
                    Button("Browse…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            mlxServerPath = url.path
                            manager.settings.mlxServerPath = url.path
                        }
                    }
                }
            }
        }
    }

    private var saveSection: some View {
        Section {
            HStack {
                Button("Restore Defaults") {
                    let d = AppSettings()
                    modelsDir = d.modelsDir
                    defaultPort = "\(d.defaultPort)"
                    defaultCtxSize = manager.formatCtxDisplay(d.defaultCtxSize)
                    llamaServerPath = d.llamaServerPath
                    mlxServerPath = d.mlxServerPath
                    globalExtraArgs = d.globalExtraArgs
                    chatTemplatePath = d.chatTemplatePath
                    enableMtp = d.enableMtp
                    kvCacheTypeK = d.kvCacheTypeK
                    kvCacheTypeV = d.kvCacheTypeV
                    flashAttention = d.flashAttention
                    thinkingEnabled = d.thinkingEnabled
                    suppressReasoning = d.suppressReasoning
                    temperature = d.temperature
                    topP = d.topP
                    topK = d.topK
                    repeatPenalty = d.repeatPenalty
                    seedStr = d.seed == 0 ? "" : "\(d.seed)"
                    cpuThreadsStr = d.cpuThreads == 0 ? "" : "\(d.cpuThreads)"
                    batchSizeStr = "\(d.batchSize)"
                    mlock = d.mlock
                    noMmap = d.noMmap
                    mlxMaxKvSizeStr = d.mlxMaxKvSize == 0 ? "" : "\(d.mlxMaxKvSize)"
                    manager.settings = d
                    manager.settings.modelsDir = modelsDir
                    manager.saveSettings()
                    manager.refreshModels()
                    manager.startWatching()
                    withAnimation { savedFeedback = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { savedFeedback = false }
                    }
                }
                Spacer()
                Button("Save") {
                    manager.saveSettings()
                    withAnimation { savedFeedback = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { savedFeedback = false }
                    }
                }
                if savedFeedback {
                    Text("✓ Saved")
                        .foregroundColor(.green)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - Help tab

    private var helpPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Quick Start
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quick Start")
                        .font(.headline)
                    Text("1. Set your Models Directory in Global settings.\n2. Click the menu bar icon to see discovered models.\n3. Check models to load them — each runs on its own port.\n4. Use the CLI: \(Text("llama list").font(.system(.body, design: .monospaced))), \(Text("llama load <name>").font(.system(.body, design: .monospaced))), \(Text("llama status").font(.system(.body, design: .monospaced)))")
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Global Settings
                VStack(alignment: .leading, spacing: 8) {
                    Text("Global Settings")
                        .font(.headline)
                    helpRow("Models Directory", "Where LLM Switcher scans for .gguf files and MLX directories (containing .safetensors + config.json).")
                    helpRow("Default Port", "Starting port for model servers. Additional models increment from here (8080, 8081, ...).")
                    helpRow("Default Ctx Size", "Context window size in tokens. Larger = more context but more memory. Use 4k for 16GB Macs, 64k for 32GB+.")
                    helpRow("Global Extra Args", "Free-form arguments passed to every server launch. Parsed with quote handling.")
                    helpRow("MTP Enable", "Multi-Token Prediction. OFF by default — proven net loss on Apple Silicon Metal (11-92% slower). For experimentation only.")
                }

                Divider()

                // Advanced Settings
                VStack(alignment: .leading, spacing: 8) {
                    Text("Advanced Settings")
                        .font(.headline)
                    Text("All defaults below are based on community-researched best practices for macOS Apple Silicon. They are safe starting points — adjust only if you know what you're doing. Use Restore Defaults to reset everything.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)
                    helpRow("K/V Cache Type", "Quantization for KV cache memory — SEPARATE from model quantization. The model quant (Q4_K_M, Q8, etc.) is baked into the GGUF file. KV cache quant controls how the context window is stored in RAM during inference. Safe combinations: any model quant + any KV quant work together. q8_0 K + q4_0 V halves memory with minimal quality loss. f16 = full precision (use only if you have spare RAM).")
                    helpRow("Flash Attention", "Hardware-accelerated attention. Reduces memory and speeds up long context. ON by default — no downside on Apple Silicon.")
                    helpRow("Thinking Mode", "When ON, model generates reasoning tokens before responding. Better for coding, worse for latency. Qwen recommends ON for coding/tools, OFF for constrained Macs.")
                    helpRow("Suppress Reasoning", "Suppresses Gemma 4 reasoning_content that breaks OpenAI-compatible clients (opencode, pi, OpenClaw). ON by default.")
                    helpRow("MTP Enable", "Multi-Token Prediction. OFF by default — proven net loss on Apple Silicon Metal (11-92% slower). Only enable for experimentation.")
                    helpRow("Temperature", "Sampling temperature. 0.6 for coding, 0.8 for chat, 1.0 for research. Default 0.8 is the middle ground.")
                    helpRow("Top-P / Top-K", "Nucleus and top-K sampling. Top-p 0.95 + top-k 20 is the Qwen-recommended standard for all workloads.")
                    helpRow("Repeat Penalty", "Penalizes repeated tokens. 1.0 = no penalty (default), 1.1-1.5 = mild. Increase if the model loops.")
                    helpRow("Seed", "Random seed for reproducible outputs. Empty = random each run. Set a number for deterministic testing.")
                    helpRow("CPU Threads", "Threads for prompt processing. Empty = auto-detect all cores. Only limit on 8GB Macs to prevent CPU contention. GGUF only.")
                    helpRow("Batch Size", "Prompt processing batch size. Larger = faster prompt eval, more memory. Default 2048 is llama.cpp's standard. GGUF only.")
                    helpRow("Mlock", "Locks model in RAM to prevent swap. Only enable if you have spare RAM — it increases memory usage. Good for long-running sessions.")
                    helpRow("No-MMap", "Disables memory-mapped file loading. Can improve speed on NVMe. GGUF only. Note: if this toggle is ON and '--no-mmap' also appears in Global Extra Args, the duplicate is automatically stripped at load time to prevent passing the flag twice to llama-server.")
                    helpRow("Max KV Size", "Caps KV cache memory for MLX. 0 = unlimited (use model default). Set a number like 4096 on 16GB Macs to avoid OOM. MLX only.")
                }

                Divider()

                // Apple Silicon & GPU Layers
                VStack(alignment: .leading, spacing: 8) {
                    Text("Apple Silicon & GPU Layers")
                        .font(.headline)
                    Text("LLM Switcher automatically passes -ngl 99 (all GPU layers) to llama-server. On Apple Silicon, this does NOT mean offloading to a separate GPU VRAM pool — that's an NVIDIA/CUDA concept.\n\nOn Mac, the CPU and GPU share the same unified memory. The -ngl flag tells llama-server to use Metal's compute kernels (dequant + matmul) instead of the CPU path. This is 5-8x faster — without it, models fall back to CPU-only inference.\n\nThe flag name is historical from the CUDA era. On Mac it effectively means 'use Metal for compute' not 'offload to VRAM'. LLM Switcher handles this automatically — no setting needed.")
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Model Quantization Guide
                VStack(alignment: .leading, spacing: 8) {
                    Text("Model Quantization Guide")
                        .font(.headline)
                    Text("Q4_K_M, Q6_K, Q8 etc. are model weight quantization levels — baked into the GGUF file at conversion time. LLM Switcher's KV cache settings (q8_0/q4_0) are separate and control context window storage, not model weights. Any model quant works with any KV cache quant.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)
                    helpRow("8GB", "Qwen3.5-4B Q4_K_M — simple chat only, not for agent work")
                    helpRow("16GB", "Qwen3.5-9B Q4_K_M — practical floor for Hermes tool calling")
                    helpRow("16GB (tight)", "Same model, Q6_K — better tool reliability if RAM permits")
                    helpRow("24GB", "Qwen3.6-27B Q4_K_M — dense, stronger coding")
                    helpRow("32GB+", "Qwen3.6-35B-A3B MLX 4-bit — MoE sweet spot (~3B active/token)")
                    helpRow("48GB+", "Qwen3.6-27B Q6_K — the 'serious agent' quant (Q4 drifts on long tool traces)")
                    helpRow("64GB+", "Qwen3.6-27B Q8 — near-full precision")
                }

                Divider()

                // Recommended Sampling by Workload
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recommended Sampling by Workload")
                        .font(.headline)
                    Text("Based on Qwen community recommendations. Adjust Temperature to match your use case.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)
                    helpRow("Coding / tool loops", "Thinking ON, temp 0.6, top-p 0.95, top-k 20")
                    helpRow("Research / chat", "Thinking ON, temp 0.8-1.0, top-p 0.95, top-k 20")
                    helpRow("Summarization (latency matters)", "Thinking OFF, temp 0.7, top-p 0.8, top-k 20, repeat penalty 1.5")
                    helpRow("Precise structured output", "Thinking ON, temp 0.6, top-p 0.95, top-k 20")
                }

                Divider()

                // Default Values Reference
                VStack(alignment: .leading, spacing: 8) {
                    Text("Default Values Reference")
                        .font(.headline)
                    Text("These are the safe starting points LLM Switcher uses. They come from the r/hermesagent macOS megathread and llama.cpp community testing.\n\nUse Restore Defaults to reset everything to these values at any time.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)
                    helpRow("K Cache: q8_0", "Community default for Mac. Halves KV memory with minimal quality loss.")
                    helpRow("V Cache: q4_0", "More aggressive — quarters KV memory. Pair with q8_0 K for the standard Mac setup.")
                    helpRow("Flash Attention: ON", "No downside on Metal. Reduces memory and speeds up long context.")
                    helpRow("Thinking: ON", "Better for coding/tools. Turn OFF for faster responses on constrained Macs.")
                    helpRow("Suppress Reasoning: ON", "Required for Gemma 4 with OpenAI-compatible clients. Turn OFF if your client handles reasoning_content natively.")
                    helpRow("MTP: OFF", "Net loss on Metal — 11-92% slower across all tested configurations.")
                    helpRow("Temperature: 0.8", "Balanced default. 0.6 coding, 0.8 chat, 1.0 research.")
                    helpRow("Top-P: 0.95", "Qwen-recommended standard for all workloads.")
                    helpRow("Top-K: 20", "Qwen-recommended. Consistent across coding, chat, and research.")
                    helpRow("Repeat Penalty: 1.0", "No penalty. Increase to 1.1-1.5 if model repeats itself.")
                    helpRow("Batch Size: 2048", "llama.cpp default. 512 for 16GB Macs, 4096 for 32GB+.")
                    helpRow("Mlock: OFF", "Only enable with spare RAM to prevent swap death.")
                    helpRow("No-MMap: OFF", "NVMe benefit only. Leave OFF for SSDs.")
                    helpRow("Max KV Size: 0", "Unlimited. Set 4096-8192 on 16GB Macs for MLX.")
                }

                Divider()

                // CLI
                VStack(alignment: .leading, spacing: 8) {
                    Text("CLI Commands")
                        .font(.headline)
                    helpRow("llama list", "List all discovered models with load status.")
                    helpRow("llama load <name>", "Load a model by fuzzy name match.")
                    helpRow("llama unload [name|all]", "Unload one model or all.")
                    helpRow("llama switch <name>", "Unload current, load a new model.")
                    helpRow("llama status", "Show running models with ports and PIDs.")
                    helpRow("llama ctx <size>", "Set per-model context size.")
                    helpRow("llama port <num>", "Set per-model port.")
                    helpRow("llama menubar", "Launch the menu bar app.")
                }

                Divider()

                // Gemma 4 Specifics
                VStack(alignment: .leading, spacing: 8) {
                    Text("Gemma 4 Settings")
                        .font(.headline)
                    Text("Gemma 4 models (12B, 26B-A4B, 31B) require special handling. LLM Switcher applies all of these automatically — no manual configuration needed.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)
                    helpRow("Reasoning Suppression", "Gemma 4 emits a reasoning_content field in its output that crashes OpenAI-compatible clients (opencode, pi, OpenClaw). LLM Switcher passes --reasoning off --reasoning-format none automatically. Turn OFF in Settings only if your client handles reasoning_content natively.")
                    helpRow("mmproj Auto-Pairing", "Gemma 4 is a vision-capable model that needs a separate mmproj (multimodal projection) file for image processing. LLM Switcher finds and attaches it automatically using name-based matching, with fallback to any mmproj-*.gguf in the directory.")
                    helpRow("MTP Heads", "Some Gemma 4 QAT builds ship a separate mtp-*.gguf file. These are NOT standalone models — they're MTP encoder heads loaded automatically by llama-server from model metadata. LLM Switcher excludes them from the model list to prevent confusion.")
                    helpRow("Chat Template Bugs", "The standard Gemma 4 chat template has 4 bugs that break multi-turn tool calling: (1) broken argument formatting, (2) dropped reasoning after 3-4 turns, (3) thinking disabled by default, (4) null corruption. Use a custom .jinja template in Settings > Chat Template for agentic harnesses. Leave empty for regular chat.")
                    helpRow("QAT vs Standard", "QAT (Quantization-Aware Training) models like gemma-4-12B-it-qat-UD-Q4_K_XL.gguf have non-standard naming. The mmproj may be named mmproj-BF16.gguf instead of the standard pattern. LLM Switcher's fallback matching handles this.")
                    helpRow("Thinking Mode", "Add <think> at the start of the system prompt to enable thinking. Don't feed prior thought blocks back into history — they're stateless per turn.")
                }

                Divider()

                // mmproj & MTP
                VStack(alignment: .leading, spacing: 8) {
                    Text("Auto-Pairing & Exclusions")
                        .font(.headline)
                    Text("mmproj files are auto-paired: LLM Switcher strips quantization suffixes from the model name and finds matching mmproj-*.gguf. If name-based matching fails, it falls back to any mmproj file in the directory.\n\nmtp-*.gguf files are excluded from the model list — they're not standalone models. llama-server loads them automatically from model metadata when --mmproj is attached.")
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Per-Model Overrides
                VStack(alignment: .leading, spacing: 8) {
                    Text("Per-Model Overrides")
                        .font(.headline)
                    Text("The Per-Model tab lets you override global settings for individual models. This is useful when different models need different sampling parameters, cache settings, or extra arguments.\n\nHow it works:\n• Each model has an 'Override Global Settings' toggle\n• When OFF: the model inherits all global settings (shown as read-only gray text)\n• When ON: editable fields appear for all overridable settings\n• 'Reset to Global' clears all per-model overrides for that model\n• 'Reset to Default' (override ON) sets per-model values to factory defaults; (override OFF) purges any stored per-model values\n• Restore Defaults (global) does NOT affect per-model overrides\n\n⚠️ IMPORTANT: Per-model settings only take effect when a model is (re)loaded. If a model is already running, you must unload it and load it again for the new settings to apply. Changing settings while a model is running does NOT hot-reload — the running process keeps its original launch arguments until restarted.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)
                    helpRow("Port", "Override the port for this model. Each model runs on its own port.")
                    helpRow("Ctx Size", "Override context window size for this model. Use smaller values for constrained Macs.")
                    helpRow("Temperature", "Per-model temperature. e.g. 0.6 for coding models, 0.8 for chat models.")
                    helpRow("Top-P / Top-K", "Per-model sampling parameters. Override when a model needs different settings than the global default.")
                    helpRow("Repeat Penalty", "Per-model repeat penalty. Increase if a specific model loops or repeats.")
                    helpRow("K/V Cache Type", "Per-model KV cache quantization. Override for models that need different memory/speed tradeoffs.")
                    helpRow("Think", "Per-model thinking mode. Turn OFF for models where you want fast direct answers.")
                    helpRow("MTP", "Per-model MTP enable. Override to enable MTP for specific models while keeping it OFF globally.")
                    helpRow("Extra Args", "Per-model extra arguments. These are APPENDED to global extra args, not replaced. Use for model-specific flags.")
                }

                Divider()

                // Stale Model Cleanup
                VStack(alignment: .leading, spacing: 8) {
                    Text("Automatic Cleanup")
                        .font(.headline)
                    Text("When a model file is deleted or moved out of the models directory, LLM Switcher automatically removes all its per-model settings from UserDefaults on the next refresh. This prevents stale configuration from accumulating.\n\nPer-model settings are stored under model.<hash>.<key> in UserDefaults, where <hash> is the first 12 characters of the MD5 of the model's file path. This is stable across restarts.")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func helpRow(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - About tab

    private var aboutPane: some View {
        ScrollView {
            VStack(spacing: 16) {
                // App icon
                if let img = NSImage(named: "AppIcon") {
                    Image(nsImage: img)
                        .resizable()
                        .frame(width: 80, height: 80)
                } else {
                    Image(systemName: "cpu")
                        .font(.system(size: 56))
                        .foregroundColor(.accentColor)
                        .frame(width: 80, height: 80)
                }

                Text("LLM Switcher")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Version 1.1.0")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text("Manage local LLM models from your menu bar.\nGGUF and Apple MLX on macOS.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Divider()
                    .frame(width: 320)

                // Author
                VStack(spacing: 4) {
                    Text("Roland Chia")
                        .font(.headline)
                    if let url = URL(string: "mailto:z3r09er@gmail.com") {
                        Link("z3r09er@gmail.com", destination: url)
                            .font(.caption)
                    }
                }

                Divider()
                    .frame(width: 320)

                // References
                VStack(spacing: 6) {
                    Text("References")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    if let url = URL(string: "https://github.com/ggml-org/llama.cpp") {
                        Link("llama.cpp", destination: url)
                            .font(.caption)
                    }
                    if let url = URL(string: "https://github.com/ml-explore/mlx-examples") {
                        Link("MLX Examples", destination: url)
                            .font(.caption)
                    }
                    if let url = URL(string: "https://www.reddit.com/r/hermesagent/comments/1uc7rw5/mac_mlx_megathread_hermes_agent_on_apple_silicon/") {
                        Link("r/hermesagent macOS Megathread", destination: url)
                            .font(.caption)
                    }
                    if let url = URL(string: "https://github.com/ggml-org/llama.cpp/issues/23752") {
                        Link("MTP on Metal: Why It's Off by Default", destination: url)
                            .font(.caption)
                    }
                }

                Divider()
                    .frame(width: 320)

                // Data directory
                VStack(spacing: 4) {
                    Text("State Directory")
                        .font(.caption)
                        .fontWeight(.medium)
                    Text("~/.local/share/llama-menubar/")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text("UserDefaults: local.llama-menubar")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Spacer()
                    .frame(height: 8)

                Text("© 2026 Roland Chia. All rights reserved.")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Text("MIT License")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }

    /// "Per-Model" tab: each model shown as a DisclosureGroup card with
    /// a master "Override Global Settings" toggle. When overrides are OFF,
    /// shows a read-only summary of inherited global values (grayed).
    /// When ON, shows editable fields for all overridable settings.
    /// Each card also has a Load/Unload button and a "Reset to Global" button.
    private var modelsPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Per-Model Settings")
                    .font(.headline)
                Spacer()
                Button("Save") {
                    withAnimation { perModelSavedFeedback = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { perModelSavedFeedback = false }
                    }
                }
                if perModelSavedFeedback {
                    Text("✓ Saved")
                        .foregroundColor(.green)
                        .font(.caption)
                }
            }
            Text("Override global settings per model · Settings apply on next model (re)load")
                .font(.caption)
                .foregroundColor(.secondary)

            if manager.models.isEmpty {
                Text("No models found in \(manager.settings.modelsDir)")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(manager.models) { model in
                            perModelCard(for: model)
                        }
                    }
                }
            }
        }
    }

    /// One DisclosureGroup card per model. Shows:
    /// - Model name + backend icon + status + Load/Unload button (always)
    /// - "Override Global Settings" toggle
    /// - When OFF: read-only summary of inherited global values
    /// - When ON: editable fields for all overridable settings + Reset button
    private func perModelCard(for model: ModelEntry) -> some View {
        let state = manager.state(for: model)

        return DisclosureGroup {
            // Always show the override toggle + editable fields.
            // The fields are enabled/disabled based on override state.
            perModelOverrideFields(for: model)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.backend.sfSymbol)
                    .foregroundColor(model.backend == .mlx ? .purple : .blue)
                    .imageScale(.small)
                Text(model.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if state.isRunning {
                    Image(systemName: "circle.fill")
                        .foregroundColor(.green)
                        .imageScale(.small)
                    Text(":\(String(state.port))")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.secondary)
                        .imageScale(.small)
                }
                if state.isRunning {
                    Button("Unload") { manager.unloadModel(model) }
                        .controlSize(.small)
                } else if manager.switchingTo == model.id {
                    Text("Switching…").font(.caption).foregroundColor(.secondary)
                } else {
                    HStack(spacing: 4) {
                        Button("Load") { manager.loadModel(model) }
                            .controlSize(.small)
                        if manager.anyRunning {
                            Button("Switch") { manager.switchModel(model) }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Editable fields shown when overrides are ON. Includes all overridable
    /// settings plus a "Reset to Global" button.
    private func perModelOverrideFields(for model: ModelEntry) -> some View {

        // Read refreshTrigger so SwiftUI re-evaluates this view when it changes.
        // Without this, the if/else below won't update when the toggle or reset
        // buttons bump refreshTrigger (they write to UserDefaults, which SwiftUI
        // can't observe directly). Reading it here creates a dependency.
        let _ = manager.refreshTrigger

        let overrideOn = manager.perModelOverrideEnabled(for: model)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: Binding<Bool>(
                    get: { overrideOn },
                    set: { newVal in
                        manager.setPerModelOverride(newVal, for: model)
                        manager.refreshTrigger += 1
                    }
                )) {
                    Text("Override Global Settings")
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Spacer()

                if overrideOn {
                    Button("Reset to Global") {
                        manager.resetPerModel(for: model)
                        manager.refreshTrigger += 1
                    }
                    .controlSize(.small)
                    .foregroundColor(.red)
                }
            }

            if !overrideOn {
                // Read-only inherited GLOBAL values (not stale per-model saved values).
                // Use String(format:) to avoid comma separators.
                HStack(spacing: 16) {
                    Text("Port: \(String(format: "%d", manager.settings.defaultPort))").font(.caption2).foregroundColor(.secondary)
                    Text("Ctx: \(manager.formatCtxDisplay(manager.settings.defaultCtxSize))").font(.caption2).foregroundColor(.secondary)
                    Text("Temp: \(manager.settings.temperature)").font(.caption2).foregroundColor(.secondary)
                    Text("Top-P: \(manager.settings.topP)").font(.caption2).foregroundColor(.secondary)
                    Text("Top-K: \(manager.settings.topK)").font(.caption2).foregroundColor(.secondary)
                    Text("RP: \(manager.settings.repeatPenalty)").font(.caption2).foregroundColor(.secondary)
                }
                HStack(spacing: 16) {
                    Text("K: \(manager.settings.kvCacheTypeK)").font(.caption2).foregroundColor(.secondary)
                    Text("V: \(manager.settings.kvCacheTypeV)").font(.caption2).foregroundColor(.secondary)
                    Text("Think: \(manager.settings.thinkingEnabled ? "ON" : "OFF")").font(.caption2).foregroundColor(.secondary)
                    Text("MTP: \(manager.settings.enableMtp ? "ON" : "OFF")").font(.caption2).foregroundColor(.secondary)
                }
            } else {
                // Editable fields when override is ON.
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Port:").font(.caption).foregroundColor(.secondary)
                        TextField("", text: Binding<String>(
                            get: { String(format: "%d", manager.perModelPort(for: model)) },
                            set: { if let p = Int($0), p >= 0, p < 65536 { manager.setPerModelPort(p, for: model) } }
                        ))
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ctx:").font(.caption).foregroundColor(.secondary)
                        TextField("", text: Binding<String>(
                            get: { manager.formatCtxDisplay(manager.perModelCtxSize(for: model)) },
                            set: { if let c = manager.parseCtxInput($0) { manager.setPerModelCtxSize(c, for: model) } }
                        ))
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Temp:").font(.caption).foregroundColor(.secondary)
                        TextField("", text: Binding<String>(
                            get: { String(format: "%.2f", manager.perModelSetting("temperature", default: manager.settings.temperature, for: model) as Double) },
                            set: { if let v = Double($0) { manager.setPerModelSetting(v, for: model, key: "temperature") } }
                        ))
                        .frame(width: 50)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Top-P:").font(.caption).foregroundColor(.secondary)
                        TextField("", text: Binding<String>(
                            get: { String(format: "%.2f", manager.perModelSetting("topP", default: manager.settings.topP, for: model) as Double) },
                            set: { if let v = Double($0) { manager.setPerModelSetting(v, for: model, key: "topP") } }
                        ))
                        .frame(width: 50)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    }
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Top-K:").font(.caption).foregroundColor(.secondary)
                        TextField("", text: Binding<String>(
                            get: { String(format: "%d", manager.perModelSetting("topK", default: manager.settings.topK, for: model) as Int) },
                            set: { if let v = Int($0) { manager.setPerModelSetting(v, for: model, key: "topK") } }
                        ))
                        .frame(width: 50)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RP:").font(.caption).foregroundColor(.secondary)
                        TextField("", text: Binding<String>(
                            get: { String(format: "%.2f", manager.perModelSetting("repeatPenalty", default: manager.settings.repeatPenalty, for: model) as Double) },
                            set: { if let v = Double($0) { manager.setPerModelSetting(v, for: model, key: "repeatPenalty") } }
                        ))
                        .frame(width: 50)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("K Cache:").font(.caption).foregroundColor(.secondary)
                        Picker("", selection: Binding<String>(
                            get: { manager.perModelSetting("kvCacheTypeK", default: manager.settings.kvCacheTypeK, for: model) },
                            set: { manager.setPerModelSetting($0, for: model, key: "kvCacheTypeK") }
                        )) {
                            Text("f16").tag("f16")
                            Text("q8_0").tag("q8_0")
                            Text("q4_0").tag("q4_0")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 80)
                        .controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("V Cache:").font(.caption).foregroundColor(.secondary)
                        Picker("", selection: Binding<String>(
                            get: { manager.perModelSetting("kvCacheTypeV", default: manager.settings.kvCacheTypeV, for: model) },
                            set: { manager.setPerModelSetting($0, for: model, key: "kvCacheTypeV") }
                        )) {
                            Text("f16").tag("f16")
                            Text("q8_0").tag("q8_0")
                            Text("q4_0").tag("q4_0")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 80)
                        .controlSize(.small)
                    }
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Think:").font(.caption).foregroundColor(.secondary)
                        Toggle("", isOn: Binding<Bool>(
                            get: { manager.perModelSetting("thinkingEnabled", default: manager.settings.thinkingEnabled, for: model) },
                            set: { manager.setPerModelSetting($0, for: model, key: "thinkingEnabled") }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MTP:").font(.caption).foregroundColor(.secondary)
                        Toggle("", isOn: Binding<Bool>(
                            get: { manager.perModelSetting("enableMtp", default: manager.settings.enableMtp, for: model) },
                            set: { manager.setPerModelSetting($0, for: model, key: "enableMtp") }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Extra Args:").font(.caption).foregroundColor(.secondary)
                    TextField("", text: Binding<String>(
                        get: { manager.perModelSetting("extraArgs", default: manager.settings.globalExtraArgs, for: model) },
                        set: { manager.setPerModelSetting($0, for: model, key: "extraArgs") }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                }
            }

            // Reset button — always visible. Behavior depends on override
            // state to avoid leaking stale per-model keys into UserDefaults:
            //   • Override ON  → write the factory defaults as this model's
            //     per-model values (so the editable fields show defaults).
            //   • Override OFF → there's nothing to edit; clear ALL per-model
            //     keys so no stale values linger and the model cleanly
            //     inherits global settings on next load.
            HStack {
                Spacer()
                Button("Reset to Default") {
                    if manager.perModelOverrideEnabled(for: model) {
                        let d = AppSettings()
                        manager.setPerModelPort(d.defaultPort, for: model)
                        manager.setPerModelCtxSize(d.defaultCtxSize, for: model)
                        manager.setPerModelSetting(d.temperature, for: model, key: "temperature")
                        manager.setPerModelSetting(d.topP, for: model, key: "topP")
                        manager.setPerModelSetting(d.topK, for: model, key: "topK")
                        manager.setPerModelSetting(d.repeatPenalty, for: model, key: "repeatPenalty")
                        manager.setPerModelSetting(d.kvCacheTypeK, for: model, key: "kvCacheTypeK")
                        manager.setPerModelSetting(d.kvCacheTypeV, for: model, key: "kvCacheTypeV")
                        manager.setPerModelSetting(d.thinkingEnabled, for: model, key: "thinkingEnabled")
                        manager.setPerModelSetting(d.enableMtp, for: model, key: "enableMtp")
                        manager.setPerModelSetting(d.globalExtraArgs, for: model, key: "extraArgs")
                    } else {
                        // Override OFF: purge any stale per-model keys.
                        manager.resetPerModel(for: model)
                    }
                    manager.refreshTrigger += 1
                }
                .controlSize(.small)
                .foregroundColor(.secondary)
            }
        }
        .padding(.leading, 4)
    }
}


// MARK: - ServerManager
// -----------------------------------------------------------------------------
//  `ServerManager` is the heart of the app. It owns:
//   - The list of discovered models (`models`).
//   - The map of model-id -> runtime state (`modelStates`).
//   - The map of model-id -> running `Process` (`processes`).
//   - The persistent settings object (`settings`).
//   - The directory watcher (`directorySource` / `directoryFD`).
//
//  Marked `@Observable` (a Swift macro introduced in Swift 5.9) so any
//  SwiftUI view that references its properties auto-re-renders when they
//  change. No `@Published` boilerplate needed.
@Observable
class ServerManager {

    // MARK:   Public state

    /// All models found on disk. Refreshed by `refreshModels()`.
    var models: [ModelEntry] = []
    /// Set of model IDs the user has ticked for loading.
    var selected: Set<String> = []

    /// Persisted global settings (models dir, port, ctx, etc.).
    var settings = AppSettings()

    /// Bumped to force SwiftUI view refresh for per-model override toggles.
    var refreshTrigger: Int = 0

    /// Set to the model ID being switched to, or nil when idle. Used by UI
    /// to disable buttons during the transition and show a "Switching…"
    /// indicator instead of Load. The atomic double-buffer switch spawns
    /// the new model first (on a fresh port), waits for it to be ready on ~5s
    /// timeout, then unloads old models only if the new one is healthy.
    var switchingTo: String? = nil

    // MARK:   Private state

    /// Per-model runtime state, keyed by `ModelEntry.id`.
    private var modelStates: [String: ModelState] = [:]

    /// Processes we started ourselves, keyed by `ModelEntry.id`.
    /// (Externally-launched processes are tracked in `modelStates` but
    /// not here, because we have no `Process` object for them.)
    private var processes: [String: Process] = [:]

    /// Serial queue used for the periodic `ps` reconciliation. Running the
    /// `Process` spawn and pipe reads on a background queue prevents a slow
    /// or hung `ps` from blocking the main thread (which would freeze the
    /// entire menu bar app).
    private let syncQueue = DispatchQueue(label: "local.llama-menubar.sync")

    /// The repeating timer that triggers `syncWithRunningProcesses`. Held
    /// so it can be invalidated on deinit / settings changes if needed.
    @ObservationIgnored
    private var syncTimer: DispatchSourceTimer?

    // MARK:   Sleep / wake
    //
    //  When macBook sleeps, the I/O subsystem suspends and our
    //  `O_EVTONLY` file descriptor (used by `directorySource`) becomes
    //  invalid. If left intact, the DispatchSource may fire spurious
    //  events on the stale FD, or silently stop working. Additionally,
    //  child processes (llama-server / mlx_lm.server) may be killed by
    //  the OS during deep sleep under memory pressure, leaving stale
    //  PIDs in `modelStates`.
    //
    //  We handle this by listening to `NSWorkspace.willSleepNotification`
    //  and `didWakeNotification`:
    //   - onSleep: tear down the watcher + timer before I/O suspends
    //   - onWake:  recreate both on fresh FDs and reconcile process state

    /// Notification observer tokens for sleep/wake. Stored so we can
    /// remove them in `deinit`. The notification center does not retain
    /// block-based observers, so we must hold the token ourselves.
    @ObservationIgnored
    private var sleepObserver: Any?
    @ObservationIgnored
    private var wakeObserver: Any?

    // MARK:   Single-instance guard

    /// File descriptor holding the single-instance advisory lock. Static so
    /// it lives for the whole process and the lock is never released early.
    /// `@ObservationIgnored` is unnecessary on a `static`.
    private static var singleInstanceFD: Int32 = -1

    /// Attempt to take an exclusive, non-blocking advisory lock on a
    /// well-known file. Returns `true` if this process got the lock (it's
    /// the only instance), `false` if another instance already holds it.
    ///
    /// Uses `flock(LOCK_EX | LOCK_NB)`. The lock is associated with the
    /// open file description and is released automatically when the process
    /// exits (clean quit, crash, or kill), so a stale lock file never
    /// blocks a future launch. We keep the fd in a static to avoid closing
    /// it — closing would drop the lock.
    static func acquireSingleInstanceLock() -> Bool {
        let lockPath = NSTemporaryDirectory() + "llm-switcher.lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd != -1 else {
            // If we can't even open the lock file, fail open (allow launch)
            // rather than locking the user out of their own app.
            return true
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            singleInstanceFD = fd   // hold the lock for the process lifetime
            return true
        }
        close(fd)
        return false
    }

    // MARK:   Init / setup

    /// On construction:
    /// 1. Load persisted settings from `UserDefaults`.
    /// 2. Scan the models directory to populate `models`.
    /// 3. Start the file-system watcher.
    /// 4. Start a 3-second timer (on a private background serial queue)
    ///    that periodically reconciles our state with the actual set of
    ///    running `llama-server`/`mlx_lm.server` processes. Running the
    ///    `ps` spawn + pipe reads off the main thread is critical: a slow
    ///    `ps` (large process table, sleep/wake races) must not block the
    ///    main run loop, since that would freeze the menu bar UI.
    init() {
        // H-5 fix: single-instance guard. The LaunchAgent (RunAtLoad=true)
        // and a manual Launchpad/Spotlight open can both start the app,
        // producing two instances that fight over ports, both run the 3s
        // `ps` timer, and both write the same UserDefaults domain. Take an
        // exclusive advisory lock on a well-known file; if another instance
        // already holds it, terminate immediately. The fd is intentionally
        // leaked for the process lifetime so the lock is held until exit
        // (the kernel releases it automatically on process death).
        if !Self.acquireSingleInstanceLock() {
            NSApp.terminate(nil)
            // terminate() is async; hard-exit so we don't continue init.
            exit(0)
        }

        loadSettings()
        refreshModels()
        startWatching()
        startSyncTimer()

        // Register sleep/wake observers. Both fire on the main queue
        // (matching the watcher/timer queues they manage), and use
        // [weak self] to avoid a retain cycle — the notification center
        // does not retain block observers, but the closure could
        // otherwise keep `self` alive past its useful lifetime.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.onSleep()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.onWake()
        }
    }

    /// Start (or restart) the periodic `ps` reconciliation. Using a
    /// `DispatchSourceTimer` on a background queue keeps the spawn + pipe
    /// reads off the main thread, so a slow `ps` can no longer freeze the
    /// UI.
    private func startSyncTimer() {
        syncTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: syncQueue)
        // First fire after 3s, then every 3s. Adding a tiny leeway keeps
        // the timer from waking the CPU unnecessarily while still feeling
        // responsive.
        timer.schedule(deadline: .now() + 3.0, repeating: 3.0, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.syncWithRunningProcesses()
        }
        timer.resume()
        syncTimer = timer
    }

    /// Called just before the system goes to sleep. Tear down the file
    /// system watcher (its FD is invalid after I/O suspension) and cancel
    /// the sync timer so `ps` isn't spawned during the transition.
    ///
    /// Cancelling the DispatchSource stops it from firing; we also nil
    /// the references so `onWake()` (or any later `startWatching()` /
    /// `startSyncTimer()` call) starts cleanly with a fresh instance.
    private func onSleep() {
        directorySource?.cancel()
        directorySource = nil
        syncTimer?.cancel()
        syncTimer = nil
    }

    /// Called after the system wakes from sleep. Recreate the file system
    /// watcher on a fresh FD and restart the sync timer. Then reconcile
    /// process state — child processes may have been killed by the OS
    /// during sleep, so we detect dead PIDs and update the UI.
    ///
    /// Recreate from scratch (rather than trying to resume) because the
    /// old FD is invalid after I/O suspension, and a cancelled
    /// `DispatchSource` cannot be resumed — only recreated.
    private func onWake() {
        startWatching()
        startSyncTimer()
        // Reconcile immediately on a background utility queue so the
        // user gets instant feedback (no 3-second wait for the next
        // timer tick). The ps scan + `kill(pid, 0)` checks run off the
        // main thread; only the final `mergeExternalStates` mutation
        // hops back to main, so the UI stays responsive.
        // H-1 fix: route the wake-time reconcile through the SAME serial
        // `syncQueue` the periodic timer uses, instead of a fresh
        // `DispatchQueue.global` worker. Two concurrent `ps` scans mutating
        // the shared `modelStates`/`processes` dicts is a data race; the
        // serial queue guarantees they never overlap. The final state
        // mutation still hops to main inside `syncWithRunningProcesses`.
        syncQueue.async { [weak self] in
            self?.syncWithRunningProcesses()
        }
    }

    // MARK:   File-system watcher
    //
    //  We use `DispatchSource.makeFileSystemObjectSource` to watch the
    //  PARENT of the models directory. Watching the directory itself
    //  doesn't fire on changes to its subdirectories, so we watch one
    //  level up and re-scan on every change.

    /// The file descriptor for the directory we're watching.
    /// `@ObservationIgnored`: never read by a SwiftUI view, so it must not
    /// add observation overhead (L-6).
    @ObservationIgnored
    private var directoryFD: Int32 = -1

    /// The dispatch source for the file-system events.
    @ObservationIgnored
    private var directorySource: DispatchSourceFileSystemObject?

    /// Start (or restart) watching the models directory.
    func startWatching() {
        // Cancel any prior watcher and close its file descriptor. Without
        // this, repeated calls would leak file descriptors.
        directorySource?.cancel()
        if directoryFD >= 0 {
            close(directoryFD)
            directoryFD = -1
        }

        let dir = URL(fileURLWithPath: settings.modelsDir)
        // Watch the parent so we also see changes to subdirectories
        // (a fresh .gguf file appearing in ~/models/gguf/).
        let watchURL = dir.deletingLastPathComponent()

        // `O_EVTONLY` is a macOS extension that opens the file/folder
        // for monitoring only (no read/write permissions needed).
        let fd = open(watchURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        directoryFD = fd

        // Subscribe to "interesting" events: anything that could mean the
        // directory contents changed.
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )

        // On any event, re-scan. SwiftUI will re-render views that observe
        // `manager.models` automatically.
        src.setEventHandler { [weak self] in
            self?.refreshModels()
        }

        // On cancellation (e.g. when `startWatching` is called again), close
        // the file descriptor.
        src.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.directoryFD >= 0 {
                close(self.directoryFD)
                self.directoryFD = -1
            }
        }

        src.resume()
        directorySource = src
    }

    /// Deinit: ensure the watcher and sync timer are torn down so we don't
    /// leak the FD or keep firing on a dead `self`.
    deinit {
        directorySource?.cancel()
        syncTimer?.cancel()
        // Explicitly remove block-based observers — the notification
        // center does not auto-remove them, so failing to do this leaks
        // the observer tokens and keeps the closure (and any captured
        // objects like `[weak self]`) alive past the lifetime of `self`.
        if let obs = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }

    // MARK: - State queries
    // ----------------------------------------------------------------------------
    //  Computed properties used by the UI. Kept simple and synchronous.

    /// Are any models currently loaded? Used to enable/disable buttons and
    /// to color the menu bar icon.
    var anyRunning: Bool {
        !modelStates.values.filter { $0.isRunning }.isEmpty
    }

    /// Longer text shown at the bottom of the menu, e.g. "2 on :8080, 8081".
    var summaryText: String {
        let running = modelStates.filter { $0.value.isRunning }
        if running.isEmpty { return "All stopped" }
        // L-2 fix: sort ports numerically, not lexicographically. String
        // sort would order e.g. 8080, 808, 8090 as "808, 8080, 8090".
        let ports = running.values.map { $0.port }.sorted().map(String.init).joined(separator: ", ")
        return "\(running.count) on :\(ports)"
    }

    /// Look up the runtime state for a model. Returns a default
    /// `ModelState()` if we have no record of it (i.e. it's not running).
    func state(for model: ModelEntry) -> ModelState {
        modelStates[model.id] ?? ModelState()
    }

    // MARK: - Per-model port/ctx persistence
    //
    //  Per-model port and context size are stored in `UserDefaults` under
    //  `model.<id-hash>.port` and `model.<id-hash>.ctx`. Using the id hash
    //  (not the path) keeps the key short and stable across path renames
    //  (since `ModelEntry.id` is the path, but its `hashValue` is what
    //  we serialize).

    /// Get the saved per-model port (0 if none set).
    func perModelPort(for model: ModelEntry) -> Int {
        UserDefaults.standard.integer(forKey: perModelKey("port", model: model))
    }

    /// Set the per-model port.
    func setPerModelPort(_ port: Int, for model: ModelEntry) {
        UserDefaults.standard.set(port, forKey: perModelKey("port", model: model))
    }

    /// Get the saved per-model context size, or fall back to the default.
    func perModelCtxSize(for model: ModelEntry) -> Int {
        let stored = UserDefaults.standard.integer(forKey: perModelKey("ctx", model: model))
        if stored > 0 { return stored }
        return settings.defaultCtxSize
    }

    /// Set the per-model context size.
    func setPerModelCtxSize(_ ctx: Int, for model: ModelEntry) {
        UserDefaults.standard.set(ctx, forKey: perModelKey("ctx", model: model))
    }

    /// Build a UserDefaults key for a given per-model attribute.
    /// Uses the first 12 hex chars of the MD5 of the path — stable across
    /// restarts (unlike String.hashValue which is randomized per process).
    private func perModelKey(_ suffix: String, model: ModelEntry) -> String {
        let data = Data(model.id.utf8)
        let digest = Insecure.MD5.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "model.\(hex.prefix(12)).\(suffix)"
    }

    /// Compute the model hash prefix (first 12 hex chars of MD5 of model.id).
    /// Used by cleanStalePerModelKeys to identify which model.* keys to keep.
    private func perModelHashPrefix(_ model: ModelEntry) -> String {
        let data = Data(model.id.utf8)
        let digest = Insecure.MD5.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }

    // MARK:   Per-model override enable/disable

    /// Whether per-model override is enabled for this model.
    /// When true, per-model settings are used instead of global defaults.
    func perModelOverrideEnabled(for model: ModelEntry) -> Bool {
        UserDefaults.standard.bool(forKey: perModelKey("overrideEnabled", model: model))
    }

    /// Enable or disable per-model overrides for this model.
    func setPerModelOverride(_ enabled: Bool, for model: ModelEntry) {
        UserDefaults.standard.set(enabled, forKey: perModelKey("overrideEnabled", model: model))
    }

    // MARK:   Generic per-model setting getters/setters

    /// Generic getter for a per-model setting. Uses the per-model UserDefaults key
    /// and falls back to the provided default.
    /// - Parameters:
    ///   - key: The setting name (e.g. "temperature", "topP")
    ///   - defaultValue: Fallback value when no per-model value is stored
    ///   - model: The model to look up
    /// - Returns: The per-model value, or `defaultValue` if none set
    func perModelSetting<T>(_ key: String, default defaultValue: T, for model: ModelEntry) -> T {
        let ud = UserDefaults.standard
        let fullKey = perModelKey(key, model: model)
        if T.self == Bool.self {
            return (ud.object(forKey: fullKey) as? Bool).map { $0 as! T } ?? defaultValue
        }
        return (ud.object(forKey: fullKey) as? T) ?? defaultValue
    }

    /// Generic setter for a per-model setting.
    /// - Parameters:
    ///   - value: The value to store
    ///   - model: The model to set it for
    ///   - key: The setting name (e.g. "temperature", "topP")
    func setPerModelSetting<T>(_ value: T, for model: ModelEntry, key: String) {
        UserDefaults.standard.set(value, forKey: perModelKey(key, model: model))
    }

    /// Check if a per-model key exists (object is present, not just default).
    func perModelSettingExists(_ key: String, for model: ModelEntry) -> Bool {
        UserDefaults.standard.object(forKey: perModelKey(key, model: model)) != nil
    }

    // MARK:   Per-model reset and cleanup

    /// Remove ALL per-model settings for a model (including overrideEnabled).
    /// This effectively resets the model to use global settings.
    func resetPerModel(for model: ModelEntry) {
        let hashPrefix = perModelHashPrefix(model)
        let prefix = "model.\(hashPrefix)."
        let allKeys = Array(UserDefaults.standard.dictionaryRepresentation().keys)
        for key in allKeys where key.hasPrefix(prefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Remove stale per-model UserDefaults keys for models no longer in the
    /// scan directory. Called at the end of refreshModels() to garbage-collect
    /// keys from deleted or moved model files.
    func cleanStalePerModelKeys() {
        let validHashes = Set(models.map { perModelHashPrefix($0) })
        // M-5 fix: filter to our `model.` namespace up front so we iterate
        // only our own keys, not the hundreds of unrelated system/other-app
        // keys that `dictionaryRepresentation()` returns. Keeps the
        // main-thread work during a file-watcher refresh small.
        let ourKeys = UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("model.") }
        for key in ourKeys {
            // Match keys of the form "model.<12hex>.<suffix>"
            let parts = key.split(separator: ".")
            // parts[0] = "model", parts[1] = hash, parts[2] = suffix
            guard parts.count >= 3 else { continue }
            let hash = String(parts[1])
            if !validHashes.contains(hash) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    // MARK:   Context size helpers

    /// Parse context size input: "8k" → 8192, "12k" → 12288, "4096" → 4096.
    /// Returns nil on invalid input.
    func parseCtxInput(_ s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasSuffix("k") {
            let num = String(trimmed.dropLast())
            guard let v = Double(num), v > 0 else { return nil }
            return Int(v * 1024)
        }
        guard let v = Int(trimmed), v > 0 else { return nil }
        return v
    }

    /// Format context for display: 8192 → "8k", 12288 → "12k", 5000 → "5000".
    func formatCtxDisplay(_ n: Int) -> String {
        guard n > 0, n % 1024 == 0 else { return "\(n)" }
        return "\(n / 1024)k"
    }

    // MARK: - Model discovery (recursive)
    // ----------------------------------------------------------------------------
    //  `refreshModels` is the entry point; it walks the models directory
    //  recursively, classifying each file/dir as a model or not, and
    //  building a deduplicated, sorted list of `ModelEntry` values.

    /// Re-scan the models directory and update `self.models`.
    func refreshModels() {
        let dir = URL(fileURLWithPath: settings.modelsDir)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            // Directory doesn't exist (yet) — show no models.
            models = []
            return
        }
        var entries: [ModelEntry] = []
        // Recursive scan. We pass `baseDir` (currently unused) for
        // future expansion — e.g. computing relative paths for display.
        scanDirectory(dir, into: &entries, baseDir: dir)
        // Dedupe by id and sort alphabetically by name.
        var seen = Set<String>()
        models = entries.filter { seen.insert($0.id).inserted }
            .sorted { $0.name < $1.name }
        // Process state is reconciled by the background sync timer
        // (every 3s), NOT synchronously here. A blocking ps scan in
        // refreshModels() would freeze the main thread during init.
        // Clean up stale per-model UserDefaults keys for models no longer
        // in the scan directory (deleted, moved, or renamed models).
        cleanStalePerModelKeys()
    }

    /// Recursive directory walker. For each child of `dir`:
    ///   - Hidden files / directories: skip.
    ///   - Subdirectory: if it looks like an MLX model, add it; otherwise
    ///     recurse into it.
    ///   - `.gguf` file: add it as a GGUF model.
    private func scanDirectory(_ dir: URL, into entries: inout [ModelEntry], baseDir: URL, depth: Int = 0) {
        // M-6 fix: cap recursion depth so a symlink loop (e.g.
        // ~/models/link -> ~/models) can't recurse forever and hang the
        // main thread (the file watcher fires `refreshModels` on .main).
        // 12 levels is far deeper than any real model directory layout.
        guard depth < 12 else { return }
        let fm = FileManager.default
        // `skipsHiddenFiles` excludes dotfiles. `skipsPackageDescendants`
        // avoids descending into .app, .bundle, etc.
        guard let contents = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        for url in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let name = url.lastPathComponent
            // Belt-and-suspenders: skip hidden.
            if name.hasPrefix(".") { continue }

            if isDir.boolValue {
                // Directory: try to interpret as an MLX model first;
                // if it doesn't look like one, recurse.
                if let entry = mlxEntry(at: url, baseDir: baseDir) {
                    entries.append(entry)
                } else {
                    scanDirectory(url, into: &entries, baseDir: baseDir, depth: depth + 1)
                }
            } else if url.pathExtension.lowercased() == "gguf" {
                // Regular .gguf file: classify and add.
                if let entry = ggufEntry(at: url, baseDir: baseDir) {
                    entries.append(entry)
                }
            }
        }
    }

    /// Classify a `.gguf` file as a model. Excludes:
    ///   - `mmproj-*.gguf`        — vision projection files, paired with
    ///                               a vision-capable base model. They're
    ///                               not standalone models; we auto-pair
    ///                               them in `findMmproj(for:)`.
    ///   - `mtp-*.gguf`           — multi-token prediction head files,
    ///                               paired with the base model. Excluded
    ///                               from the model list; loaded
    ///                               automatically by llama-server from
    ///                               model metadata when --mmproj is
    ///                               attached. Note: only the `mtp-`
    ///                               prefix is excluded; files containing
    ///                               `-mtp-` as an infix
    ///                               (e.g. `gemma-3-mtp-Q4_K_M.gguf`) are
    ///                               treated as regular models.
    ///   - `modernbert-embed-*.gguf` — embedding models used by the
    ///                                 gbrain system. Not a chat model.
    private func ggufEntry(at url: URL, baseDir: URL) -> ModelEntry? {
        let lname = url.lastPathComponent.lowercased()
        if lname.hasPrefix("mmproj-") { return nil }
        if lname.hasPrefix("mtp-") { return nil }
        if lname.hasPrefix("modernbert-embed-") { return nil }
        return ModelEntry(
            id: url.path,
            name: url.lastPathComponent,
            path: url,
            backend: .gguf
        )
    }

    /// Classify a directory as an MLX model. An MLX model is a directory
    /// that contains BOTH `*.safetensors` (weights) and `config.json`
    /// (model configuration). The presence of both is a reliable
    /// heuristic — random data dirs won't have both.
    private func mlxEntry(at dir: URL, baseDir: URL) -> ModelEntry? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return nil }
        let hasSafetensors = contents.contains { $0.pathExtension.lowercased() == "safetensors" }
        let hasConfig = contents.contains { $0.lastPathComponent.lowercased() == "config.json" }
        if hasSafetensors && hasConfig {
            return ModelEntry(
                id: dir.path,
                name: dir.lastPathComponent,
                path: dir,
                backend: .mlx
            )
        }
        return nil
    }

    // MARK: - Load / Unload
    // ----------------------------------------------------------------------------
    //  `loadModel` spawns a new `llama-server` or `mlx_lm.server` process
    //  for a model. `unloadModel` terminates it. `unloadAll` cleans up
    //  everything. All three methods are safe to call from the UI thread.

    /// Start a server for the given model. No-op if it's already running.
    func loadModel(_ model: ModelEntry) {



        // Don't start a second instance of the same model.
        if let s = modelStates[model.id], s.isRunning { return }

        // Pick a port: prefer the per-model saved port (only when override
        // is enabled); otherwise the first available port from defaultPort.
        let overrides = perModelOverrideEnabled(for: model)
        let preferredPort = overrides ? perModelPort(for: model) : 0
        let port = preferredPort > 0 ? preferredPort : nextAvailablePort()
        let ctx = overrides ? perModelCtxSize(for: model) : settings.defaultCtxSize

        // Helper: get a setting value — per-model override if enabled + exists,
        // otherwise global.
        func pm<T>(_ key: String, global globalVal: T, for model: ModelEntry) -> T {
            if overrides && perModelSettingExists(key, for: model) {
                return perModelSetting(key, default: globalVal, for: model)
            }
            return globalVal
        }

        // Resolve effective settings for this model load.
        let effTemp = pm("temperature", global: settings.temperature, for: model)
        let effTopP = pm("topP", global: settings.topP, for: model)
        let effTopK = pm("topK", global: settings.topK, for: model)
        let effRepeatPenalty = pm("repeatPenalty", global: settings.repeatPenalty, for: model)
        let effKvK = pm("kvCacheTypeK", global: settings.kvCacheTypeK, for: model)
        let effKvV = pm("kvCacheTypeV", global: settings.kvCacheTypeV, for: model)
        let effThinking = pm("thinkingEnabled", global: settings.thinkingEnabled, for: model)
        let effMtp = pm("enableMtp", global: settings.enableMtp, for: model)
        let effExtraArgs = pm("extraArgs", global: settings.globalExtraArgs, for: model)

        // Build the command line.
        let task = Process()
        var args: [String] = []
        var executable: String

        switch model.backend {
        case .gguf:
            // GGUF: invoke llama-server with -m <model>.
            executable = settings.llamaServerPath
            args += ["-m", model.path.path]
            // Auto-attach a matching mmproj projection model if present.
            // This enables vision models (e.g. gemma-3) without manual
            // configuration.
            if let mmproj = findMmproj(for: model.path) {
                args += ["--mmproj", mmproj.path]
            }
            // MTP heads are loaded automatically by llama-server from model
            // metadata when --mmproj is attached. No --mtp flag needed.

            // Apply chat template override if configured in settings.
            // Agentic harnesses (opencode, pi) need custom templates to fix
            // tool-calling edge cases (broken arg formatting, dropped reasoning,
            // disabled thinking, null corruption).
            if !settings.chatTemplatePath.isEmpty &&
               FileManager.default.fileExists(atPath: settings.chatTemplatePath) {
                args += ["--chat-template", settings.chatTemplatePath]
            }
            // All GPU layers on Metal — on Apple Silicon, Metal compute
            // is significantly faster than CPU fallback for all transformer
            // layers. Unified memory means no VRAM/RAM split.
            args += ["-ngl", "99"]

            // Context size (only set if explicitly configured).
            if ctx > 0 {
                args += ["--ctx-size", "\(ctx)"]
            }
            // KV cache quantization — critical for Mac memory management.
            // q8_0 K + q4_0 V halves KV memory with minimal quality loss.
            args += ["--cache-type-k", effKvK,
                     "--cache-type-v", effKvV]

            // Flash attention — reduces KV memory and speeds up long context.
            if settings.flashAttention {
                args += ["-fa", "on"]
            }

            // Reasoning suppression — Gemma 4 emits reasoning_content that
            // breaks OpenAI-compatible clients (opencode, pi, OpenClaw).
            // See docs/GEMMA4_LOADING_DETAILS.md §3.2.
            if settings.suppressReasoning {
                args += ["--reasoning", "off", "--reasoning-format", "none"]
            }

            // Thinking mode — when enabled, model generates reasoning tokens
            // before responding. Better for coding/tools, worse for latency.
            if !effThinking {
                args += ["--chat-template-kwargs", "{\"enable_thinking\":false}"]
            }

            // MTP (Multi-Token Prediction): opt-in only. On Apple Silicon
            // Metal, MTP is a proven net loss for every configuration
            // tested (11-92% slower). Off by default.
            // https://github.com/ggerganov/llama.cpp/issues/23752
            if effMtp {
                args += ["--spec-type", "draft-mtp"]
            }

            // Sampling defaults — shared with MLX.
            args += ["--temp", "\(effTemp)",
                     "--top-p", "\(effTopP)",
                     "--top-k", "\(effTopK)",
                     "--repeat-penalty", "\(effRepeatPenalty)"]
            if settings.seed > 0 {
                args += ["--seed", "\(settings.seed)"]
            }

            // Performance (llama-server only).
            if settings.cpuThreads > 0 {
                args += ["-t", "\(settings.cpuThreads)"]
            }
            args += ["-b", "\(settings.batchSize)"]
            if settings.mlock {
                args += ["--mlock"]
            }
            if settings.noMmap {
                args += ["--no-mmap"]
            }
        case .mlx:
            // MLX: invoke mlx_lm.server with --model <dir>.
            executable = settings.mlxServerPath
            args += ["--model", model.path.path]

            // Sampling defaults — shared with llama-server.
            args += ["--temp", "\(effTemp)",
                     "--top-p", "\(effTopP)",
                     "--top-k", "\(effTopK)"]
            if settings.seed > 0 {
                args += ["--seed", "\(settings.seed)"]
            }
            // Max KV size — caps memory for MLX on constrained Macs.
            if settings.mlxMaxKvSize > 0 {
                args += ["--max-kv-size", "\(settings.mlxMaxKvSize)"]
            }
        }

        // Bind to localhost (security + convenience) and the chosen port.
        args += ["--host", "127.0.0.1", "--port", "\(port)"]

        // Append any extra args (per-model override or global).
        // We use a small parser to handle quoted args.
        // Reconcile: strip --no-mmap if the toggle already handles it.
        var cleanExtra = effExtraArgs
        if settings.noMmap && cleanExtra.contains("--no-mmap") {
            cleanExtra = cleanExtra.replacingOccurrences(of: "--no-mmap", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        if !cleanExtra.isEmpty {
            args += parseArgs(cleanExtra)
        }

        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args

        // Capture the model ID by value (not the `model` reference) so
        // the termination handler can use it safely later.
        let modelId = model.id

        // When the process exits (cleanly or via signal), clear its state
        // and remove it from our `processes` map. The closure runs on a
        // background thread, so we hop to the main queue before mutating
        // `@Observable` state.
        task.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                // Only clear state if the PID still matches — a model
                // may have been reloaded before the old process exited.
                if var s = self.modelStates[modelId],
                   s.pid == task.processIdentifier {
                    s.isRunning = false
                    s.pid = nil
                    self.modelStates[modelId] = s
                }
                if self.processes[modelId] === task {
                    self.processes[modelId] = nil
                }
            }
        }

        // Redirect the child's stdout/stderr to /dev/null. The previous
        // implementation created a `Pipe()` but never read from it; the
        // local reference went out of scope as soon as this method
        // returned, the read end was closed, and the kernel pipe buffer
        // (~64KB on macOS) filled up the moment the child produced enough
        // log output. The child's `write(2)` would then block in the
        // kernel and the model server would freeze during loading. The
        // `llama` CLI captures per-model log files; this app does not,
        // so discarding the child's output is the correct behavior.
        let devnull: FileHandle = FileHandle(forWritingAtPath: "/dev/null") ?? FileHandle.nullDevice
        task.standardOutput = devnull
        task.standardError = devnull

        do {
            try task.run()

            // Record the process and update state. The PID comes from
            // `processIdentifier` (POSIX `pid_t`).
            processes[model.id] = task
            var s = modelStates[model.id] ?? ModelState()
            s.isRunning = true
            s.pid = task.processIdentifier
            s.port = port
            s.ctxSize = ctx
            s.lastError = nil   // clear any stale error from a prior failed load
            modelStates[model.id] = s
        } catch {
            // C-1 fix: don't swallow the failure. The most common cause is
            // a wrong/missing binary path (llama-server / mlx_lm.server),
            // which previously produced ZERO feedback — the model just
            // never appeared to load. Record the error in model state so
            // the menu can show it, and beep so the user notices.
            var s = modelStates[model.id] ?? ModelState()
            s.isRunning = false
            s.pid = nil
            s.lastError = "\(error.localizedDescription)"
            modelStates[model.id] = s
            NSSound.beep()
        }
    }

    /// Stop the server for a single model. Sends SIGTERM to the process
    /// (and falls back to SIGKILL after a short wait). Also handles
    /// externally-launched processes by killing them by PID.
    func unloadModel(_ model: ModelEntry) {
        // Send SIGTERM via exactly one path:
        //   - Owned process (`processes[id]`): use `Process.terminate()`
        //     which sends SIGTERM and lets the `terminationHandler`
        //     clear state.
        //   - External process (only PID in `modelStates`): use
        //     `kill(2)` directly since we have no `Process` object.
        // The `else if` is critical — doing both would double-signal
        // the process, and after the first SIGTERM kills it the PID
        // could be recycled by an unrelated process before the second
        // `kill()` fires.
        if let p = processes[model.id] {
            p.terminate()
            processes[model.id] = nil
        } else if let s = modelStates[model.id], let pid = s.pid {
            kill(pid, SIGTERM)
        }

        // Clear local state.
        if var s = modelStates[model.id] {
            s.isRunning = false
            s.pid = nil
            modelStates[model.id] = s
        }
    }

    /// Stop every running model. Used by the "Unload All" button and on
    /// app quit. Syncs state first so we don't miss externally-launched
    /// processes.
    ///
    /// PIDs of externally-launched processes are expected to already be
    /// in `modelStates` from the background sync timer. We do NOT call
    /// `collectExternalStatesFromPS()` here — a hanging `ps` would block
    /// the main thread and freeze the menu bar / prevent quitting.
    func unloadAll() {
        // Iterate over a snapshot of keys (we mutate `modelStates` inside
        // `unloadModel`).
        for id in Array(processes.keys) {
            if let m = models.first(where: { $0.id == id }) {
                unloadModel(m)
            }
        }
        // Now handle any remaining running models (those we don't have a
        // `Process` object for, e.g. externally launched).
        for (id, state) in modelStates where state.isRunning {
            if let m = models.first(where: { $0.id == id }) {
                unloadModel(m)
            } else {
                // No matching `ModelEntry` — just kill the PID.
                // H-4 fix: also clear the state here. Previously the
                // `modelStates[id]` entry kept `isRunning = true` until the
                // next 3s sync, so the "⏹ Unload All" button left stale
                // rows in the menu for up to 3 seconds when the model file
                // had been deleted out from under us.
                if let pid = state.pid {
                    kill(pid, SIGTERM)
                }
                var s = state
                s.isRunning = false
                s.pid = nil
                modelStates[id] = s
            }
        }
    }

    /// Atomically switch to a single model using the double-buffer strategy:
    ///
    /// 1. Load the new model on a **fresh** port (old models keep running
    ///    — no gap where the user has zero models loaded).
    /// 2. Poll for readiness (process alive + port bound, timeout ~5s).
    /// 3. If ready → unload all old models. If not → unload the new model
    ///    and keep the old ones running (rollback). The error is already in
    ///    `modelStates[model.id].lastError` from the C-1 catch.
    ///
    /// Contrast with the CLI's `switch` command which does an unload-all
    /// first, leaving the user with nothing if the new model fails to load.
    func switchModel(_ model: ModelEntry) {
        // Already running this model → no-op.
        guard !state(for: model).isRunning else { return }
        // Snapshot of what's currently running (for rollback).
        let oldRunning: [(model: ModelEntry, state: ModelState)] = models.compactMap { m in
            let s = state(for: m)
            guard s.isRunning && m.id != model.id else { return nil }
            return (m, s)
        }
        // Mark switching UI state.
        switchingTo = model.id

        // Step 1: load the target. `loadModel` picks a fresh port via
        // `nextAvailablePort()` which now (M-1) also probes the port with
        // a real bind() — since the old models still hold their ports, the
        // new model gets a different one automatically.
        loadModel(model)

        // Step 2: wait for the new server to confirm it's listening.
        let deadline = Date().addingTimeInterval(5.0)
        var isReady = false
        pollLoop: while Date() < deadline {
            guard let s = modelStates[model.id], s.isRunning, let pid = s.pid else {
                break  // process died → loadModel already recorded the error
            }
            if kill(pid, 0) == 0 && !Self.portIsFree(s.port) {
                // Process alive AND port is bound (not free) → ready.
                isReady = true
                break pollLoop
            }
            Thread.sleep(forTimeInterval: 0.25)
        }

        if isReady {
            // Step 3: swap complete — unload old models.
            for entry in oldRunning {
                unloadModel(entry.model)
            }
        } else {
            // Step 4: rollback — new model failed, unload it.
            unloadModel(model)
        }

        switchingTo = nil
    }

    /// Find the smallest unused port starting at `defaultPort`.
    /// Used when no per-model port has been set.
    ///
    /// M-1 fix: in addition to skipping ports we already track as in-use,
    /// probe each candidate with a real `bind()` to localhost so we also
    /// skip ports held by processes we don't manage (another app, a stale
    /// server, a different tool). Previously we'd hand out a port that was
    /// taken by an unmanaged process, `llama-server` would fail to bind,
    /// and (pre-C-1) the failure was swallowed silently.
    private func nextAvailablePort() -> Int {
        let usedPorts = Set(modelStates.values.compactMap { $0.isRunning ? $0.port : nil })
        var port = settings.defaultPort
        // Cap the search so a fully-saturated range can't loop forever.
        let maxPort = min(settings.defaultPort + 200, 65535)
        while port <= maxPort {
            if !usedPorts.contains(port) && Self.portIsFree(port) {
                return port
            }
            port += 1
        }
        // Fall back to the default if nothing probed free (the spawn will
        // surface the bind error via C-1 rather than hang here).
        return settings.defaultPort
    }

    /// Probe whether a TCP port is free by attempting a `bind()` on
    /// 127.0.0.1. Returns true if the bind succeeds (port available). The
    /// socket is closed immediately; this is a best-effort check (a TOCTOU
    /// race is possible but harmless — the spawn surfaces any real
    /// collision via C-1). Async-signal-unsafe; main/background only.
    static func portIsFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }   // can't probe → assume free
        defer { close(fd) }
        // SO_REUSEADDR so a recently-closed port in TIME_WAIT doesn't read
        // as taken.
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }

    /// Discover the `mlx_lm.server` executable path instead of hardcoding a
    /// Python version (L-7 fix). Tries, in order: `which mlx_lm.server` on
    /// PATH, then the per-version Python user-install bin dirs from newest
    /// to oldest. Returns the first hit, or a sensible 3.14 fallback so the
    /// Settings field is never empty (the user can still override it).
    static func discoverMLXServerPath() -> String {
        let home = NSHomeDirectory()
        // 1. PATH lookup via `which` (covers Homebrew, pipx, venvs on PATH).
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", "mlx_lm.server"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        if (try? which.run()) != nil {
            which.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let out = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
               !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) {
                return out
            }
        }
        // 2. Probe Python user-install bin dirs, newest version first.
        let versions = ["3.14", "3.13", "3.12", "3.11", "3.10"]
        for v in versions {
            let p = "\(home)/Library/Python/\(v)/bin/mlx_lm.server"
            if FileManager.default.isExecutableFile(atPath: p) {
                return p
            }
        }
        // 3. Fallback — keep the field populated; user can override.
        return "\(home)/Library/Python/3.14/bin/mlx_lm.server"
    }

    /// Shared helper for finding companion GGUF files (e.g. mmproj) that
    /// match a base model by name with quantization stripped. The `prefix`
    /// parameter selects the companion type (e.g. "mmproj").
    ///
    /// Example: `gemma-4-12B-it-Q4_K_M.gguf` with prefix `"mmproj"` matches
    /// `mmproj-gemma-4-12B-it-Q8_0.gguf`.
    ///
    /// Matching strategy:
    ///   1. Name-based: strip quantization from the model name, look for
    ///      `<prefix>-<stripped>*` in the same directory.
    ///   2. Fallback: if name-based fails, find ANY `<prefix>-*.gguf` in
    ///      the same directory. This handles models with non-standard
    ///      naming (e.g. QAT builds where the mmproj is named
    ///      `mmproj-BF16.gguf` instead of `mmproj-<modelname>-Q8_0.gguf`).
    ///
    /// Returns the first alphabetically-sorted match, or nil if none.
    private func findCompanion(for modelURL: URL, prefix: String) -> URL? {
        let dir = modelURL.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return nil }

        // Step 1: name-based matching — strip quantization, look for
        // `<prefix>-<stripped>*`.
        // L-3 fix: strip ALL quant suffixes via regex instead of a handful
        // of hardcoded ones. Covers -Q2_K…-Q8_0, K-quants, I-quants
        // (-IQ4_NL), and float types (-F16/-F32/-BF16). Matches the CLI's
        // `sed -E 's/-Q[0-9]+(_[0-9]+)?(_K)?(_[A-Z]+)?$//'` behavior.
        let base = modelURL.deletingPathExtension().lastPathComponent
        let stripped = base.replacingOccurrences(
            of: #"-(Q\d+(_\d+)?(_K)?(_[A-Z]+)?|IQ\d+(_[A-Z]+)+|F16|F32|BF16)$"#,
            with: "",
            options: .regularExpression
        )

        let pattern = "\(prefix)-\(stripped)"
        let nameMatches = entries.filter {
            $0.lastPathComponent.hasPrefix(pattern) && $0.pathExtension == "gguf"
        }
        if let first = nameMatches.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first {
            return first
        }

        // Step 2: fallback — find any `<prefix>-*.gguf` in the directory.
        // This catches models with non-standard naming (e.g. QAT builds,
        // generic mmproj files like `mmproj-BF16.gguf`).
        let fallbackMatches = entries.filter {
            $0.lastPathComponent.hasPrefix("\(prefix)-") && $0.pathExtension == "gguf"
        }
        return fallbackMatches.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
    }

    /// Find a matching `mmproj-*.gguf` vision projection file for a model.
    private func findMmproj(for modelURL: URL) -> URL? {
        findCompanion(for: modelURL, prefix: "mmproj")
    }



    /// Split a free-form "extra args" string into argv-style tokens.
    /// Honors single and double quotes so `--prompt "hello world"` parses
    /// as two tokens: `--prompt` and `hello world`.
    private func parseArgs(_ s: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inQuote = false
        var escaped = false
        for ch in s {
            // M-8 fix: honor backslash escapes. A `\` makes the next char
            // literal (so `\"` is a literal quote, `\ ` a literal space)
            // instead of toggling quote state or splitting the token.
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" || ch == "'" {
                inQuote.toggle()
            } else if ch == " " && !inQuote {
                if !current.isEmpty { args.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        // A trailing lone backslash is kept literally rather than dropped.
        if escaped { current.append("\\") }
        if !current.isEmpty { args.append(current) }
        return args
    }

    // MARK: - Sync with external processes
    // ----------------------------------------------------------------------------
    //  The companion `llama` CLI can launch `llama-server` / `mlx_lm.server`
    //  processes independently of this app. To keep the menu bar accurate,
    //  we periodically scan `ps` output, parse out any model-related
    //  processes, and reconcile `modelStates` with reality.

    /// Merge externally-discovered running processes into `modelStates`.
    /// Clears stale entries and garbage-collects models no longer on disk.
    /// Must be called on the main thread (accesses `@Observable` state).
    private func mergeExternalStates(_ externalStates: [String: (pid: Int32, port: Int, ctx: Int)]) {
        // Merge: for each external process, mark its model as running
        // with the observed PID/port/ctx.
        for (id, ext) in externalStates {
            var s = modelStates[id] ?? ModelState()
            s.isRunning = true
            s.pid = ext.pid
            s.port = ext.port
            s.ctxSize = ext.ctx
            modelStates[id] = s
        }
        // Clear stale state: any model we previously thought was
        // running but that doesn't show up in `ps` anymore is now
        // stopped. Also drop entries whose backing model no longer
        // exists on disk so the dictionaries don't grow forever.
        let knownIDs = Set(models.map { $0.id })
        for id in Array(modelStates.keys) {
            guard let s = modelStates[id] else { continue }
            if s.isRunning && externalStates[id] == nil {
                // The `ps` scan may legitimately miss a running
                // process: regex fails on paths with spaces, output
                // truncated, or the process is mid-startup/shutdown.
                // Before clearing state, verify the PID is actually
                // dead via `kill(pid, 0)` (which sends no signal —
                // it just tests for existence). This prevents
                // loaded models from falsely appearing stopped.
                if let pid = s.pid, kill(pid, 0) == 0 {
                    // PID alive — keep the running state.
                } else {
                    var cleared = s
                    cleared.isRunning = false
                    cleared.pid = nil
                    modelStates[id] = cleared
                }
            }
            if !knownIDs.contains(id) {
                modelStates[id] = nil
                processes[id] = nil
            }
        }
    }

    /// Reconcile `modelStates` with the actual set of running server
    /// processes on the system. Called every 3s by the timer in `init`.
    ///
    /// This method is safe to call from any thread. The `ps` spawn and
    /// pipe reads happen synchronously on the calling thread; the
    /// dictionary mutations are then hopped to the main queue because
    /// `modelStates` is observed by SwiftUI.
    func syncWithRunningProcesses() {
        // Run `ps` on whatever thread we were called from. Callers fire
        // this from the background `syncQueue`, so a slow `ps` can no
        // longer freeze the main thread.
        let externalStates = collectExternalStatesFromPS()

        DispatchQueue.main.async { [weak self] in
            self?.mergeExternalStates(externalStates)
        }
    }

    /// Spawn `/bin/ps` synchronously and parse its output into a
    /// `[modelID : (pid, port, ctx)]` map. This call is potentially
    /// long-running (it blocks on `ps` finishing), so callers should
    /// invoke it off the main thread.
    private func collectExternalStatesFromPS() -> [String: (pid: Int32, port: Int, ctx: Int)] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-ax", "-o", "pid=,command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        // Redirect stderr to /dev/null to avoid pipe leak.
        if let dn = FileHandle(forWritingAtPath: "/dev/null") {
            task.standardError = dn
        } else {
            task.standardError = FileHandle.nullDevice
        }
        do {
            try task.run()
            // Wait for `ps` to finish; the output is small.
            task.waitUntilExit()
        } catch {
            // If `ps` itself failed (very unusual), bail out.
            return [:]
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        var externalStates: [String: (pid: Int32, port: Int, ctx: Int)] = [:]

        for line in output.split(separator: "\n") {
            let s = String(line)
            guard s.contains("llama-server") || s.contains("mlx_lm.server") else { continue }
            // Skip our own `ps` invocation. Without this, we'd detect the
            // `ps` command's own grep matches.
            if s.contains("syncWithRunning") { continue }

            let mPattern: String
            let dropLen: Int
            if s.contains("llama-server") {
                // H-3 fix: allow spaces inside the path. The old pattern
                // `-m (\/[^\s]+\.gguf)` stopped at the first space, so a
                // model at "/Users/x/My Models/g.gguf" captured only
                // "/Users/x/My" and never matched a known ModelEntry.
                // GGUF paths always end in `.gguf`, so match lazily up to
                // the LAST `.gguf` on the argument (the path can't contain
                // a literal `.gguf ` mid-string in practice). `.*?` is
                // lazy; anchoring on `\.gguf` keeps it from swallowing
                // trailing flags.
                mPattern = #"-m (\/.+?\.gguf)"#
                dropLen = 3
            } else {
                // MLX `--model` points at a directory (no extension). Match
                // everything up to the next ` --` flag boundary or end of
                // line, so spaces in the directory name are preserved.
                mPattern = #"--model (\/.+?)(?= --|$)"#
                dropLen = 8
            }
            guard let m = s.range(of: mPattern, options: .regularExpression) else { continue }
            var pathStr = String(s[m].dropFirst(dropLen))
            pathStr.trimEnd()

            let trimmed = s.drop(while: { $0 == " " })
            let pidStr = trimmed.prefix(while: { $0.isNumber })
            let pid: Int32 = Int32(pidStr) ?? 0

            var port = 0
            if let pm = s.range(of: #"--port (\d+)"#, options: .regularExpression) {
                port = Int(String(s[pm].split(separator: " ").last ?? "0")) ?? 0
            }
            var ctx = 0
            if let pm = s.range(of: #"--ctx-size (\d+)"#, options: .regularExpression) {
                ctx = Int(String(s[pm].split(separator: " ").last ?? "0")) ?? 0
            }
            externalStates[pathStr] = (pid, port, ctx)
        }
        return externalStates
    }

    // MARK: - Settings
    // ----------------------------------------------------------------------------
    //  Settings are persisted to `UserDefaults` under the bundle's domain
    //  (`local.llama-menubar`). The companion `llama` CLI shares the same
    //  domain via `defaults read local.llama-menubar ...`, so both tools
    //  see the same configuration.

    /// Load all settings from `UserDefaults`, applying defaults for any
    /// missing keys.
    func loadSettings() {
        let d = UserDefaults.standard
        // Models dir: default to ~/models if not set.
        settings.modelsDir = d.string(forKey: "modelsDir")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("models").path
        // Port: 0 means "not set" in UserDefaults, so apply our default.
        settings.defaultPort = d.integer(forKey: "defaultPort")
        if settings.defaultPort == 0 { settings.defaultPort = 8080 }
        // Same for ctx size.
        settings.defaultCtxSize = d.integer(forKey: "defaultCtxSize")
        if settings.defaultCtxSize == 0 { settings.defaultCtxSize = 4096 }
        // Backend binary paths: have sensible defaults for both Homebrew
        // and Python user installs.
        settings.llamaServerPath = d.string(forKey: "llamaServerPath")
            ?? "/opt/homebrew/bin/llama-server"
        settings.mlxServerPath = d.string(forKey: "mlxServerPath")
            ?? Self.discoverMLXServerPath()
        // Global extra args default to empty.
        settings.globalExtraArgs = d.string(forKey: "globalExtraArgs") ?? ""
        // Chat template override: empty = use built-in template.
        settings.chatTemplatePath = d.string(forKey: "chatTemplatePath") ?? ""

        // MTP toggle: off by default (MTP is a net loss on Metal).
        settings.enableMtp = d.bool(forKey: "enableMtp")

        // KV cache quantization.
        settings.kvCacheTypeK = d.string(forKey: "kvCacheTypeK") ?? "q8_0"
        settings.kvCacheTypeV = d.string(forKey: "kvCacheTypeV") ?? "q4_0"

        // Flash attention: on by default.
        settings.flashAttention = d.object(forKey: "flashAttention") as? Bool ?? true

        // Thinking: on by default (better for coding/tools).
        settings.thinkingEnabled = d.object(forKey: "thinkingEnabled") as? Bool ?? true

        // Reasoning suppression: on by default (Gemma 4 crashes OpenAI clients).
        settings.suppressReasoning = d.object(forKey: "suppressReasoning") as? Bool ?? true

        // Sampling defaults.
        let temp = d.double(forKey: "temperature")
        settings.temperature = temp == 0 ? 0.8 : temp
        let tp = d.double(forKey: "topP")
        settings.topP = tp == 0 ? 0.95 : tp
        settings.topK = d.integer(forKey: "topK") == 0 ? 20 : d.integer(forKey: "topK")
        let rp = d.double(forKey: "repeatPenalty")
        settings.repeatPenalty = rp == 0 ? 1.0 : rp
        settings.seed = d.integer(forKey: "seed")

        // Performance (llama-server only).
        settings.cpuThreads = d.integer(forKey: "cpuThreads")
        settings.batchSize = d.integer(forKey: "batchSize") == 0 ? 2048 : d.integer(forKey: "batchSize")
        settings.mlock = d.bool(forKey: "mlock")
        settings.noMmap = d.bool(forKey: "noMmap")

        // MLX-specific.
        settings.mlxMaxKvSize = d.integer(forKey: "mlxMaxKvSize")
    }

    /// Persist all settings to `UserDefaults`. Currently called by
    /// `SettingsView.onChange` handlers indirectly; `loadSettings` is the
    /// inverse.
    func saveSettings() {
        let d = UserDefaults.standard
        d.set(settings.modelsDir, forKey: "modelsDir")
        d.set(settings.defaultPort, forKey: "defaultPort")
        d.set(settings.defaultCtxSize, forKey: "defaultCtxSize")
        d.set(settings.llamaServerPath, forKey: "llamaServerPath")
        d.set(settings.mlxServerPath, forKey: "mlxServerPath")
        d.set(settings.globalExtraArgs, forKey: "globalExtraArgs")
        d.set(settings.chatTemplatePath, forKey: "chatTemplatePath")
        d.set(settings.enableMtp, forKey: "enableMtp")
        d.set(settings.kvCacheTypeK, forKey: "kvCacheTypeK")
        d.set(settings.kvCacheTypeV, forKey: "kvCacheTypeV")
        d.set(settings.flashAttention, forKey: "flashAttention")
        d.set(settings.thinkingEnabled, forKey: "thinkingEnabled")
        d.set(settings.suppressReasoning, forKey: "suppressReasoning")
        d.set(settings.temperature, forKey: "temperature")
        d.set(settings.topP, forKey: "topP")
        d.set(settings.topK, forKey: "topK")
        d.set(settings.repeatPenalty, forKey: "repeatPenalty")
        d.set(settings.seed, forKey: "seed")
        d.set(settings.cpuThreads, forKey: "cpuThreads")
        d.set(settings.batchSize, forKey: "batchSize")
        d.set(settings.mlock, forKey: "mlock")
        d.set(settings.noMmap, forKey: "noMmap")
        d.set(settings.mlxMaxKvSize, forKey: "mlxMaxKvSize")
    }
}

// MARK:   String extension
// -----------------------------------------------------------------------------
//  Small helper: trim trailing whitespace, including newlines. Used by
//  `syncWithRunningProcesses` to clean up MLX paths.

private extension String {
    /// Remove trailing spaces, tabs, newlines, and carriage returns.
    mutating func trimEnd() {
        while let last = self.last, last == " " || last == "\n" || last == "\r" {
            self.removeLast()
        }
    }
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
    /// MTP is a net loss on Apple Silicon Metal (11–92% slower depending
    /// on model size and draft ceiling). This toggle lets users opt in
    /// for experimentation. Off by default.
    /// See https://github.com/ggerganov/llama.cpp/issues/23752
    var enableMtp: Bool = false

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
