# LLM Switcher — Model Switching Handoff

**Date:** 2026-06-29
**Repo:** `/Users/rolandchia/Projects/llm-switcher`

---

## Current State

### Menu Bar App (Swift)

The menu bar app has NO "switch model" feature. It has:

- **Load** — spawns a new server process for a model (button in per-model card)
- **Unload** — terminates a single model's process (button in per-model card)
- **Unload All** — kills everything (⏹ button in menu dropdown)
- **Load Selected** — bulk load checked models

Multiple models can run simultaneously on different ports. There is no concept of "unload A then load B" as a single atomic action in the Swift app.

### CLI (bash)

The CLI (`~/bin/llama`) DOES have a switch command:

```bash
llama switch <model>
```

This unloads all running models, then loads the target. It's a sequential unload-all → load-one operation, not atomic (there's a gap between unload and load where no model is available).

**CLI switch implementation** (`src/llama`, `cmd_switch` function):
1. Calls `unload_all` (kills all running servers)
2. Calls `load_model` for the target
3. No rollback if load fails — user is left with zero running models

### What's Missing

1. **No switch in the menu bar UI** — user must manually unload one model, then load another
2. **No atomic switch** — CLI leaves a gap between unload and load
3. **No port reuse on switch** — switching to a new model on the same port requires the old process to fully exit first (SIGTERM is async)
4. **No error recovery** — if the new model fails to load, the old one is already dead

---

## Key Code Paths

### loadModel (`LlamaMenubarApp.swift:2275`)
```
loadModel(model)
  → checks if already running (early return)
  → resolves port (per-model override or nextAvailablePort)
  → resolves ctx size (per-model override or global default)
  → resolves all sampling params via pm() helper
  → builds args array (GGUF: -m, -ngl 99, --ctx-size, --cache-type-k/v, -fa, --temp, --top-p, etc.)
  → spawns Process()
  → sets modelStates[id] = ModelState(isRunning: true, pid: pid, port: port, ctxSize: ctx)
  → empty catch block (C-1 in audit — swallows spawn errors)
```

### unloadModel (`LlamaMenubarApp.swift:2491`)
```
unloadModel(model)
  → if processes[id] exists: Process.terminate() (sends SIGTERM)
  → else if modelStates[id].pid exists: kill(pid, SIGTERM)
  → clears modelStates[id].isRunning = false, pid = nil
```

### unloadAll (`LlamaMenubarApp.swift:2525`)
```
unloadAll()
  → for each owned process: unloadModel(m)
  → for each remaining running state (external): kill(pid, SIGTERM)
```

### Per-model override gate (`LlamaMenubarApp.swift:2284-2287`)
```swift
let overrides = perModelOverrideEnabled(for: model)
let preferredPort = overrides ? perModelPort(for: model) : 0
let port = preferredPort > 0 ? preferredPort : nextAvailablePort()
let ctx = overrides ? perModelCtxSize(for: model) : settings.defaultCtxSize
```

When override is OFF, port falls back to `nextAvailablePort()` and ctx to `settings.defaultCtxSize`.
All other settings (temp, topP, topK, repeatPenalty, kvCache, thinking, mtp, extraArgs) are gated by the `pm()` helper which checks `overrides && perModelSettingExists()`.

---

## Proposed: Switch Feature for Menu Bar App

### Design

Add a "Switch" action to each model row in the menu bar dropdown and per-model card. When clicked:

1. If target model is already running → no-op
2. Unload all currently running models (SIGTERM)
3. Wait for ports to be released (poll with short timeout)
4. Load the target model
5. If load fails → report error (fix C-1 first)

### Implementation approach

**Option A: Simple sequential (like CLI)**
```swift
func switchModel(_ model: ModelEntry) {
    // Unload everything
    unloadAll()
    // Wait briefly for ports to free (SIGTERM is async)
    Thread.sleep(forTimeInterval: 0.5)
    // Load target
    loadModel(model)
}
```
Simple but has a gap where no model is running. The 0.5s sleep is a hack.

**Option B: Graceful with port reuse**
```swift
func switchModel(_ model: ModelEntry) {
    guard !isRunning(model) else { return }
    
    // If only one model running, try to reuse its port
    let runningModels = models.filter { state(for: $0).isRunning }
    let reusePort = runningModels.count == 1 ? state(for: runningModels[0]).port : nil
    
    // Unload all
    unloadAll()
    
    // Wait for processes to exit (max 2s)
    let deadline = Date().addingTimeInterval(2.0)
    while Date() < deadline {
        let anyRunning = models.contains { state(for: $0).isRunning }
        if !anyRunning { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    
    // Load target (reuse port if available)
    if let port = reusePort {
        // Temporarily set per-model port
        setPerModelPort(port, for: model)
    }
    loadModel(model)
}
```

**Option C: Atomic (double-buffer)**
- Start the new model on a different port first
- Once confirmed running, unload the old model
- No gap, but requires 2x memory briefly
- Best UX but most complex

### UI changes needed

1. **Menu dropdown** — add a "Switch to" action per model row (maybe a context menu or a ⟳ button)
2. **Per-model card** — add a "Switch" button next to Load/Unload
3. **Status indicator** — show "Switching..." during the transition
4. **Error handling** — show a message if the new model fails to load (requires C-1 fix)

### Dependencies (fix first)

| Audit ID | Issue | Why it blocks switching |
|----------|-------|----------------------|
| C-1 | Empty catch block swallows spawn errors | Switch has no error feedback if new model fails to load |
| H-4 | unloadAll leaves stale state | Switch relies on clean unload before load |
| M-1 | Port not verified free | Switch needs the old port freed before reuse |

---

## File Locations

| File | Path | Purpose |
|------|------|---------|
| Swift source | `src/LlamaMenubarApp.swift` | Entire app (~2984 lines) |
| CLI | `src/llama` | Bash CLI with `switch` command |
| Install | `scripts/install.sh` | Build + install pipeline |
| Build source copy | `~/bin/llama-menubar.swift` | Where install.sh compiles from |
| Binary | `~/Applications/LLM Switcher.app/Contents/MacOS/llama-menubar` | Installed binary |
| Plist | `~/Library/LaunchAgents/local.llama-menubar.plist` | Auto-start on login |
| Gitea | `http://localhost:3000/admin/llm-switcher.git` | Origin remote |

## Build & Deploy Flow

```bash
# 1. Edit source
vim ~/Projects/llm-switcher/src/LlamaMenubarApp.swift

# 2. Copy to ~/bin (install.sh compiles from here, NOT from src/)
cp src/LlamaMenubarApp.swift ~/bin/llama-menubar.swift

# 3. Kill running instance
pkill -f llama-menubar

# 4. Build + install
cd ~/Projects/llm-switcher && bash scripts/install.sh

# 5. Launch
open ~/Applications/LLM\ Switcher.app

# 6. Verify changes in binary
strings ~/Applications/LLM\ Switcher.app/Contents/MacOS/llama-menubar | grep "search string"

# 7. Push to Gitea
cd ~/Projects/llm-switcher && git add -A && git commit -m "msg" && git push
```
