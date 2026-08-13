// =============================================================================
//  ServerManager.swift
//  LM Switcher — the brain: model discovery, process lifecycle, persistence
// =============================================================================
//  Extracted from the former single-file LlamaMenubarApp.swift (audit A-1).
// =============================================================================

import SwiftUI
import AppKit
import Darwin
import CryptoKit
import UserNotifications


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

    // MARK:   Threading invariant (A3)
    // -----------------------------------------------------------------------------
    //  `modelStates`, `processes`, `selected`, `models`, `recentAgentEvents`,
    //  and `switchingTo` are plain value/dictionary types. `@Observable` does
    //  NOT make them thread-safe — concurrent read/modify from a background
    //  queue while SwiftUI reads them on main is a data race.
    //
    //  This class's invariant: ALL mutation of these properties happens on the
    //  main thread. Background work (the `ps` spawn, the `Thread.sleep` poll,
    //  the `/slots` fetch) runs on `syncQueue` and hops back to main
    //  (`DispatchQueue.main.async`/`.sync`) before touching any state.
    //
    //  A3: rather than annotate the class `@MainActor` (which compiles but
    //  whose interaction with the existing `DispatchQueue.main.sync` hops can
    //  mask races via implicit runtime hops), we enforce the invariant with a
    //  debug-build assertion at every mutation entry point. This fails fast
    //  in development if a future change calls a mutator off-main, and
    //  compiles to nothing in release.
    @inline(__always)
    private func assertMain(_ ctx: String = #function) {
        #if DEBUG
        // dispatchPrecondition traps if the current queue is not main,
        // catching any future off-main mutation at development time. In
        // release builds the whole body is compiled out.
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        #endif
        _ = ctx   // referenced so #function is always used (avoids unused-warning in release)
    }

    // MARK:   Public state

    /// All models found on disk. Refreshed by `refreshModels()`.
    var models: [ModelEntry] = []
    /// Set of model IDs the user has ticked for loading.
    var selected: Set<String> = []

    /// Persisted global settings (models dir, port, ctx, etc.).
    var settings = AppSettings()

    /// Bumped to force SwiftUI view refresh for per-model override toggles.
    var refreshTrigger: Int = 0

    /// Rolling history of MCP agent actions, newest last, capped at 20.
    /// Populated by `consumeAgentEvents()`; read by the menu's Agent
    /// Activity view (redesign Phase 5).
    var recentAgentEvents: [AgentEvent] = []

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
        let lockPath = NSTemporaryDirectory() + "lm-switcher.lock"
        // A6 fix: O_NOFOLLOW refuses to open a symlink at the lock path,
        // closing a redirect vector where a local attacker who can write
        // the per-user temp dir points the lock file at an attacker-chosen
        // target. Mode 0o600 keeps the lock file owner-only (it never holds
        // sensitive data, but restrictive defaults are cheap). O_CREAT|O_RDWR
        // creates it if absent and opens read/write for the flock.
        let fd = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
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

    /// Pending debounced refresh work item (M-7). The watcher observes the
    /// PARENT of the models dir (a DispatchSource limitation), so unrelated
    /// changes anywhere in the parent fire events. Rather than re-scan on
    /// every event, we coalesce a burst into a single refresh ~300ms after
    /// the last event.
    @ObservationIgnored
    private var pendingRefresh: DispatchWorkItem?

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

        // On any event, schedule a debounced re-scan (M-7). The parent-dir
        // watch fires on unrelated changes too, so we cancel any pending
        // refresh and reschedule — a burst of events collapses into one
        // `refreshModels()` ~300ms after the last event. SwiftUI re-renders
        // views observing `manager.models` automatically.
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.pendingRefresh?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.refreshModels()
            }
            self.pendingRefresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
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
        pendingRefresh?.cancel()
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

            // Skip symlinks. A self-referential link (e.g. the common
            // `models -> /Users/x/AI/models` inside the models dir) would
            // otherwise (a) feed the recursion a duplicate subtree and
            // (b) produce ModelEntry ids via the LINK path
            // (".../models/models/gguf/x.gguf") that never match the real
            // path llama-server reports in `ps` (".../models/gguf/x.gguf"),
            // so running models would never show as loaded. The depth cap
            // (M-6) stops infinite recursion, but skipping symlinks is the
            // correct fix: the real files are always reachable via the
            // non-symlink path during the same scan.
            let vals = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if vals?.isSymbolicLink == true { continue }

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
    ///   - `dflash-*.gguf`           — DFlash block-diffusion drafter
    ///                                 files (e.g. Muse Glimmer's
    ///                                 dflash-kquant.gguf). Not standalone
    ///                                 models; auto-attached via
    ///                                 --spec-type draft-dflash.
    private func ggufEntry(at url: URL, baseDir: URL) -> ModelEntry? {
        let lname = url.lastPathComponent.lowercased()
        if lname.hasPrefix("mmproj-") { return nil }
        if lname.hasPrefix("mtp-") { return nil }
        if lname.hasPrefix("modernbert-embed-") { return nil }
        if lname.hasPrefix("dflash-") { return nil }
        // Exclude MTP assistant heads (arch *-assistant) that are not
        // standalone models. Quick GGUF header read to check architecture.
        if let arch = readGgufArchitecture(url), arch.hasSuffix("-assistant") {
            return nil
        }
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
        assertMain()   // A3: all state mutation must happen on main


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
        let effDflash = pm("enableDflash", global: settings.enableDflash, for: model)
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
            // MTP: some models ship MTP built into the GGUF (infix -mtp- in name),
            // while others carry a separate mtp-*.gguf companion. If a companion
            // exists, pass --spec-draft-model explicitly.

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

            // Slots endpoint (local-only) — lets the TTL auto-unload poll
            // detect activity. Harmless when TTL is off.
            args += ["--slots"]

            // Reasoning suppression — Gemma 4 emits reasoning_content that
            // breaks OpenAI-compatible clients (opencode, pi, OpenClaw).
            // See docs/GEMMA4_LOADING_DETAILS.md §3.2.
            if pm("suppressReasoning", global: settings.suppressReasoning, for: model) {
                args += ["--reasoning", "off", "--reasoning-format", "none"]
            }

            // Thinking mode — when enabled, model generates reasoning tokens
            // before responding. Better for coding/tools, worse for latency.
            if !effThinking {
                args += ["--chat-template-kwargs", "{\"enable_thinking\":false}"]
            }

            // MTP (Multi-Token Prediction): ON by default. Check if the model
            // actually supports MTP (companion mtp-*.gguf or built-in via
            // filename infix -MTP-). If not, silently skip — no-op.
            var specTypeAttached = false
            if effMtp {
                // Detect MTP support: companion file or built-in infix
                let hasCompanion = findMtpDraftModel(for: model.path) != nil
                let nameContainsMtp = model.name.range(of: "-MTP-", options: .caseInsensitive) != nil
                if hasCompanion || nameContainsMtp {
                    specTypeAttached = true
                    args += ["--spec-type", "draft-mtp"]
                    if let draft = findMtpDraftModel(for: model.path) {
                        args += ["--spec-draft-model", draft.path]
                    }
                }
            }

            // DFlash (block-diffusion speculative decoding): ON by default.
            // Muse Glimmer ships dflash-kquant.gguf as a companion drafter.
            // Attach --spec-type draft-dflash when one exists and no MTP
            // head was attached (the two speculative methods are exclusive).
            var dflashAttached = false
            if effDflash && !specTypeAttached,
               let draft = findDflashDraftModel(for: model.path) {
                dflashAttached = true
                args += ["--spec-type", "draft-dflash"]
                args += ["--spec-draft-model", draft.path]
                args += ["--spec-draft-n-max", "15"]
                // Adaptive disengage: when greedy acceptance drops below
                // 0.4 (Muse's reasoning phase on open-ended prompts), the
                // drafter stops proposing — measured net loss (7.5 t/s)
                // vs baseline (10 t/s) without this. Structured/agentic
                // prompts keep 60-75% acceptance and full speed.
                args += ["--spec-draft-p-min", "0.4"]
            }

            // Sampling defaults — shared with MLX.
            args += ["--temp", "\(effTemp)"]
            // top-p/top-k/repeat-penalty skew the distribution the DFlash
            // drafter verifies against, collapsing block acceptance
            // (measured on Muse Glimmer: 63% -> 13%, 25 t/s -> 7 t/s).
            // Omit them while a DFlash drafter is attached; temperature
            // stays user-controlled.
            if !dflashAttached {
                args += ["--top-p", "\(effTopP)",
                         "--top-k", "\(effTopK)",
                         "--repeat-penalty", "\(effRepeatPenalty)"]
            }
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
        // A4 fix: strip any `--host` the user supplied in extra args. The
        // app deliberately binds to 127.0.0.1 (loopback) so the unauthenticated
        // OpenAI-compatible endpoint is NOT exposed on the LAN. Since
        // llama-server/mlx honor the LAST `--host`, appending a user-supplied
        // `--host 0.0.0.0` AFTER our loopback binding would silently rebind
        // the server to all interfaces — a real security footgun for a
        // copy-pasted settings string. We drop `--host` (and its value) from
        // extras so the loopback binding always wins. Users who genuinely
        // want LAN exposure can run the CLI directly with explicit flags.
        // Also strip `--no-mmap` when the toggle already handles it.
        var cleanExtra = stripHostFlag(from: effExtraArgs)
        if settings.noMmap && cleanExtra.contains("--no-mmap") {
            cleanExtra = cleanExtra.replacingOccurrences(of: "--no-mmap", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        if !cleanExtra.isEmpty {
            args += parseArgs(cleanExtra)
        }

        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args

        // Pre-flight: check the backend binary exists BEFORE attempting to
        // launch, rather than parsing Process.run()'s thrown NSError text
        // (whose exact wording/domain isn't something we control or should
        // depend on). This is also the one case worth a specific, actionable
        // message instead of the generic catch below — "file not found" is
        // meaningless to someone who's never installed llama.cpp; the fix is
        // one copy-pasteable command away.
        if !FileManager.default.isExecutableFile(atPath: executable) {
            let installHint = model.backend == .gguf
                ? "brew install llama.cpp"
                : "pip install mlx-lm"
            var s = modelStates[model.id] ?? ModelState()
            s.isRunning = false
            s.pid = nil
            s.lastError = "\(model.backend.rawValue) engine not found at \(executable) — install with: \(installHint), or fix the path in Settings → Global → Backends."
            modelStates[model.id] = s
            NSSound.beep()
            return
        }

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
            // Keep `selected` honest: a running model is checked in the menu,
            // and "Unload Selected" reads `selected ∩ running`. Insert here so
            // the checkbox truthfully reflects set membership.
            selected.insert(model.id)
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
        assertMain()   // A3: all state mutation must happen on main
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
        // No longer running → uncheck in the menu.
        selected.remove(model.id)
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
        assertMain()   // A3: all state mutation must happen on main
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
        // Everything stopped → clear the checked set.
        selected.removeAll()
    }

    /// Number of models currently running. Used by the UI to decide whether
    /// to offer selectable unloading (only meaningful with 2+ loaded).
    var runningCount: Int {
        modelStates.values.filter { $0.isRunning }.count
    }

    /// Unload a specific set of models by ID. Only the RUNNING models in the
    /// set are touched; selected-but-not-running IDs are ignored. Used by the
    /// "Unload Selected" action so the user can stop a chosen subset when
    /// several models are loaded at once (vs. the all-or-one alternatives).
    /// IDs that were unloaded are also removed from `selected` so the UI's
    /// checkboxes reflect the new state.
    func unloadSelected(_ ids: Set<String>) {
        assertMain()   // A3: all state mutation must happen on main
        for id in ids {
            guard state(forID: id).isRunning else { continue }
            if let m = models.first(where: { $0.id == id }) {
                unloadModel(m)
            } else if let s = modelStates[id], let pid = s.pid {
                // Running but no matching ModelEntry (file moved/deleted) —
                // kill by PID and clear state (same as unloadAll's else-branch).
                kill(pid, SIGTERM)
                var ns = s
                ns.isRunning = false
                ns.pid = nil
                modelStates[id] = ns
            }
            selected.remove(id)
        }
    }

    /// Look up runtime state by raw model ID (the `selected` set stores IDs,
    /// not `ModelEntry` values, so this avoids a models-array search when we
    /// only have the ID).
    private func state(forID id: String) -> ModelState {
        modelStates[id] ?? ModelState()
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
        // new model gets a different one automatically. Runs on main (it
        // mutates @Observable state).
        loadModel(model)

        // Capture the chosen port now (on main) so the background poll never
        // has to read `modelStates` for it.
        let targetPort = modelStates[model.id]?.port ?? 0

        // Step 2: poll for readiness OFF the main thread. The previous
        // implementation ran this `Thread.sleep` poll loop (up to 5s) on the
        // calling thread — which is main, since `switchModel` is invoked from
        // a SwiftUI button — freezing the entire menu bar for the duration of
        // the switch. Run the poll on the shared serial `syncQueue` (the same
        // queue the `ps` reconciler uses, so the two can never overlap and
        // race on the shared dictionaries) and hop the final mutation back to
        // main.
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            let deadline = Date().addingTimeInterval(5.0)
            var isReady = false
            while Date() < deadline {
                // Snapshot the PID on main each iteration (the dictionaries are
                // main-thread state). Cheap, and keeps the heavy waiting off main.
                let pid: Int32? = DispatchQueue.main.sync {
                    let s = self.modelStates[model.id]
                    return (s?.isRunning == true) ? s?.pid : nil
                }
                guard let livePid = pid else {
                    break  // process died → loadModel already recorded the error
                }
                if kill(livePid, 0) == 0 && targetPort > 0 && !Self.portIsFree(targetPort) {
                    // Process alive AND port is bound (not free) → ready.
                    isReady = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.25)
            }

            DispatchQueue.main.async {
                if isReady {
                    // Step 3: swap complete — unload old models.
                    for entry in oldRunning {
                        self.unloadModel(entry.model)
                    }
                } else {
                    // Step 4: rollback — new model failed, unload it.
                    self.unloadModel(model)
                }
                self.switchingTo = nil
            }
        }
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

    /// Read the architecture string from a GGUF file header.
    /// Reads only the first ~8 KB which contains all metadata KV pairs.
    /// Returns nil on any error (not a valid GGUF, file not found, etc.).
    /// GGUF type codes: 0=uint8, 1=int8, 2=uint16, 3=int16, 4=uint32, 5=int32,
    /// 6=float32, 7=bool, 8=string, 9=array, 10=uint64, 11=int64, 12=float64,
    /// 13=float16, 14=bfloat16.
    private func readGgufArchitecture(_ url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { fh.closeFile() }
        let data = fh.readData(ofLength: 8192)
        guard data.count >= 24 else { return nil }
        let bytes = [UInt8](data)
        // Verify GGUF magic
        guard bytes[0] == 0x47, bytes[1] == 0x47, bytes[2] == 0x55, bytes[3] == 0x46 else { return nil }
        // Read GGUF version (uint32 little-endian at offset 4)
        let version = UInt32(bytes[4]) | (UInt32(bytes[5]) << 8) | (UInt32(bytes[6]) << 16) | (UInt32(bytes[7]) << 24)
        // Read kv_count — uint64 at offset 16
        let kvCount: UInt64 = UInt64(bytes[16]) | (UInt64(bytes[17]) << 8) | (UInt64(bytes[18]) << 16) | (UInt64(bytes[19]) << 24) |
                              (UInt64(bytes[20]) << 32) | (UInt64(bytes[21]) << 40) | (UInt64(bytes[22]) << 48) | (UInt64(bytes[23]) << 56)
        // Start of KV pairs: skip magic(4) + version(4) + tensor_count(8) + kv_count(8) = 24
        var offset = 24
        for _ in 0..<min(Int(kvCount), 200) {
            guard offset + 4 < data.count else { return nil }
            // Key length: uint64 for v3+, uint32 for v1/v2
            let keyLen: Int
            if version >= 3 {
                guard offset + 8 <= data.count else { return nil }
                keyLen = Int(bytes[offset]) | (Int(bytes[offset+1]) << 8) | (Int(bytes[offset+2]) << 16) | (Int(bytes[offset+3]) << 24) |
                        (Int(bytes[offset+4]) << 32) | (Int(bytes[offset+5]) << 40) | (Int(bytes[offset+6]) << 48) | (Int(bytes[offset+7]) << 56)
                offset += 8
            } else {
                keyLen = Int(bytes[offset]) | (Int(bytes[offset+1]) << 8) | (Int(bytes[offset+2]) << 16) | (Int(bytes[offset+3]) << 24)
                offset += 4
            }
            guard offset + keyLen + 4 <= data.count else { return nil }
            let key = String(data: data[offset..<offset + keyLen], encoding: .utf8) ?? ""
            offset += keyLen
            // Value type (uint32)
            let valType = UInt32(bytes[offset]) | (UInt32(bytes[offset+1]) << 8) | (UInt32(bytes[offset+2]) << 16) | (UInt32(bytes[offset+3]) << 24)
            offset += 4
            if key == "general.architecture" && valType == 8 {
                // String value: read length + content
                let strLen: Int
                if version >= 3 {
                    guard offset + 8 <= data.count else { return nil }
                    strLen = Int(bytes[offset]) | (Int(bytes[offset+1]) << 8) | (Int(bytes[offset+2]) << 16) | (Int(bytes[offset+3]) << 24) |
                            (Int(bytes[offset+4]) << 32) | (Int(bytes[offset+5]) << 40) | (Int(bytes[offset+6]) << 48) | (Int(bytes[offset+7]) << 56)
                    offset += 8
                } else {
                    guard offset + 4 <= data.count else { return nil }
                    strLen = Int(bytes[offset]) | (Int(bytes[offset+1]) << 8) | (Int(bytes[offset+2]) << 16) | (Int(bytes[offset+3]) << 24)
                    offset += 4
                }
                guard offset + strLen <= data.count else { return nil }
                return String(data: data[offset..<offset + strLen], encoding: .utf8)
            } else {
                // Skip value by type
                if valType == 8 { // string
                    let strLen: Int
                    if version >= 3 {
                        guard offset + 8 <= data.count else { return nil }
                        strLen = Int(bytes[offset]) | (Int(bytes[offset+1]) << 8) | (Int(bytes[offset+2]) << 16) | (Int(bytes[offset+3]) << 24) |
                                (Int(bytes[offset+4]) << 32) | (Int(bytes[offset+5]) << 40) | (Int(bytes[offset+6]) << 48) | (Int(bytes[offset+7]) << 56)
                        offset += 8
                    } else {
                        guard offset + 4 <= data.count else { return nil }
                        strLen = Int(bytes[offset]) | (Int(bytes[offset+1]) << 8) | (Int(bytes[offset+2]) << 16) | (Int(bytes[offset+3]) << 24)
                        offset += 4
                    }
                    offset += strLen
                } else if valType == 0 || valType == 1 || valType == 7 { offset += 1 } // uint8, int8, bool
                else if valType == 2 || valType == 3 { offset += 2 } // uint16, int16
                else if valType == 4 || valType == 5 || valType == 6 || valType == 13 || valType == 14 { offset += 4 } // uint32, int32, float32, float16, bfloat16
                else if valType == 10 || valType == 11 || valType == 12 { offset += 8 } // uint64, int64, float64
                else { return nil } // array (9) or unknown
            }
        }
        return nil
    }

    /// Find a matching `mmproj-*.gguf` vision projection file for a model.
    private func findMmproj(for modelURL: URL) -> URL? {
        findCompanion(for: modelURL, prefix: "mmproj")
    }

    /// Find a matching `mtp-*.gguf` draft model file for MTP speculation.
    /// Checks both the model's own directory and a `MTP/` subdirectory
    /// (HuggingFace convention). Returns nil if none found — the model
    /// may have MTP built into the GGUF itself (infix -mtp- in name).
    private func findMtpDraftModel(for modelURL: URL) -> URL? {
        let dir = modelURL.deletingLastPathComponent()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return nil }
        // Step 1: look for mtp-*.gguf in the same directory
        if let match = entries.filter({
            $0.lastPathComponent.hasPrefix("mtp-") && $0.pathExtension == "gguf"
        }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first {
            return match
        }
        // Step 2: check MTP/ subdirectory (HuggingFace convention)
        let mtpDir = dir.appendingPathComponent("MTP", isDirectory: true)
        guard let mtpEntries = try? fm.contentsOfDirectory(
            at: mtpDir, includingPropertiesForKeys: nil
        ) else { return nil }
        return mtpEntries.filter {
            $0.pathExtension == "gguf"
        }.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first
    }

    /// Find a matching `dflash-*.gguf` DFlash drafter for a model.
    /// Same-directory companion lookup (e.g. Muse Glimmer's
    /// dflash-kquant.gguf next to the main model file).
    private func findDflashDraftModel(for modelURL: URL) -> URL? {
        let dir = modelURL.deletingLastPathComponent()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return nil }
        return entries.filter {
            $0.lastPathComponent.hasPrefix("dflash-") && $0.pathExtension == "gguf"
        }.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first
    }



    /// Split a free-form "extra args" string into argv-style tokens.
    /// Honors single and double quotes so `--prompt "hello world"` parses
    /// as two tokens: `--prompt` and `hello world`.
    private func parseArgs(_ s: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quoteChar: Character? = nil   // A5 fix: track which quote is open
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
            } else if (ch == "\"" || ch == "'") && quoteChar == nil {
                // Opening a quote.
                quoteChar = ch
            } else if ch == quoteChar {
                // Closing the SAME quote char that opened it. This fixes the
                // bug where `--prompt "it's"` toggled quote state on `'`
                // inside a double-quoted string, mis-splitting into three
                // tokens instead of two. POSIX shells only close on the
                // matching opener.
                quoteChar = nil
            } else if ch == " " && quoteChar == nil {
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

    /// A4 fix: remove a `--host <value>` (or `--host=<value>`) pair from a
    /// free-form extra-args string. The app forces `--host 127.0.0.1` for
    /// loopback security; a user-supplied `--host` in extra args must not
    /// override that (llama-server/mlx honor the LAST occurrence). Tokenizes
    /// with `parseArgs` so the strip respects quoting, then drops `--host`
    /// and its following token (or the `=` form). `--port` is left alone —
    /// port selection is handled by the app's allocator and a user override
    /// there is not a security boundary.
    private func stripHostFlag(from s: String) -> String {
        let tokens = parseArgs(s)
        var filtered: [String] = []
        var skipNext = false
        for tok in tokens {
            if skipNext { skipNext = false; continue }
            if tok == "--host" {
                skipNext = true        // drop the value token too
                continue
            }
            if tok.hasPrefix("--host=") { continue }
            filtered.append(tok)
        }
        return filtered.joined(separator: " ")
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
        assertMain()   // A3: called from syncWithRunningProcesses' main hop
        // Merge: for each external process, mark its model as running
        // with the observed PID/port/ctx.
        for (id, ext) in externalStates {
            var s = modelStates[id] ?? ModelState()
            let wasRunning = s.isRunning
            s.isRunning = true
            // A1 fix: don't let a `ps` parse clobber the authoritative
            // port/ctx of a model THIS app launched. `ps` output can be
            // truncated (long command lines get cut, dropping --port or
            // --ctx-size), and the previous code unconditionally overwrote
            // our known-good values every 3s — making an app-owned model
            // flicker to "port 0" if its line was truncated. For app-owned
            // models we keep our own port/ctx; for purely external models
            // (CLI-launched) we trust `ps` as the only source. When `ps`
            // parsed a 0 for port/ctx, always keep any existing non-zero
            // value rather than blanking it.
            let appOwned = processes[id] != nil
            if appOwned {
                s.pid = s.pid ?? ext.pid
                if s.port == 0, ext.port > 0 { s.port = ext.port }
                if s.ctxSize == 0, ext.ctx > 0 { s.ctxSize = ext.ctx }
            } else {
                s.pid = ext.pid
                if ext.port > 0 || s.port == 0 { s.port = ext.port }
                if ext.ctx > 0 || s.ctxSize == 0 { s.ctxSize = ext.ctx }
            }
            modelStates[id] = s
            // Only auto-check on transition to running (newly discovered).
            // Don't re-insert on every poll — that would override a user uncheck.
            if !wasRunning {
                selected.insert(id)
            }
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
                    // No longer running → drop from the checked set so the
                    // menu checkbox clears.
                    selected.remove(id)
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

        // Both run on syncQueue (the only caller); network + file I/O
        // stay off the main thread, mutations hop back to main.
        checkIdleTTL()
        consumeAgentEvents()
    }

    // MARK:   TTL auto-unload
    //
    //  Every 10th sync tick (~30 s) probe each running, unpinned GGUF
    //  model's /slots endpoint. Any change in the response body counts as
    //  activity (n_past/n_decoded move when requests are processed, and
    //  persist afterwards — so activity between polls is still detected).
    //  A model whose response is unchanged for `ttlMinutes` is unloaded.
    //  MLX has no slots endpoint and is exempt. Only touched from syncQueue.

    private var slotActivity: [String: (sig: Int, lastActive: Date)] = [:]
    private var ttlTick = 0

    private func checkIdleTTL() {
        ttlTick += 1
        guard ttlTick % 10 == 0 else { return }
        // UserDefaults is thread-safe; `settings` is main-owned, avoid it here.
        let ttlMin = UserDefaults.standard.integer(forKey: "ttlMinutes")
        guard ttlMin > 0 else {
            if !slotActivity.isEmpty { slotActivity.removeAll() }
            return
        }

        // Snapshot running, unpinned GGUF models on main (same main.sync
        // pattern the unload path already uses on this queue).
        var candidates: [(model: ModelEntry, port: Int)] = []
        DispatchQueue.main.sync {
            for m in self.models where m.backend == .gguf {
                let st = self.state(for: m)
                if st.isRunning, st.port > 0,
                   !self.perModelSetting("pinned", default: false, for: m) {
                    candidates.append((m, st.port))
                }
            }
        }

        let now = Date()
        var toUnload: [(ModelEntry, Int)] = []
        for (model, port) in candidates {
            guard let body = fetchSlots(port: port) else {
                // 501/404/timeout — endpoint off (pre---slots launch) or
                // busy; never TTL a model we cannot observe.
                slotActivity[model.id] = nil
                continue
            }
            let sig = body.hashValue
            if let prev = slotActivity[model.id], prev.sig == sig {
                if now.timeIntervalSince(prev.lastActive) > Double(ttlMin) * 60 {
                    toUnload.append((model, ttlMin))
                }
            } else {
                slotActivity[model.id] = (sig, now)
            }
        }
        // Prune entries for models no longer candidates so a re-load
        // starts a fresh clock.
        let candidateIDs = Set(candidates.map { $0.model.id })
        slotActivity = slotActivity.filter { candidateIDs.contains($0.key) }

        for (model, minutes) in toUnload {
            slotActivity[model.id] = nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.unloadModel(model)
                self.postNotification(title: "LM Switcher",
                                      body: "Unloaded \(model.name) — idle for \(minutes) min.")
            }
        }
    }

    /// Synchronous GET of /slots; nil unless HTTP 200.
    private func fetchSlots(port: Int) -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/slots") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2.0
        var result: Data? = nil
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 { result = data }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 3.0)
        return result
    }

    // MARK:   Agent action notifications
    //
    //  lm-switcher-mcp appends one JSON line per successful mutation to
    //  events.jsonl; we drain the file each tick and post a notification
    //  per event (gated by the notifyAgentActions setting). Draining even
    //  when notifications are off keeps the file from growing unbounded.

    private func consumeAgentEvents() {
        let path = NSHomeDirectory() + "/.local/share/llama-menubar/events.jsonl"
        guard let fh = FileHandle(forUpdatingAtPath: path) else { return }
        defer { try? fh.close() }
        // A7 fix: take an exclusive advisory lock for the read+truncate
        // window. The MCP process appends one JSONL line per agent action;
        // without a lock, a line appended between our `readDataToEndOfFile`
        // and our `truncate(atOffset: 0)` would be destroyed (the truncate
        // zeros it out). `flock(LOCK_EX)` blocks the MCP's append briefly
        // (or the MCP retries) so the consume is atomic. LOCK_NB avoids
        // blocking this sync-tick caller if the MCP holds the lock — we
        // simply skip this tick and retry next cycle.
        let fd = fh.fileDescriptor
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { return }
        // Under the exclusive lock the MCP cannot append between our read and
        // truncate, so reading to EOF then zeroing is atomic and no events
        // are lost. (Without the lock, a line appended in that window would
        // be destroyed by the truncate.)
        let data = fh.readDataToEndOfFile()
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            _ = flock(fd, LOCK_UN)
            return
        }
        // Seek back to start and truncate to 0 (we've consumed everything).
        try? fh.seek(toOffset: 0)
        try? fh.truncate(atOffset: 0)
        _ = flock(fd, LOCK_UN)

        // Parse first, regardless of the notify toggle — the Agent
        // Activity feed is pull-based history and must not depend on
        // whether push notifications are also enabled.
        var parsed: [AgentEvent] = []
        for line in text.split(separator: "\n") {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let action = obj["action"] as? String,
                  let model = obj["model"] as? String else { continue }
            let ts = (obj["ts"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
            parsed.append(AgentEvent(action: action, model: model, port: obj["port"] as? Int, timestamp: ts))
        }
        guard !parsed.isEmpty else { return }

        let notify = UserDefaults.standard.object(forKey: "notifyAgentActions") as? Bool ?? true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recentAgentEvents.append(contentsOf: parsed)
            if self.recentAgentEvents.count > 20 {
                self.recentAgentEvents.removeFirst(self.recentAgentEvents.count - 20)
            }
            guard notify else { return }
            for ev in parsed {
                var body = "Agent \(ev.action) \(ev.model)"
                if let port = ev.port { body += " on :\(port)" }
                self.postNotification(title: "LM Switcher", body: body)
            }
        }
    }

    /// Post a user notification. No-ops when running outside an app bundle
    /// (UNUserNotificationCenter aborts without one — e.g. bare-binary runs).
    private func postNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                             content: content, trigger: nil))
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
        } catch {
            // If `ps` itself failed (very unusual), bail out.
            return [:]
        }
        // CRITICAL ordering: read the pipe to completion BEFORE
        // `waitUntilExit()`. `ps -ax` on a busy system easily exceeds the
        // ~64KB kernel pipe buffer; if we wait for exit first, `ps` blocks
        // on `write(2)` once the buffer fills (because nobody is draining
        // the read end) and `waitUntilExit()` deadlocks — the sync hangs and
        // running models never get detected ("All stopped" even when they're
        // up). `readDataToEndOfFile()` drains as `ps` writes, so the child
        // never blocks; then the wait returns immediately.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""

        var externalStates: [String: (pid: Int32, port: Int, ctx: Int)] = [:]

        for line in output.split(separator: "\n") {
            let s = String(line)
            guard s.contains("llama-server") || s.contains("mlx_lm.server") else { continue }

            // A2 fix: use NSRegularExpression with an explicit capture group
            // for the model path, instead of slicing the full match by a
            // hardcoded `dropFirst(dropLen)` count. The slice approach worked
            // only by coincidence (the prefix length happened to match), and
            // it returned the full match range rather than group 1. Capture
            // groups are robust to pattern tweaks.
            let mPattern: String
            if s.contains("llama-server") {
                // H-3 fix: allow spaces inside the path. The old pattern
                // `-m (\/[^\s]+\.gguf)` stopped at the first space, so a
                // model at "/Users/x/My Models/g.gguf" captured only
                // "/Users/x/My" and never matched a known ModelEntry.
                // GGUF paths always end in `.gguf`, so match lazily up to
                // the FIRST `.gguf` (the base model always comes before
                // --mmproj / --spec-draft-model companions).
                mPattern = #"-m (\/.+?\.gguf)"#
            } else {
                // MLX `--model` points at a directory (no extension). Match
                // everything up to the next ` --` flag boundary or end of
                // line, so spaces in the directory name are preserved.
                mPattern = #"--model (\/.+?)(?= --|$)"#
            }
            var pathStr: String?
            if let re = try? NSRegularExpression(pattern: mPattern, options: []) {
                let nsr = NSRange(s.startIndex..., in: s)
                if let m = re.firstMatch(in: s, options: [], range: nsr),
                   m.numberOfRanges >= 2, let r = Range(m.range(at: 1), in: s) {
                    pathStr = String(s[r])
                }
            }
            guard var path = pathStr else { continue }
            path = path.trimmingCharacters(in: .whitespaces)

            let trimmed = s.drop(while: { $0 == " " })
            let pidStr = trimmed.prefix(while: { $0.isNumber })
            // A2 fix: reject pid == 0. A garbled/truncated `ps` line that
            // fails to parse previously coerced to 0; `kill(0, 0)` then
            // reported "alive" forever (pid 0 is always testable), so the
            // model got stuck showing as running with PID 0. Drop the line
            // instead — better to miss a model than to wedge its state.
            guard let pid = Int32(pidStr), pid > 0 else { continue }

            var port = 0
            if let pm = s.range(of: #"--port (\d+)"#, options: .regularExpression) {
                port = Int(String(s[pm].split(separator: " ").last ?? "0")) ?? 0
            }
            var ctx = 0
            if let pm = s.range(of: #"--ctx-size (\d+)"#, options: .regularExpression) {
                ctx = Int(String(s[pm].split(separator: " ").last ?? "0")) ?? 0
            }
            externalStates[path] = (pid, port, ctx)
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

        // MTP toggle: ON by default when unset (matches the CLI's
        // pm_bool default — both surfaces must agree).
        settings.enableMtp = d.object(forKey: "enableMtp") as? Bool ?? true

        // DFlash drafter toggle: on by default (absent key reads as true).
        settings.enableDflash = d.object(forKey: "enableDflash") as? Bool ?? true

        // MCP agent access: off by default — absent key reads as false.
        settings.mcpEnabled = d.bool(forKey: "mcpEnabled")
        settings.allowSwapLoads = d.bool(forKey: "allowSwapLoads")
        settings.notifyAgentActions = d.object(forKey: "notifyAgentActions") as? Bool ?? true
        settings.ttlMinutes = d.integer(forKey: "ttlMinutes")

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
        d.set(settings.enableDflash, forKey: "enableDflash")
        d.set(settings.mcpEnabled, forKey: "mcpEnabled")
        d.set(settings.allowSwapLoads, forKey: "allowSwapLoads")
        d.set(settings.notifyAgentActions, forKey: "notifyAgentActions")
        d.set(settings.ttlMinutes, forKey: "ttlMinutes")
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
