# LM Switcher — Project Handoff

## 2026-08-12 — DFlash drafter + per-model reasoning suppression (v1.4.0)

Shipped in this session:
- **DFlash support**: auto-attach `dflash-*.gguf` companions
  (`--spec-type draft-dflash --spec-draft-model <file> --spec-draft-n-max
  15 --spec-draft-p-min 0.4`), `enableDflash` setting (default true),
  Settings toggle + per-model override row, Help entries.
- **dflash-*.gguf exclusion** in all three discovery surfaces (Swift
  `ggufEntry`, CLI `list_all_models`, MCP `StateReader.discoverModels`).
- **Per-model `suppressReasoning`** (Settings row + `pm()` in loadModel).
- **CLI per-model overrides**: `pm()`/`pm_bool()` helpers now make the
  CLI (and MCP loads, which shell out to it) honor all `model.<hash>.*`
  keys, not just port/ctx.
- **DFlash-aware sampling**: top-p/top-k/repeat-penalty omitted when a
  drafter is attached.

Measured findings baked into the code/docs (Muse Glimmer, M2 Max):
- top-p/top-k collapse DFlash acceptance 63% → 13% (25 → 7.5 t/s).
- Acceptance is prompt-dependent (structured 60-79%, open-ended 13%
  during reasoning); `--spec-draft-p-min 0.4` disengages adaptively.
- q8_0/q4_0 KV cache costs ~23% on muse-glimmer; use f16/f16 per-model.
- `--reasoning off` garbles Muse output; needs per-model
  suppressReasoning OFF.

Per-model overrides live for Muse Glimmer under `model.402d4751948a.*`
(KV f16/f16, suppressReasoning 0, temperature 0).

## What This Is

macOS menu bar app for managing local LLM models (GGUF + MLX). Swift (~5000 lines across 5 files) + bash CLI (~710 lines). Written by Roland Chia. Version 1.4.0.

**What it does:** discovers `.gguf` files and MLX model directories under a configurable path, spawns `llama-server` (GGUF) or `mlx_lm.server` (MLX) processes — one per model on its own port — tracks PIDs/ports/context, reconciles with externally-launched processes via `ps`, persists settings to UserDefaults, watches the models directory for live changes, and handles macOS sleep/wake.

## Repo

- **Local:** `/Users/rolandchia/Projects/llm-switcher`
- **Gitea origin:** `http://localhost:3000/admin/llm-switcher.git`
- **Arrakis:** `http://192.168.1.244:3000/polaris/llm-switcher.git` (remote: `arrakis`)

## File Structure

```
lm-switcher/
├── src/
│   ├── LlamaMenubarApp.swift   # @main MenuBarExtra + SettingsWindowHost ~205 lines
│   ├── DomainTypes.swift        # ModelBackend, ModelEntry, ModelState, AppSettings
│   ├── MenuView.swift           # menu bar dropdown ~280 lines
│   ├── SettingsView.swift       # 4-tab settings window (~1250 lines)
│   ├── ServerManager.swift      # the brain: discovery, lifecycle, sync (~1500 lines)
│   └── llama                    # bash CLI companion (~710 lines)
├── scripts/
│   └── install.sh               # build (multi-file) + .app bundle + LaunchAgent
├── AUDIT_REPORT.md              # scout audit (30 findings — all actionable fixed)
├── HANDOFF_PERMODEL_FIX.md      # history
├── HANDOFF_MODEL_SWITCHING.md   # design options (implemented)
└── HANDOFF.md                   # this file
```

The Swift app was split from a single ~3250-line file into 5 files (commit b707b69). They compile together as one module via `swiftc src/*.swift`.

## Architecture

