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
    @State private var manager = ServerManager()
    @State private var settingsHost = SettingsWindowHost()

    var body: some Scene {
        MenuBarExtra {
            MenuView(manager: manager, settingsHost: settingsHost)
        } label: {
            // MenuBarExtra always renders the label as a template image when
            // using Image(systemName:) or foregroundStyle — macOS strips colour.
            // Using Image(nsImage:) with isTemplate=false bypasses this: SwiftUI
            // passes the NSImage directly to NSStatusBarButton.image without
            // re-templating it, so our tint colour is preserved.
            let count = manager.models.filter { manager.state(for: $0).isRunning }.count
            Image(nsImage: menuBarIcon(runCount: count))
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


// MARK: - Menu bar icon helper
// -----------------------------------------------------------------------------
//  Returns a coloured, non-template NSImage for the status bar bolt icon.
//  isTemplate=false tells NSStatusBarButton not to re-render it monochrome.

private func menuBarIcon(runCount: Int) -> NSImage {
    let symbolName = runCount == 0 ? "bolt" : "bolt.fill"
    let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)

    guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else {
        let fallback = NSImage(systemSymbolName: "bolt", accessibilityDescription: nil)!
        fallback.isTemplate = true
        return fallback
    }

    if runCount == 0 {
        base.isTemplate = true   // monochrome, adapts to light/dark menu bar
        return base
    }

    let color: NSColor = runCount == 1 ? .systemGreen : .systemBlue
    let img = NSImage(size: base.size, flipped: false) { rect in
        base.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    img.isTemplate = false
    return img
}
