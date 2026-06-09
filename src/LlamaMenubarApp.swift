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
//    GGUF models (e.g. gemma-3 vision).
//  - Detects externally-launched server processes (e.g. started by the
//    companion `llama` CLI) by scanning `ps` output and reconciles state.
//  - Persists all settings via `UserDefaults` (same domain as the CLI so they
//    share configuration).
//  - Watches the models directory with a `DispatchSource` so newly added or
//    removed models appear/disappear from the menu live.
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
    func show(manager: ServerManager) {
        // If the window is already open and visible, just focus it.
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // Build a SwiftUI -> AppKit hosting controller for the SwiftUI view.
        let view = SettingsView(manager: manager)
        let hosting = NSHostingController(rootView: view)

        // Construct a basic titled window. We deliberately do NOT use
        // `.resizable` because we set a fixed content size and don't want
        // the user to be able to mess with it.
        let win = NSWindow(contentViewController: hosting)
        win.title = "LLM Switcher Settings"
        win.setContentSize(NSSize(width: 720, height: 540))
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

    /// Reserved for future per-model extra args. Currently unused — the
    /// global `AppSettings.globalExtraArgs` covers most use cases.
    var extraArgs: String = ""
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
    @State private var selected: Set<String> = []

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
                    Button("Load Selected (\(selected.count))") {
                        // Filter the model list to just the ones the user
                        // checked, then load each. (One process per model.)
                        let toLoad = manager.models.filter { selected.contains($0.id) }
                        for m in toLoad { manager.loadModel(m) }
                    }
                    .disabled(selected.isEmpty)
                    Spacer()
                    Button("Clear") { selected.removeAll() }
                        .disabled(selected.isEmpty)
                }
                .padding(.horizontal, 4)
            }

            Divider()

            // Global actions: unload everything, manually rescan.
            HStack {
                Button("⏹ Unload All") { manager.unloadAll() }
                    .disabled(!manager.anyRunning)
                Spacer()
                Button("↻ Refresh") { manager.refreshModels() }
            }
            .padding(.horizontal, 4)

            Divider()

            // Bottom status: green dot + "N on :ports".
            HStack {
                Circle()
                    .fill(manager.anyRunning ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(manager.summaryText)
                Spacer()
            }
            .padding(.horizontal, 4)
            .foregroundStyle(.secondary)

            Divider()

            // Settings — Cmd+, is the standard macOS settings shortcut.
            Button("⚙ Settings…") { settingsHost.show(manager: manager) }
                .keyboardShortcut(",")

            // Quit — first stops all servers cleanly, then terminates the
            // app process. Without the explicit terminate, the app would
            // keep running invisibly (because there's no main window).
            Button("Quit") {
                manager.unloadAll()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
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
        let isChecked = selected.contains(model.id) || state.isRunning

        return Toggle(isOn: Binding(
            get: { isChecked },
            set: { isOn in
                if isOn { selected.insert(model.id) } else { selected.remove(model.id) }
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
                // hollow gray dot if not.
                if state.isRunning {
                    Image(systemName: "circle.fill")
                        .foregroundColor(.green)
                        .imageScale(.small)
                    Text(":\(state.port)")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
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
struct SettingsView: View {
    /// The shared manager. `@Bindable` allows `$settings.foo` bindings.
    @Bindable var manager: ServerManager

    // Local @State mirrors of the manager's settings. We keep these as
    // local copies so the form can show unsaved-typed values; the
    // `.onChange` modifiers below push changes back into the manager.
    @State private var modelsDir: String
    @State private var defaultPort: String
    @State private var defaultCtxSize: String
    @State private var llamaServerPath: String
    @State private var mlxServerPath: String
    @State private var globalExtraArgs: String

    /// Initialize the local state from the manager's settings.
    /// SwiftUI's `@State` must be initialized in `init`, not the property
    /// declaration, which is why we override the default initializer.
    init(manager: ServerManager) {
        self.manager = manager
        _modelsDir = State(initialValue: manager.settings.modelsDir)
        _defaultPort = State(initialValue: "\(manager.settings.defaultPort)")
        _defaultCtxSize = State(initialValue: "\(manager.settings.defaultCtxSize)")
        _llamaServerPath = State(initialValue: manager.settings.llamaServerPath)
        _mlxServerPath = State(initialValue: manager.settings.mlxServerPath)
        _globalExtraArgs = State(initialValue: manager.settings.globalExtraArgs)
    }

    var body: some View {
        // A two-tab layout. SwiftUI's `TabView` is a `Picker` with a tab
        // style; macOS renders it as a tab bar at the top.
        TabView {
            globalPane.tabItem { Label("Global", systemImage: "gear") }
            modelsPane.tabItem { Label("Per-Model", systemImage: "cube") }
        }
        .padding()
        // Fixed window size — content is laid out by hand.
        .frame(width: 720, height: 540)
    }

    /// "Global" tab: shared defaults and binary paths.
    private var globalPane: some View {
        Form {
            Section("Server Defaults") {
                // Models directory: editable text + Browse button.
                HStack {
                    Text("Models Directory:")
                    TextField("~/models", text: $modelsDir)
                        .frame(width: 350)
                    Button("Browse…") {
                        // NSOpenPanel is AppKit's file/folder picker. We
                        // configure it to allow only directories and a
                        // single selection, with the current value as the
                        // starting point.
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.directoryURL = URL(fileURLWithPath: modelsDir)
                        if panel.runModal() == .OK, let url = panel.url {
                            modelsDir = url.path
                            // Push the change into the manager and refresh.
                            manager.settings.modelsDir = url.path
                            manager.refreshModels()
                            // Restart the directory watcher on the new path.
                            manager.startWatching()
                        }
                    }
                }
                // Helper text below the field.
                Text("Scanned recursively. GGUF files in any subdir, MLX dirs (containing .safetensors).")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Default port: parsed as Int on every change.
                HStack {
                    Text("Default Port:")
                    TextField("8080", text: $defaultPort)
                        .frame(width: 80)
                    Text("(used if model has no specific port)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }

                // Default context size in tokens.
                HStack {
                    Text("Default Ctx Size:")
                    TextField("4096", text: $defaultCtxSize)
                        .frame(width: 100)
                    Text("tokens")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }

                // Global extra args (parsed by `parseArgs` into argv).
                HStack {
                    Text("Global Extra Args:")
                    TextField("--no-mmap", text: $globalExtraArgs)
                        .frame(width: 350)
                }
            }
            // Backend binary paths.
            Section("Backends") {
                HStack {
                    Text("llama-server:")
                    TextField("/opt/homebrew/bin/llama-server", text: $llamaServerPath)
                        .frame(width: 380)
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
                HStack {
                    Text("mlx_lm.server:")
                    TextField("mlx_lm.server", text: $mlxServerPath)
                        .frame(width: 380)
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
        // Push every keystroke into the manager (and into UserDefaults via
        // the manager's own setters). `.onChange(of:_:)` is the modern form
        // (macOS 14+); it fires with both the old and new value.
        .onChange(of: modelsDir) { _, newValue in
            manager.settings.modelsDir = newValue
            manager.refreshModels()
            manager.startWatching()
        }
        .onChange(of: defaultPort) { _, newValue in
            // Validate: must be a positive 16-bit integer.
            if let p = Int(newValue), p > 0, p < 65536 {
                manager.settings.defaultPort = p
            }
        }
        .onChange(of: defaultCtxSize) { _, newValue in
            if let c = Int(newValue), c > 0 {
                manager.settings.defaultCtxSize = c
            }
        }
        .onChange(of: llamaServerPath) { _, newValue in
            manager.settings.llamaServerPath = newValue
        }
        .onChange(of: mlxServerPath) { _, newValue in
            manager.settings.mlxServerPath = newValue
        }
        .onChange(of: globalExtraArgs) { _, newValue in
            manager.settings.globalExtraArgs = newValue
        }
    }

    /// "Per-Model" tab: one row per discovered model with editable port,
    /// context size, and a Load/Unload button.
    private var modelsPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Per-Model Settings")
                    .font(.headline)
                Spacer()
                Text("Edits apply on next load")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if manager.models.isEmpty {
                Text("No models found in \(manager.settings.modelsDir)")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                // Column header row.
                HStack {
                    Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Backend").frame(width: 60, alignment: .leading)
                    Text("Port").frame(width: 70, alignment: .leading)
                    Text("Ctx").frame(width: 80, alignment: .leading)
                    Text("Status").frame(width: 80, alignment: .leading)
                    Text("").frame(width: 130, alignment: .trailing)
                }
                .font(.caption)
                .foregroundColor(.secondary)
                Divider()
                // Scrollable list of rows.
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(manager.models) { model in
                            perModelRow(for: model)
                        }
                    }
                }
            }
        }
    }

    /// One row in the per-model list. Provides two-way bindings for
    /// `port` and `ctx` (parsed as `Int`; invalid input is silently
    /// ignored). A trailing Load/Unload button toggles the model.
    private func perModelRow(for model: ModelEntry) -> some View {
        let state = manager.state(for: model)

        // Two-way binding for the port field. On every keystroke, we try
        // to parse to Int; if it fails, we leave the stored value alone
        // (so the field re-syncs next time the view re-evaluates).
        let portBinding = Binding<String>(
            get: { "\(manager.perModelPort(for: model))" },
            set: { newVal in
                if let p = Int(newVal), p >= 0, p < 65536 {
                    manager.setPerModelPort(p, for: model)
                }
            }
        )
        // Same idea for the context size field.
        let ctxBinding = Binding<String>(
            get: { "\(manager.perModelCtxSize(for: model))" },
            set: { newVal in
                if let c = Int(newVal), c > 0 {
                    manager.setPerModelCtxSize(c, for: model)
                }
            }
        )
        return HStack {
            // Left: model name with backend icon.
            HStack(spacing: 4) {
                Image(systemName: model.backend.sfSymbol)
                    .foregroundColor(model.backend == .mlx ? .purple : .blue)
                    .imageScale(.small)
                Text(model.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Backend label.
            Text(model.backend.rawValue)
                .font(.caption)
                .frame(width: 60, alignment: .leading)

            // Port editor.
            TextField("", text: portBinding)
                .frame(width: 70)
                .textFieldStyle(.roundedBorder)
            // Ctx editor.
            TextField("", text: ctxBinding)
                .frame(width: 80)
                .textFieldStyle(.roundedBorder)

            // Status column: green/gray dot + port if running.
            HStack(spacing: 4) {
                Image(systemName: state.isRunning ? "circle.fill" : "circle")
                    .foregroundColor(state.isRunning ? .green : .secondary)
                    .imageScale(.small)
                if state.isRunning {
                    Text(":\(state.port)")
                        .font(.caption.monospaced())
                }
            }
            .frame(width: 80, alignment: .leading)

            // Action button.
            HStack {
                if state.isRunning {
                    Button("Unload") { manager.unloadModel(model) }
                        .controlSize(.small)
                } else {
                    Button("Load") { manager.loadModel(model) }
                        .controlSize(.small)
                }
            }
            .frame(width: 130, alignment: .trailing)
        }
        .padding(.vertical, 2)
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

    /// Persisted global settings (models dir, port, ctx, etc.).
    var settings = AppSettings()

    /// Reserved for future use; currently unused. Was intended to scroll
    /// the per-model settings pane to a specific model.
    var pendingCtxEdit: URL? = nil

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
        loadSettings()
        refreshModels()
        startWatching()
        startSyncTimer()
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

    // MARK:   File-system watcher
    //
    //  We use `DispatchSource.makeFileSystemObjectSource` to watch the
    //  PARENT of the models directory. Watching the directory itself
    //  doesn't fire on changes to its subdirectories, so we watch one
    //  level up and re-scan on every change.

    /// The file descriptor for the directory we're watching.
    private var directoryFD: Int32 = -1

    /// The dispatch source for the file-system events.
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
    }

    // MARK: - State queries
    // ----------------------------------------------------------------------------
    //  Computed properties used by the UI. Kept simple and synchronous.

    /// Are any models currently loaded? Used to enable/disable buttons and
    /// to color the menu bar icon.
    var anyRunning: Bool {
        !modelStates.values.filter { $0.isRunning }.isEmpty
    }

    /// Short text shown next to the menu bar icon. Single-model case shows
    /// the name; multi-model case shows a count.
    var statusText: String {
        let running = modelStates.filter { $0.value.isRunning }
        if running.isEmpty { return "" }
        if running.count == 1,
           let entry = models.first(where: { modelStates[$0.id]?.isRunning == true }) {
            return entry.name
        }
        return "\(running.count) models"
    }

    /// Longer text shown at the bottom of the menu, e.g. "2 on :8080, 8081".
    var summaryText: String {
        let running = modelStates.filter { $0.value.isRunning }
        if running.isEmpty { return "All stopped" }
        let ports = running.values.map { "\($0.port)" }.sorted().joined(separator: ", ")
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
    private func perModelKey(_ suffix: String, model: ModelEntry) -> String {
        // The id itself is already unique (it's the path), but using the
        // hash keeps the key short. Note: a hash collision would cause
        // two models to share settings, but in practice path hashes are
        // unique enough for our purposes.
        "model.\(model.id.hashValue).\(suffix)"
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
        // After refreshing, reconcile our state with what's actually
        // running on the system. This catches externally-launched models
        // and removes entries for processes that have died.
        syncWithRunningProcesses()
    }

    /// Recursive directory walker. For each child of `dir`:
    ///   - Hidden files / directories: skip.
    ///   - Subdirectory: if it looks like an MLX model, add it; otherwise
    ///     recurse into it.
    ///   - `.gguf` file: add it as a GGUF model.
    private func scanDirectory(_ dir: URL, into entries: inout [ModelEntry], baseDir: URL) {
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
                    scanDirectory(url, into: &entries, baseDir: baseDir)
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
    ///   - `modernbert-embed-*.gguf` — embedding models used by the
    ///                                 gbrain system. Not a chat model.
    private func ggufEntry(at url: URL, baseDir: URL) -> ModelEntry? {
        let lname = url.lastPathComponent.lowercased()
        if lname.hasPrefix("mmproj-") { return nil }
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

        // Pick a port: prefer the per-model saved port; otherwise the
        // first available port starting from `defaultPort`.
        let preferredPort = perModelPort(for: model)
        let port = preferredPort > 0 ? preferredPort : nextAvailablePort()
        let ctx = perModelCtxSize(for: model)

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
            // Context size (only set if explicitly configured).
            if ctx > 0 {
                args += ["--ctx-size", "\(ctx)"]
            }
        case .mlx:
            // MLX: invoke mlx_lm.server with --model <dir>.
            executable = settings.mlxServerPath
            args += ["--model", model.path.path]
        }

        // Bind to localhost (security + convenience) and the chosen port.
        args += ["--host", "127.0.0.1", "--port", "\(port)"]

        // Append any global extra args (e.g. `--no-mmap --threads 8`).
        // We use a small parser to handle quoted args.
        if !settings.globalExtraArgs.isEmpty {
            args += parseArgs(settings.globalExtraArgs)
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
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                if var s = self?.modelStates[modelId] {
                    s.isRunning = false
                    s.pid = nil
                    self?.modelStates[modelId] = s
                }
                self?.processes[modelId] = nil
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
        let devnull = FileHandle(forWritingAtPath: "/dev/null")
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
            modelStates[model.id] = s
        } catch {
            // Spawn failed (e.g. binary not found). We don't show an alert
            // here — the menu icon stays gray and the user can check the
            // log via the CLI. The CLI also shows errors in its output.
        }
    }

    /// Stop the server for a single model. Sends SIGTERM to the process
    /// (and falls back to SIGKILL after a short wait). Also handles
    /// externally-launched processes by killing them by PID.
    func unloadModel(_ model: ModelEntry) {
        // 1. If we own the process (started via loadModel), terminate it
        //    cleanly. `Process.terminate()` sends SIGTERM.
        if let p = processes[model.id] {
            p.terminate()
        }
        processes[model.id] = nil

        // 2. If we have a recorded PID (including from externally-launched
        //    processes detected by `syncWithRunningProcesses`), send
        //    SIGTERM via `kill(2)` to ensure it actually dies.
        if let s = modelStates[model.id], let pid = s.pid {
            // `kill(pid, SIGTERM)` returns -1 on error (e.g. process
            // already dead). We ignore the result.
            kill(pid, SIGTERM)
        }

        // 3. Clear our local state.
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
    /// The `ps` scan and state merge run synchronously on the calling
    /// thread. This is intentional: `unloadAll` iterates over
    /// `modelStates` immediately afterward to send SIGTERM, so the
    /// external-process PIDs must be present *before* the loop runs.
    /// Blocking briefly here is acceptable because this is a
    /// user-initiated action (button click / app quit), not a timer.
    func unloadAll() {
        // Reconcile with `ps` synchronously so any external processes
        // get recorded in `modelStates` before we iterate. Blocking
        // here is acceptable because this is a user-initiated action.
        let externalStates = collectExternalStatesFromPS()
        mergeExternalStates(externalStates)

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
                if let pid = state.pid {
                    kill(pid, SIGTERM)
                }
            }
        }
    }

    /// Find the smallest unused port starting at `defaultPort`.
    /// Used when no per-model port has been set.
    private func nextAvailablePort() -> Int {
        let usedPorts = Set(modelStates.values.compactMap { $0.isRunning ? $0.port : nil })
        var port = settings.defaultPort
        while usedPorts.contains(port) {
            port += 1
        }
        return port
    }

    /// For a GGUF model, find a matching `mmproj-*.gguf` file in the same
    /// directory. The match is by base name with quantization stripped.
    /// E.g. `gemma-4-12B-it-Q4_K_M.gguf` matches `mmproj-gemma-4-12B-it-Q8_0.gguf`.
    ///
    /// Returns the first alphabetically-sorted match, or nil if none.
    private func findMmproj(for modelURL: URL) -> URL? {
        let dir = modelURL.deletingLastPathComponent()
        let base = modelURL.deletingPathExtension().lastPathComponent
        // Strip common quantization suffixes. We only strip suffixes we
        // commonly see; if a model uses a different one, mmproj simply
        // won't be auto-paired (no harm done).
        let stripped = base
            .replacingOccurrences(of: "-Q4_K_M", with: "")
            .replacingOccurrences(of: "-Q4_K_S", with: "")
            .replacingOccurrences(of: "-Q5_K_M", with: "")
            .replacingOccurrences(of: "-Q5_K_S", with: "")
            .replacingOccurrences(of: "-Q6_K", with: "")
            .replacingOccurrences(of: "-Q8_0", with: "")

        // Look for files named `mmproj-<stripped>*` (any quantization).
        let pattern = "mmproj-\(stripped)"
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return nil }
        let matches = entries.filter {
            $0.lastPathComponent.hasPrefix(pattern) && $0.pathExtension == "gguf"
        }
        return matches.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
    }

    /// Split a free-form "extra args" string into argv-style tokens.
    /// Honors single and double quotes so `--prompt "hello world"` parses
    /// as two tokens: `--prompt` and `hello world`.
    private func parseArgs(_ s: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inQuote = false
        for ch in s {
            if ch == "\"" || ch == "'" {
                inQuote.toggle()
            } else if ch == " " && !inQuote {
                if !current.isEmpty { args.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
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
                var cleared = s
                cleared.isRunning = false
                cleared.pid = nil
                modelStates[id] = cleared
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
        // Discard stderr (some `ps` options emit warnings; we don't care).
        task.standardError = Pipe()
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
                mPattern = #"-m (\/[^\s]+\.gguf)"#
                dropLen = 3
            } else {
                mPattern = #"--model (\/[^\s]+)"#
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
            ?? (NSHomeDirectory() + "/Library/Python/3.14/bin/mlx_lm.server")
        // Global extra args default to empty.
        settings.globalExtraArgs = d.string(forKey: "globalExtraArgs") ?? ""
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
}