| Component | Role |
|-----------|------|
| `LlamaMenubarApp` | `@main` — MenuBarExtra scene, holds ServerManager + SettingsWindowHost |
| `SettingsWindowHost` | Manages NSWindow lifecycle (MenuBarExtra can't use Settings scene) |
| `MenuView` | Dropdown menu: model list (checkbox/status per row), bulk actions (Load/Unload Selected + Clear), status line, Settings/Help/About/Quit footer |
| `SettingsView` | 4 tabs: Global, Per-Model, Help, About. `@State` mirrors + onChange → UserDefaults |
| `ServerManager` | `@Observable` class — model discovery + scan, process lifecycle (load/unload/switch), UserDefaults persistence, per-model settings, 3s `ps` sync timer, DispatchSource file watcher, sleep/wake observers, port allocation with bind() probe |
| `ModelEntry` | Value: id (abs path), name, path URL, backend (.gguf/.mlx) |
| `ModelState` | Runtime: isRunning, pid, port, ctxSize, lastError |
| `AppSettings` | Persisted global settings struct |
| `ModelBackend` | Enum: .gguf or .mlx, each with sfSymbol + launch handler |

## Build & Deploy

```bash
# Edit source in src/
vim ~/Projects/llm-switcher/src/ServerManager.swift

# Type-check all files (fast — returns in ~1s)
swiftc -parse-as-library -typecheck -framework SwiftUI -framework AppKit src/*.swift

# Kill running instance
pkill -f lm-switcher; sleep 1

# Build + install (copies src/*.swift → ~/bin, compiles as one module)
cd ~/Projects/llm-switcher && bash scripts/install.sh

# Launch (or restart the LaunchAgent: launchctl kickstart -k gui/$(id -u)/local.llama-menubar)
open ~/Applications/LM\ Switcher.app

# Verify symbol in binary
nm ~/Applications/LM\ Switcher.app/Contents/MacOS/lm-switcher \
  | grep -i "switchModel\|portIsFree\|unloadSelected"

# Push to Gitea
cd ~/Projects/llm-switcher \
  && git add -A && git commit -m "msg" \
  && git push origin main && git push arrakis main
```

`install.sh` copies `src/*.swift` → `~/bin/`, compiles them together, wraps in `.app` bundle, signs (inner binary first, then bundle), registers with Launch Services, installs CLI from `src/llama`, and writes LaunchAgent.

## Key Patterns

- **`@Observable`** on ServerManager — SwiftUI auto-redraws.
- **UserDefaults** for all persistence. Global under direct keys, per-model under `model.<md5hash>.<key>`.
- **`refreshTrigger: Int`** — bumped to force per-model UI re-render (UserDefaults writes don't trigger @Observable).
- **`let _ = manager.refreshTrigger`** at top of `perModelOverrideFields()` — creates SwiftUI dependency.
- **`[weak self]`** in all closures/timers/observers — no retain cycles. Verified by audit.
- **`syncQueue`** (serial DispatchQueue) for background `ps` scanning. Also used by onWake (H-1 fix).
- **`selected: Set<String>`** — the checkbox set. Running models auto-inserted on load/switch/external-discovery; removed on unload/stale-clear. Drives both Load Selected and Unload Selected.
- **`switchingTo: String?`** — model ID being switched to (disabled UI during transition).
- **`processes`** dict tracks `Process` objects we spawned; `modelStates` tracks all runtime state.
- **Process spawn** uses `Process()` with arguments array — no shell injection.
- **@State mirrors** in SettingsView — local copies of persisted settings, synced via onChange handlers. Now also debounced-on-receive of UserDefaults change notifications (M-4).

## Per-Model Override System

```
perModelOverrideEnabled(for:)     → Bool
perModelKey("port", model:)       → "model.<12hex>.port"
perModelSetting(key, default, model:) → generic getter
setPerModelSetting(value, model, key:) → writes UserDefaults
resetPerModel(for:)               → removes ALL per-model keys
```

In `loadModel`: the `overrides` flag gates per-model reads. When OFF, `nextAvailablePort()` and global defaults are used. UI: OFF → read-only global values. ON → editable fields + "Reset to Global" + "Reset to Default" (override-aware — writes factory defaults when ON, purges keys when OFF).

## Menu Bar Dropdown Controls

| Control | What it does |
|---------|-------------|
| Load Selected (N) | Loads the stopped models you've ticked |
| Unload Selected (N) | Stops the running models you've ticked (appears when 2+ loaded) |
| Clear | Deselects everything |
| ⏹ Unload All | Stops every running model |
| ↻ Refresh | Re-scans the models directory |
| Right-click a model | Load / Unload / Switch to (atomic) |
| Per-model card Switch | Double-buffer switch (appears when any other model running) |

## CLI Commands

| Command | Description |
|---------|-------------|
| `llama list` | List all discovered models |
| `llama load <name>` | Load by fuzzy name match |
| `llama unload <name...>|all` | Unload one/more/all |
| `llama switch <name>` | Atomic switch (load first, verify, then unload old) |
| `llama status` | Show running models with ports |
| `llama ctx <size>` | Set per-model context size |
| `llama port <num>` | Set per-model port |
| `llama menubar` | Launch the menu bar app |

## Fixed Bugs — All Sessions (Commit History)

| Commit | What was fixed |
|--------|---------------|
| `e0c6568` | C-1 (empty catch → lastError + beep + warning triangle), C-2 (unquoted EXTRA_ARGS → read -ra), H-1 (concurrent ps → syncQueue), H-3 (ps regex paths with spaces), H-4 (unloadAll stale state), H-5 (flock single-instance guard), per-model reset override-aware |
| `94eaed6` | M-1 (bind() port probe), M-2 (pendingCtxEdit), M-3 (statusText), M-5 (key filtering), M-6 (depth limit), M-8 (backslash escapes), L-2 (numeric sort), L-3 (regex quant strip), L-6 (@ObservationIgnored), L-7 (discoverMLXServerPath), L-11 (extraArgs) + atomic model switching (Swift switchModel + CLI cmd_switch double-buffer) |
| `b707b69` | A-1 file split (3250→5 files), selectable multi-model unload (unloadSelected + runningCount + selected auto-tracking), install.sh multi-file build + L-8 fix (src copy) |
| `6e91f8e` | M-4 (mirror drift → debounced UserDefaults observer), M-7 (file watcher debounce 0.3s), M-11 (CLI sleep → port poll 15s), L-9 (KeepAlive SuccessfulExit=false), L-10 (fake per-model Save removed), L-12 (cmd_unload all mname), B-3 (version 1.1.0 + NSHumanReadableCopyright), B-4 (--deep → binary-then-bundle sign) |
| `5dd720d` | Checkbox won't uncheck (dropped `|| state.isRunning`), ~/models placeholder removed, **ps pipe deadlock** (read pipe before waitUntilExit — was blocking every 3s sync), symlink skip in scanDirectory |

## CRITICAL: ps Sync Pipe Deadlock (found & fixed 2026-06-29)

**Root cause of "running models show as stopped":** `collectExternalStatesFromPS()` called `task.waitUntilExit()` **before** `readDataToEndOfFile()`. `ps -ax` on a real system produces ~772 lines (>64KB), filling the kernel pipe buffer. `ps` blocks on `write(2)` waiting for the pipe to be drained. `waitUntilExit()` deadlocks waiting for `ps` to exit. Result: every 3s sync tick hangs; running models are never detected. **Do NOT revert the ordering.** 

Proven with standalone test:
```
NEW (read-then-wait):  772 lines, 2 llama-server matches  ✓
OLD (wait-then-read):  hung >8s — pipe-buffer deadlock      ✗
```

## Single-Instance Guard (H-5)

`ServerManager.acquireSingleInstanceLock()` uses `flock(LOCK_EX | LOCK_NB)` on `/tmp/lm-switcher.lock`. Second instance self-terminates. Verified live.

## Known Issues / Deferred

The 30-audit-finding report is fully resolved except for items the audit itself reclassified as non-defects:
- **H-2** (informational: override gates correctly implemented for exposed settings)
- **M-9** (MLX safetensors heuristic — reasonable)
- **M-10** (CLI PID file check — bash `&&...||` idiom works correctly)

And these design-level items left untouched:
- **M-7 approach** (parent-dir watch) — debounced (300ms) rather than switched to FSEvents. Functional but still fires on parent-dir noise.
- **Settings `@State` mirror pattern** — verbose but works around SwiftUI type-checker limits. Documented.

## User Preferences

- Prefers concise, table-formatted output
- "Porting" not "stealing" when adopting patterns
- Hands-on infra — does own reinstalls
- SwiftUI type-checker limit: Form with >5 onChange or >8 sections times out. Fix: computed properties + ViewModifier structs
- Toggle labels: short, no colons, ON/OFF colored
- Per-model settings: `model.<hash>.<key>`, String(format:%d) no commas, refreshTrigger
- MTP ON by default (auto-detected per model). -ngl 99 auto. KV q8_0/q4_0 defaults
- Author: Roland Chia, z3r09er@gmail.com
