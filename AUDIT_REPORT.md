# LM Switcher — Scout Audit Report

**Date:** 2025-06-29  
**Repo:** `/Users/rolandchia/Projects/llm-switcher`
**Auditor:** Automated scout audit  
**Files reviewed:**
- `src/LlamaMenubarApp.swift` (2984 lines)
- `src/llama` (679 lines, bash CLI)
- `scripts/install.sh` (280 lines, zsh)

---

## Executive Summary

The codebase is remarkably well-documented and generally well-structured for a single-file Swift app. The comments are thorough and accurately describe the code's intent in most places. However, there are several notable findings across security, concurrency, and robustness dimensions. The most critical are an empty `catch` block that silently swallows process spawn failures, race conditions on shared dictionaries, and a command-injection surface in the CLI's extra-args handling.

**Finding counts:** 2 CRITICAL · 5 HIGH · 11 MEDIUM · 12 LOW

---

## 1. CRITICAL FINDINGS

### C-1: Silent failure on `Process.run()` — empty catch block

**Severity:** CRITICAL  
**File:** `LlamaMenubarApp.swift`, lines 2483–2485  
**Description:**
```swift
} catch {

}
```
When `task.run()` throws (e.g. the `llama-server` or `mlx_lm.server` binary doesn't exist, is not executable, or the path is wrong), the error is silently swallowed. The user sees nothing — no model loads, no error message, no state update. The `modelStates` entry is never set to running, so the UI shows the model as stopped with zero indication of why. This is the single worst UX defect in the codebase because the most common failure mode (wrong binary path on first run) produces no feedback at all.

**Remediation:**
```swift
} catch {
    // Record the error in model state so the UI can display it.
    var s = modelStates[model.id] ?? ModelState()
    s.isRunning = false
    s.lastError = "\(error)"
    modelStates[model.id] = s
    // Optionally: NSSound.beep() or a notification.
}
```

### C-2: Command injection via `LLAMA_EXTRA_ARGS` in CLI

**Severity:** CRITICAL (exploitable if env var is attacker-controlled)  
**File:** `src/llama`, lines 408–410  
**Description:**
```bash
if [[ -n "$LLAMA_EXTRA_ARGS" ]]; then
    args+=($LLAMA_EXTRA_ARGS)
fi
```
`$LLAMA_EXTRA_ARGS` is unquoted and word-split without sanitization. While this is an environment variable (so the attacker needs control over the environment), it means an exported variable like `LLAMA_EXTRA_ARGS='$(malicious_cmd)'` or `LLAMA_EXTRA_ARGS='; rm -rf ~'` would be passed as arguments to `nohup "$executable"`. Since `nohup` execs the binary directly (not through a shell), pure argument injection is contained — but if the model path or args contain shell metacharacters that are later expanded by any downstream tool, this could escalate. More realistically, **the Swift app's `parseArgs` and `Process` usage is safe** (it passes arguments as an array, no shell), but the CLI's `nohup` invocation with unsanitized array expansion is a risk if `LLAMA_EXTRA_ARGS` contains paths with spaces or glob characters.

**Remediation:** Use `read -ra` to split on whitespace safely, or use a proper quoting function:
```bash
if [[ -n "$LLAMA_EXTRA_ARGS" ]]; then
    read -ra extra <<< "$LLAMA_EXTRA_ARGS"
    args+=("${extra[@]}")
fi
```

---

## 2. HIGH FINDINGS

### H-1: Race condition — `modelStates` and `processes` accessed from multiple threads without synchronization

**Severity:** HIGH  
**File:** `LlamaMenubarApp.swift`, lines 1755, 1760, 2440–2456, 2698–2703  
**Description:**
`modelStates` and `processes` are plain dictionaries on a class. `@Observable` does not enforce thread safety. They are mutated from:
- The main thread (via `loadModel`, `unloadModel`, `unloadAll` — button clicks).
- A background `DispatchQueue.global(qos: .utility)` callback in `onWake()` → `syncWithRunningProcesses()`.
- The `syncQueue` (serial) timer → `syncWithRunningProcesses()`.
- Process `terminationHandler` closures (background thread → hops to main).

The `syncWithRunningProcesses` method explicitly documents that `ps` spawn happens on the calling thread, and the mutation is dispatched to `DispatchQueue.main.async`. However, `collectExternalStatesFromPS()` called from `onWake()` runs on `DispatchQueue.global(qos: .utility)`, which is **not** the same serial `syncQueue`. If both fire concurrently, the `ps` spawns overlap and there's no protection. While the final mutation hops to main, the `_ = manager.refreshTrigger` reads and the `perModelSetting` reads in the UI can interleave with background mutations.

**Remediation:** Either (a) route all `syncWithRunningProcesses` calls through the same `syncQueue`, or (b) use a lock (`NSLock` / actor) around dictionary access. The simplest fix is to change `onWake` to use `syncQueue.async` instead of `DispatchQueue.global`:
```swift
syncQueue.async { [weak self] in self?.syncWithRunningProcesses() }
```

### H-2: Per-model override logic does not respect "override OFF" for ALL settings in `loadModel`

**Severity:** HIGH  
**File:** `LlamaMenubarApp.swift`, lines 2284–2412  
**Description:**
When `overrides = perModelOverrideEnabled(for: model)` is `false`, the code correctly uses `settings.*` (global) for most values. However, several settings are read from `settings.*` directly without going through the `pm()` helper:
- `settings.chatTemplatePath` (line 2332) — always uses global, correct.
- `settings.flashAttention` (line 2351) — always uses global, correct.
- `settings.suppressReasoning` (line 2358) — always uses global, correct.
- `settings.seed` (lines 2381, 2405) — always uses global, correct.
- `settings.cpuThreads` (line 2386) — always uses global, correct.
- `settings.batchSize` (line 2389) — always uses global, correct.
- `settings.mlock` (line 2390) — always uses global, correct.
- `settings.noMmap` (line 2393) — always uses global, correct.
- `settings.mlxMaxKvSize` (line 2409) — always uses global, correct.

These are NOT overridable per-model in `loadModel`, even though the UI (`perModelOverrideFields`) doesn't expose them either. **The mismatch is that the UI exposes per-model overrides for `kvCacheTypeK`, `kvCacheTypeV`, `thinkingEnabled`, `enableMtp`, `extraArgs`, `temperature`, `topP`, `topK`, `repeatPenalty`, `port`, `ctx` — and `loadModel` correctly uses these via `pm()`.** The non-overridable settings are consistent. **No actual bug here — the logic is correct.** However, `flashAttention`, `suppressReasoning`, `seed`, `cpuThreads`, `batchSize`, `mlock`, `noMmap`, `mlxMaxKvSize` have **no per-model override** even though some users might want per-model control over them (e.g., `flashAttention` off for a specific buggy model). This is a design limitation, not a bug.

**Reclassification:** This finding is informational, not a defect. The override logic is correctly implemented for all exposed settings.

### H-3: `ps` regex parsing fails on paths with spaces

**Severity:** HIGH  
**File:** `LlamaMenubarApp.swift`, lines 2744, 2747  
**Description:**
```swift
mPattern = #"-m (\/[^\s]+\.gguf)"#  // GGUF
mPattern = #"--model (\/[^\s]+)"#     // MLX
```
The regex `[^\s]+` stops at the first whitespace. If a model path contains spaces (e.g. `/Users/roland/My Models/gemma.gguf`), the regex will only capture `/Users/roland/My` and the model ID won't match any known `ModelEntry.id`. The externally-launched model will be invisible to the menu bar app. The companion CLI handles spaces correctly (it uses `"$path"`), but the Swift regex-based reconciliation does not.

**Remediation:** Use a more permissive regex (e.g. match until the next `--` flag) or, better, use `NSRegularExpression` with a pattern like `-m (\S+\.gguf)` and accept that paths with spaces in the `.gguf` filename portion won't be matched. For a proper fix, scan the argument list rather than using regex on the full command string.

### H-4: `unloadAll()` only iterates `processes.keys` — misses externally-launched models

**Severity:** HIGH  
**File:** `LlamaMenubarApp.swift`, lines 2528–2532  
**Description:**
```swift
for id in Array(processes.keys) { ... }
// Then:
for (id, state) in modelStates where state.isRunning { ... }
```
The first loop handles owned processes. The second loop handles externally-launched ones. However, the second loop calls `unloadModel(m)` which does `if let p = processes[model.id] { ... } else if let s = modelStates[model.id], let pid = s.pid { kill(pid, SIGTERM) }`. This works for external processes that have a matching `ModelEntry`. But for external processes whose model path doesn't match any current `ModelEntry` (e.g., the model file was deleted), it falls through to the `else` branch which calls `kill(pid, SIGTERM)` directly — correct. **However, the state is not cleared in that `else` branch.** The `modelStates[id]` entry keeps `isRunning = true` until the next `syncWithRunningProcesses` clears it. If `unloadAll()` is followed by `NSApplication.shared.terminate(nil)` (the Quit button), the app exits before the sync timer runs, so stale state doesn't matter. But if `unloadAll()` is called from the "⏹" button and the app keeps running, the stale state persists for up to 3 seconds.

**Remediation:** In the `else` branch of `unloadAll`, clear `modelStates[id]` after killing:
```swift
if let pid = state.pid { kill(pid, SIGTERM) }
modelStates[id]?.isRunning = false
modelStates[id]?.pid = nil
```

### H-5: No single-instance check — app can be launched twice

**Severity:** HIGH  
**File:** `scripts/install.sh` (LaunchAgent), `LlamaMenubarApp.swift` (entry point)  
**Description:**
The `LaunchAgent` plist has `RunAtLoad=true` and `KeepAlive=false`. If the user launches the app via Launchpad/Spotlight while the LaunchAgent has already started it, **two instances run simultaneously**. Both will:
- Watch the same models directory.
- Run the same 3-second `ps` sync timer.
- Potentially both try to `loadModel` on the same port → collision.
- Both write to the same `UserDefaults` domain.

There is no `NSApplication.shared.activationPolicy` check, no file-lock-based singleton guard, and no `NSDistributedNotificationCenter` handshake.

**Remediation:** Add a single-instance check in `init()` or `applicationDidFinishLaunching`:
```swift
// Use a file lock or distributed notification
let lockFile = "/tmp/llama-menubar.lock"
let fd = open(lockFile, O_CREAT | O_RDWR, 0o644)
if flock(fd, LOCK_EX | LOCK_NB) == -1 {
    // Another instance is running — activate it and exit.
    NSApp.activate(ignoringOtherApps: true)
    NSApp.terminate(nil)
}
```

---

## 3. MEDIUM FINDINGS

### M-1: `nextAvailablePort()` does not check if the port is actually free on the system

**Severity:** MEDIUM  
**File:** `LlamaMenubarApp.swift`, lines 2549–2556  
**Description:**
`nextAvailablePort()` only checks ports already in `modelStates`. If another application (not managed by LM Switcher) is using port 8080, the `Process.run()` call will fail — and thanks to C-1, the failure is silently swallowed.

**Remediation:** Attempt a `bind()` on `127.0.0.1:port` to verify availability, or at minimum catch the `Process.run()` error (see C-1) and retry on the next port.

### M-2: `pendingCtxEdit` is dead code

**Severity:** MEDIUM (noise)  
**File:** `LlamaMenubarApp.swift`, line 1750  
**Description:**
```swift
var pendingCtxEdit: URL? = nil
```
This property is declared, documented as "reserved for future use," and never read or written anywhere else in the file. It's `@Observable`-tracked, so it adds unnecessary observation overhead.

**Remediation:** Remove the property, or mark it `@ObservationIgnored` if kept for future use.

### M-3: `statusText` computed property is never used by any view

**Severity:** MEDIUM (dead code)  
**File:** `LlamaMenubarApp.swift`, lines 1975–1983  
**Description:**
`statusText` is computed but never referenced in `MenuView` or `SettingsView`. The menu uses `summaryText` instead. The `@Observable` macro will still track reads, and any change to `modelStates` triggers re-evaluation if it were read — but since it's never read, it's just dead code.

**Remediation:** Remove `statusText`, or use it in the menu bar label if intended.

### M-4: Settings `@State` mirrors can drift from `UserDefaults` values

**Severity:** MEDIUM  
**File:** `LlamaMenubarApp.swift`, lines 663–716 (init), 588–655 (onChange handlers)  
**Description:**
`SettingsView` initializes `@State` mirrors from `manager.settings.*` in `init`. The `onChange` handlers write to both the `@State` mirror and `manager.settings.*` (which persists to UserDefaults). However, if the CLI (`llama ctx`, `llama port`) writes to UserDefaults while the Settings window is open, the `@State` mirrors won't update — they only refresh when the view is re-created. The user sees stale values in the text fields.

**Remediation:** Either (a) observe `UserDefaults.didChangeNotification` and refresh mirrors, or (b) bind directly to `manager.settings` instead of using `@State` mirrors (losing the "cancel without save" behavior), or (c) add a "Refresh" button.

### M-5: `cleanStalePerModelKeys()` runs on the main thread during `refreshModels()`

**Severity:** MEDIUM  
**File:** `LlamaMenubarApp.swift`, lines 2109–2123, called from line 2173  
**Description:**
`cleanStalePerModelKeys()` calls `UserDefaults.standard.dictionaryRepresentation().keys` which returns a snapshot of ALL UserDefaults keys — this can be hundreds of keys (system keys, other app keys if the domain is shared). Iterating and removing them on the main thread during a file-system watcher event (which fires on `.main` queue) could cause a brief UI hitch if the key set is large.

**Remediation:** Move to a background queue, or cache the valid hashes and only scan `model.*` prefixed keys.

### M-6: `scanDirectory` recursion has no depth limit

**Severity:** MEDIUM  
**File:** `LlamaMenubarApp.swift`, lines 2181–2213  
**Description:**
`scanDirectory` recurses into subdirectories with no depth limit. If the models directory contains a symlink loop (e.g. `~/models/link -> ~/models`), the scan will infinitely recurse and hang the main thread (since the watcher fires on `.main`).

**Remediation:** Add a `maxDepth` parameter (e.g. 10), and/or resolve symlinks and detect cycles:
```swift
private func scanDirectory(_ dir: URL, into entries: inout [ModelEntry], baseDir: URL, depth: Int = 0) {
    guard depth < 10 else { return }
    ...
}
```

### M-7: File watcher watches PARENT directory, causing excessive refreshes

**Severity:** MEDIUM  
**File:** `LlamaMenubarApp.swift`, lines 1897–1944  
**Description:**
The comment on line 1887 explains: "Watching the directory itself doesn't fire on changes to its subdirectories, so we watch one level up." But this means ANY change to the parent directory (e.g., if `modelsDir` is `~/models`, any file created/modified in `~` triggers a refresh). `refreshModels()` calls `FileManager.default.contentsOfDirectory` recursively, so this is wasteful. On macOS, `FSEvents` or `DispatchSource.makeFileSystemObjectSource` on the models directory itself with `.write` should fire on file additions in some configurations. The parent-watching approach is a workaround that causes excessive refreshes.

**Remediation:** Use `FSEventStream` (via `FSEvents` framework) which supports recursive watching, or accept the cost and add a debounce.

### M-8: `parseArgs` does not handle escaped quotes or backslashes

**Severity:** MEDIUM  
**File:** `LlamaMenubarApp.swift`, lines 2618–2633  
**Description:**
The `parseArgs` function toggles `inQuote` on `"` or `'` but does not handle `\` escape sequences. A user entering `--prompt "say \"hello\""` in the Extra Args field will get `--prompt`, `say \`, `hello\` instead of `--prompt`, `say "hello"`. This can cause unexpected server behavior.

**Remediation:** Add escape handling, or use `CommandLine.arguments`-style parsing from a library like `Swift Argument Parser`.

### M-9: MLX MLX path regex doesn't validate `.safetensors` — `mlxEntry` only checks file extension

**Severity:** MEDIUM (low impact)  
**File:** `LlamaMenubarApp.swift`, lines 2249–2266  
**Description:**
`mlxEntry` checks if any file in the directory has a `.safetensors` extension and if `config.json` exists. A directory with a `config.json` and a single empty `.safetensors` file would be classified as a valid MLX model. This is unlikely in practice but could cause a confusing error when trying to load.

**Remediation:** No action needed — the heuristic is reasonable for the use case.

### M-10: CLI `next_port()` reads PID files with `head -1` which can fail on empty files

**Severity:** MEDIUM  
**File:** `src/llama`, lines 294–304  
**Description:**
If a `.pid` file is empty (e.g., killed mid-write), `head -1` returns empty, and `kill -0 ""` fails silently. The port from the stale file won't be detected, potentially causing a port collision.

**Remediation:** Add `[[ -n "$p" ]]` check before `kill -0`:
```bash
p=$(head -1 "$pf" 2>/dev/null)
[[ -n "$p" ]] || continue
```
Actually, looking more carefully at the code, line 298 already has `[[ -n "$p" ]] && kill -0 "$p" 2>/dev/null || continue` — but the `||` binds to the whole `&&` chain, so if `p` is empty, the `||continue` fires. **This is actually correct.** No bug.

**Reclassification:** Not a bug — the logic is sound. The `&&...||` idiom works as intended.

### M-11: CLI `load_model` sleeps 1 second to check if process started — race condition

**Severity:** MEDIUM  
**File:** `src/llama`, lines 428–436  
**Description:**
```bash
sleep 1
if kill -0 "$newpid" 2>/dev/null; then
    echo "● [$type] $name loaded on :$port (PID $newpid)"
else
    echo "✗ Failed to start $name"
    rm -f "$pf"
    return 1
fi
```
The 1-second sleep is a heuristic. A slow-loading model (large GGUF on first mmap) might still be alive at 1s but crash at 2s. Conversely, a fast-failing binary might produce the "loaded" message and then exit immediately. The CLI doesn't verify the port is actually listening.

**Remediation:** Poll `nc -z 127.0.0.1 $port` or `lsof -i :$port` with a timeout instead of `kill -0`.

---

## 4. LOW FINDINGS

### L-1: `SettingsWindowHost` window is never released on app termination

**Severity:** LOW  
**File:** `LlamaMenubarApp.swift`, lines 145–204  
**Description:**
`window` is held strongly by `SettingsWindowHost` which is held by `@State` in the app. `isReleasedWhenClosed = false` means closing the window doesn't deallocate it. On app termination, `NSApplication.shared.terminate(nil)` cleans up, but the window is not explicitly released. This is fine for a menu bar app (the OS reclaims everything on exit), but it means the SwiftUI hosting controller and its view tree persist in memory for the app's lifetime.

**Remediation:** No action needed — this is the intended design for fast re-opening.

### L-2: `summaryText` sorts ports as strings, not integers

**Severity:** LOW  
**File:** `LlamaMenubarApp.swift`, line 1989  
**Description:**
```swift
let ports = running.values.map { "\($0.port)" }.sorted().joined(separator: ", ")
```
String sorting means ports `8080, 8081, 8082` sort correctly, but `8080, 808` would sort as `8080, 808` (lexicographic). In practice, all ports are 4-5 digits starting at 8080, so this is unlikely to matter.

**Remediation:** Sort numerically: `.map { $0.port }.sorted().map(String.init)`

### L-3: `findCompanion` quantization stripping is incomplete

**Severity:** LOW  
**File:** `LlamaMenubarApp.swift`, lines 2583–2589  
**Description:**
The quantization stripping handles `-Q4_K_M`, `-Q4_K_S`, `-Q5_K_M`, `-Q5_K_S`, `-Q6_K`, `-Q8_0` but misses:
- `-Q4_0`, `-Q4_1`, `-Q5_0`, `-Q5_1`
- `-Q2_K`, `-Q3_K_M`, `-Q3_K_S`, `-Q3_K_L`
- `-F16`, `-F32`, `-BF16`
- `-IQ4_NL`, `-IQ3_XXS`, etc.

The CLI (`src/llama`, line 357) handles this more robustly with a regex: `sed -E 's/-Q[0-9]+(_[0-9]+)?(_K)?(_[A-Z]+)?$//'`. The Swift app should do the same.

**Remediation:** Use a regex:
```swift
let stripped = base.replacingOccurrences(
    of: #"(-Q[0-9]+(_K)?(_[A-Z]+)?|-F16|-F32|-BF16)"#,
    with: "",
    options: .regularExpression
)
```

### L-4: Comment says "skipsPackageDescendants" but it's not the right behavior for MLX

**Severity:** LOW (documentation accuracy)  
**File:** `LlamaMenubarApp.swift`, line 2184  
**Description:**
```swift
// `skipsPackageDescendants` avoids descending into .app, .bundle, etc.
```
This is accurate per the API docs. However, it also means that if someone has a `.gguf` file inside an MLX directory that's classified as a package, it won't be found. This is unlikely since MLX dirs aren't packages, but it's an edge case.

**Remediation:** No action needed; the comment is accurate.

### L-5: `Import CryptoKit` used only for `Insecure.MD5`

**Severity:** LOW (security hygiene)  
**File:** `LlamaMenubarApp.swift`, line 82, 2034  
**Description:**
`Insecure.MD5` is used for generating per-model setting keys. While MD5 is fine for non-cryptographic purposes (generation of stable hash prefixes), using the `Insecure` namespace signals that it shouldn't be used for security. This is correct usage. However, if the model path is ever used in a security-sensitive context (it's not currently), this would be a weakness.

**Remediation:** No action needed — usage is appropriate. Could use SHA-256 for future-proofing but no real risk.

### L-6: `directorySource` and `directoryFD` are not `@ObservationIgnored`

**Severity:** LOW  
**File:** `LlamaMenubarApp.swift`, lines 1892–1895  
**Description:**
```swift
private var directoryFD: Int32 = -1
private var directorySource: DispatchSourceFileSystemObject?
```
These are private and never read in any SwiftUI view, so `@Observable` won't trigger view updates from them. But they're still tracked by the observation system, adding minor overhead.

**Remediation:** Mark as `@ObservationIgnored`:
```swift
@ObservationIgnored private var directoryFD: Int32 = -1
@ObservationIgnored private var directorySource: DispatchSourceFileSystemObject?
```

### L-7: Hardcoded Python version `3.14` in MLX server path

**Severity:** LOW (maintainability)  
**File:** `LlamaMenubarApp.swift`, line 2797; `src/llama`, line 72; `scripts/install.sh`  
**Description:**
```swift
settings.mlxServerPath = d.string(forKey: "mlxServerPath")
    ?? (NSHomeDirectory() + "/Library/Python/3.14/bin/mlx_lm.server")
```
The default MLX server path hardcodes Python 3.14. If the user installs `mlx_lm` via a different Python version (3.12, 3.13), the path won't match and the model won't load — with no helpful error message (see C-1).

**Remediation:** Detect the available Python version at launch, or try multiple paths.

### L-8: `install.sh` compiles from `~/bin/llama-menubar.swift`, not from the repo source

**Severity:** LOW (confusing path)  
**File:** `scripts/install.sh`, lines 52, 89–91  
**Description:**
```bash
SWIFT_FILE="$BIN_DIR/llama-menubar.swift"
# ...
swiftc -parse-as-library -o "$COMPILED_BIN" -O \
    -framework SwiftUI -framework AppKit \
    "$SWIFT_FILE"
```
The install script expects the source file to already be in `$BIN_DIR` (default `~/bin`). It doesn't copy `src/LlamaMenubarApp.swift` to `$BIN_DIR/llama-menubar.swift` first. If the user runs `scripts/install.sh` directly from a fresh clone, it will fail with "file not found" unless they've manually copied the source.

**Remediation:** Add a copy step at the beginning:
```bash
cp "$(dirname "$0")/../src/LlamaMenubarApp.swift" "$SWIFT_FILE"
cp "$(dirname "$0")/../src/llama" "$BIN_DIR/llama"
```
Or change `SWIFT_FILE` to reference the repo source directly.

### L-9: `install.sh` LaunchAgent does not handle crash recovery

**Severity:** LOW  
**File:** `scripts/install.sh`, lines 233–250  
**Description:**
The LaunchAgent plist has `KeepAlive=false`, which means if the app crashes, it won't restart. The comment says "this is the right behavior for a menu bar app the user explicitly quits" — but a crash is not an explicit quit. For crash recovery, `KeepAlive` can be set to a dictionary:
```xml
<key>KeepAlive</key>
<dict>
    <key>AfterInitialCrash</key>
    <true/>
</dict>
```
Or just `KeepAlive=true` with a short `ThrottleInterval` — but then the user's "Quit" would be overridden. The cleanest approach is `KeepAlive` with `SuccessfulExit=false`:
```xml
<key>KeepAlive</key>
<dict>
    <key>SuccessfulExit</key>
    <false/>
</dict>
```
This restarts on crash but not on clean exit.

**Remediation:** Use `SuccessfulExit=false` in the LaunchAgent plist.

### L-10: `modesPane` "Save" button doesn't actually save per-model settings (they're already saved)

**Severity:** LOW (UX confusion)  
**File:** `LlamaMenubarApp.swift`, lines 1429–1434  
**Description:**
The "Save" button in the Per-Model tab shows "✓ Saved" feedback but doesn't call any save method — per-model settings are written to UserDefaults immediately on `set:` in the bindings. The button is purely decorative. The global "Save" button (line 1082) does call `manager.saveSettings()`, so users might expect the per-model one to do something similar.

**Remediation:** Remove the per-model "Save" button (since changes are immediate), or add a comment explaining it's just feedback.

### L-11: `AppState.extraArgs` field in `ModelState` is unused

**Severity:** LOW (dead code)  
**File:** `LlamaMenubarApp.swift`, lines 291–293  
**Description:**
```swift
/// Reserved for future per-model extra args. Currently unused — the
/// global `AppSettings.globalExtraArgs` covers most use cases.
var extraArgs: String = ""
```
This field is never read or written. The per-model extra args are stored in UserDefaults via `perModelSetting("extraArgs", ...)`.

**Remediation:** Remove the field.

### L-12: `cmd_unload all` in CLI has a broken model name extraction

**Severity:** LOW  
**File:** `src/llama`, line 543  
**Description:**
```bash
mname=$(ps -o args= -p "$pid" 2>/dev/null | head -1 | sed 's/.*\(mlx_lm\.server\|llama-server\).*//')
```
This `sed` command replaces everything from `mlx_lm.server` or `llama-server` to the end with nothing — so if the process args are `mlx_lm.server --model /path/to/model`, `mname` will be empty. The `unload_model` function uses `mname` only for display, so the user sees "○  stopped" instead of "○ model-name stopped".

**Remediation:** Fix the extraction or just use the PID file name:
```bash
mname=$(basename "$pf" .pid)
```

---

## 5. SWIFT/SWIFTUI-SPECIFIC OBSERVATIONS

### S-1: No force unwraps found

The codebase has zero force unwraps (`!`), which is excellent. All optional access uses `if let`, `guard let`, or `??`.

### S-2: Main thread violations

- `Process.run()` is called in `loadModel()` on the main thread (line 2472). This is generally fine — `Process.run()` is a lightweight fork/exec that doesn't block. The heavier work (pipe reads) was moved to the background `syncQueue`. 
- `collectExternalStatesFromPS()` is called from `onWake()` on `DispatchQueue.global(qos: .utility)` — correct, it's off the main thread.
- The file watcher handler fires on `.main` (line 1923: `queue: .main`) and calls `refreshModels()` which does synchronous file I/O on the main thread. For a models directory with many files, this could cause a brief UI hang.

### S-3: `@Observable` tracking — properties that should be `@ObservationIgnored`

- `directoryFD` and `directorySource` (lines 1892, 1895) — should be `@ObservationIgnored` (see L-6).
- `pendingCtxEdit` (line 1750) — dead code, should be removed (M-2).
- `modelStates` and `processes` are private but not `@ObservationIgnored`. Since they're never directly read by SwiftUI views (views use `state(for:)` which reads `modelStates`), changes to these dictionaries DO trigger observation. The `state(for:)` method creates an observation dependency on `modelStates` when called from a view body. This is actually the intended mechanism — mutating `modelStates` in `loadModel`/`unloadModel`/`mergeExternalStates` triggers view re-evaluation. This is correct.

### S-4: View body re-evaluation

- `MenuView.body` references `manager.models`, `manager.selected`, `manager.anyRunning`, `manager.summaryText` — all correctly tracked.
- `perModelOverrideFields` uses `let _ = manager.refreshTrigger` (line 1514) to force re-evaluation. This is a workaround for the fact that UserDefaults writes don't trigger `@Observable` changes. It works but is fragile — if `refreshTrigger` is accidentally not bumped somewhere, the UI won't update. A cleaner approach would be to mirror per-model settings in `@Observable` properties.

### S-5: Retain cycles

- Process `terminationHandler` (line 2440) uses `[weak self]` — correct.
- Sleep/wake observers (lines 1819, 1824) use `[weak self]` — correct.
- File watcher handler (line 1928) uses `[weak self]` — correct.
- File watcher cancel handler (line 1934) uses `[weak self]` but then does `guard let self = self else { return }` and accesses `self.directoryFD` — this is fine since it's a strong capture inside the guard scope, which only runs once on cancellation.
- Timer handler (line 1842) uses `[weak self]` — correct.
- `DispatchQueue.main.async` in `syncWithRunningProcesses` (line 2700) uses `[weak self]` — correct.
- `DispatchQueue.global` in `onWake` (line 1879) uses `[weak self]` — correct.

**No retain cycles found.** The codebase is exemplary in its use of `[weak self]`.

---

## 6. ARCHITECTURE ASSESSMENT

### A-1: Single-file approach at ~3000 lines

**Assessment:** Borderline. The file is well-organized with clear MARK sections, and the extensive comments make it navigable. However, at 2984 lines it's at the limit of what a single file can reasonably sustain. The `SettingsView` (lines 659–1717) alone is ~1060 lines and could be split into a separate file. The help and about panes (lines 1100–1416) are pure static content that doesn't need to be in the same file as the business logic.

**Recommendation:** Split into:
- `LlamaMenubarApp.swift` (entry point + `SettingsWindowHost`)
- `ServerManager.swift` (model discovery, load/unload, sync)
- `MenuView.swift`
- `SettingsView.swift` (+ modifier structs)
- `DomainTypes.swift` (`ModelEntry`, `ModelState`, `ModelBackend`, `AppSettings`)
- `HelpAndAbout.swift`

### A-2: `ServerManager` responsibilities

**Assessment:** `ServerManager` has too many responsibilities:
1. Model discovery (filesystem scanning)
2. Process lifecycle (spawn, terminate, port allocation)
3. Settings persistence (load/save to UserDefaults)
4. Per-model settings (get/set/cleanup)
5. External process reconciliation (ps scanning)
6. File system watching
7. Sleep/wake handling

This is a "God Object" anti-pattern. Each responsibility is well-implemented and well-documented, but they should be factored into separate types:
- `ModelDiscovery` (scanning, watching)
- `ProcessManager` (spawn, terminate, port allocation, process tracking)
- `SettingsStore` (UserDefaults read/write)
- `ExternalProcessReconciler` (ps scanning)

### A-3: Settings persistence — `@State` mirrors + UserDefaults

The pattern of mirroring `AppSettings` fields as `@State` in `SettingsView` and syncing via `onChange` is functional but verbose (5 `ViewModifier` structs just to hold the `onChange` handlers). A `@Bindable` wrapper around `AppSettings` directly (if it were a class instead of a struct) would eliminate the boilerplate, but `AppSettings` being a struct is the correct Swift pattern for value semantics. The `onChange` approach works, but means each keystroke triggers a UserDefaults write (which is asynchronous and coalesced, so not a performance issue).

---

## 7. BUILD & DEPLOY ASSESSMENT

### B-1: `install.sh` is mostly idempotent

The script removes and recreates the app bundle on each run (`rm -rf "$APP_BUNDLE"`), which is correct. The LaunchAgent bootstrap is idempotent (line 254: `|| true`). The codesign and lsregister steps use `|| true` or `2>/dev/null`, so they don't fail the script on warnings.

### B-2: Missing source copy step (see L-8)

`install.sh` expects `$SWIFT_FILE` to already exist at `$BIN_DIR/llama-menubar.swift` but doesn't copy it from `src/`. This means the script as written cannot be run from a fresh clone without a manual copy step.

### B-3: No version checking

The app version is hardcoded as `1.0` in `Info.plist` (line 159) but `1.1.0` in the About pane (line 1337). These are inconsistent.

### B-4: `--deep` codesigning is deprecated

**Severity:** LOW  
**File:** `scripts/install.sh`, line 189  
Apple has deprecated `--deep` codesigning. For a single-binary app bundle with no nested frameworks, it still works but produces a warning. 

**Remediation:** Sign the binary directly, then the bundle:
```bash
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/llama-menubar"
codesign --force --sign - "$APP_BUNDLE"
```

---

## 8. SECURITY ASSESSMENT

### SEC-1: Model paths are passed as Process arguments, not through a shell

**Assessment:** The Swift app uses `Process()` with `executableURL` and `arguments` array. This is the correct and safe approach — no shell interpretation occurs. Model paths with spaces, special characters, or even shell metacharacters are safe because `Process` passes them directly to `execve(2)`.

### SEC-2: No sensitive data in UserDefaults

**Assessment:** UserDefaults stores only configuration (paths, ports, sampling parameters). No API keys, tokens, or credentials are stored. The app binds to `127.0.0.1` only, so no network exposure.

### SEC-3: File watcher — malicious files in models dir

**Assessment:** A malicious file named `evil.gguf` in the models directory would be displayed in the menu. If loaded, `llama-server` would try to load it as a model — this could crash `llama-server` but wouldn't execute arbitrary code (the server reads the file as binary model data, not as executable). A malicious MLX directory with a crafted `config.json` could cause `mlx_lm.server` to behave unexpectedly, but again, no arbitrary code execution path exists.

### SEC-4: CLI model name arguments — shell injection

**Assessment:** The CLI uses `"$query"` and `"$path"` with proper quoting throughout (`"$f"`, `"$d"`, etc.). The `resolve_query` function matches against model names using `[[ "$name" == *"$query"* ]]` — this is a bash pattern match, not a shell command, so it's safe from injection. However, `LLAMA_EXTRA_ARGS` (C-2) is the one injection surface.

---

## Summary Table

| ID | Severity | File | Line(s) | Category | Brief |
|---|---|---|---|---|---|
| C-1 | CRITICAL | LlamaMenubarApp.swift | 2483-2485 | Bug | Empty catch block swallows spawn errors |
| C-2 | CRITICAL | llama | 408-410 | Security | Unquoted `$LLAMA_EXTRA_ARGS` expansion |
| H-1 | HIGH | LlamaMenubarApp.swift | 1755,1879 | Race | `modelStates` accessed from multiple threads |
| H-3 | HIGH | LlamaMenubarApp.swift | 2744,2747 | Bug | `ps` regex fails on paths with spaces |
| H-4 | HIGH | LlamaMenubarApp.swift | 2528-2532 | Bug | `unloadAll` leaves stale state for external procs |
| H-5 | HIGH | install.sh + app | — | Bug | No single-instance check |
| M-1 | MEDIUM | LlamaMenubarApp.swift | 2549-2556 | Bug | Port not verified free before use |
| M-2 | MEDIUM | LlamaMenubarApp.swift | 1750 | Dead code | `pendingCtxEdit` unused |
| M-3 | MEDIUM | LlamaMenubarApp.swift | 1975-1983 | Dead code | `statusText` never used |
| M-4 | MEDIUM | LlamaMenubarApp.swift | 663-716 | Bug | Settings mirrors drift from UserDefaults |
| M-5 | MEDIUM | LlamaMenubarApp.swift | 2109-2123 | Perf | `cleanStalePerModelKeys` on main thread |
| M-6 | MEDIUM | LlamaMenubarApp.swift | 2181-2213 | Bug | No recursion depth limit (symlink loops) |
| M-7 | MEDIUM | LlamaMenubarApp.swift | 1897-1944 | Perf | Parent dir watch causes excessive refreshes |
| M-8 | MEDIUM | LlamaMenubarApp.swift | 2618-2633 | Bug | `parseArgs` doesn't handle escapes |
| M-11 | MEDIUM | llama | 428-436 | Bug | CLI 1s sleep race for process check |
| L-3 | LOW | LlamaMenubarApp.swift | 2583-2589 | Bug | Incomplete quantization stripping |
| L-6 | LOW | LlamaMenubarApp.swift | 1892-1895 | Perf | Missing `@ObservationIgnored` |
| L-7 | LOW | LlamaMenubarApp.swift, llama | 2797, 72 | Maintain | Hardcoded Python 3.14 path |
| L-8 | LOW | install.sh | 52, 89-91 | Bug | Missing source copy step |
| L-9 | LOW | install.sh | 233-250 | Feature | No crash recovery in LaunchAgent |
| L-10 | LOW | LlamaMenubarApp.swift | 1429-1434 | UX | Per-model "Save" is a no-op |
| L-12 | LOW | llama | 543 | Bug | Broken model name extraction in `cmd_unload all` |

---

## Positive Highlights

1. **Excellent comment quality** — Every non-trivial decision is documented with rationale.
2. **Zero force unwraps** — No crash-prone `!` operator usage anywhere.
3. **Proper weak self usage** — All closures, observers, and timers use `[weak self]` correctly.
4. **Proper deinit cleanup** — File descriptors closed, observers removed, timer cancelled.
5. **Pipe leak prevention** — The comment on lines 2458-2466 explains a real-world bug (pipe buffer fill) and the fix is correct (/dev/null redirect).
6. **Sleep/wake handling** — Thoughtful teardown/recreation of FD and timer around system sleep.
7. **Background `ps` scanning** — Moved off main thread to prevent UI freezes.
8. **Security-conscious** — Binds to localhost only, no shell injection in Process spawning.
