# LLM Switcher — Project Handoff

## What This Is

macOS menu bar app for managing local LLM models (GGUF + MLX). Single Swift file, ~3000 lines. Written by Roland Chia. Version 1.1.0.

## Repo

- **Local:** `/Users/rolandchia/Projects/llm-switcher`
- **Gitea:** `http://localhost:3000/admin/llm-switcher.git` (origin)
- **Arrakis:** `http://192.168.1.244:3000/polaris/llm-switcher.git` (remote: `arrakis`, push here too)

## File Structure

```
llm-switcher/
├── src/
│   ├── LlamaMenubarApp.swift   # entire app (~3000 lines)
│   └── llama                    # bash CLI companion (~680 lines)
├── scripts/
│   └── install.sh               # build + .app bundle + LaunchAgent
├── AUDIT_REPORT.md              # scout audit (30 findings)
├── HANDOFF_PERMODEL_FIX.md      # per-model override fix history
└── HANDOFF_MODEL_SWITCHING.md   # switch feature design options
```

## Build & Deploy

**Critical:** `install.sh` compiles from `~/bin/llama-menubar.swift`, NOT from `src/`. You must copy the source first.

```bash
# Edit source
vim ~/Projects/llm-switcher/src/LlamaMenubarApp.swift

# Copy to ~/bin (install.sh compiles from here)
cp src/LlamaMenubarApp.swift ~/bin/llama-menubar.swift

# Kill running instance
pkill -f llama-menubar; sleep 1

# Build + install
cd ~/Projects/llm-switcher && bash scripts/install.sh

# Launch
open ~/Applications/LLM\ Switcher.app

# Verify binary has your changes
strings ~/Applications/LLM\ Switcher.app/Contents/MacOS/llama-menubar | grep "your string"

# Push to Gitea
git add -A && git commit -m "msg" && git push
```

## Architecture

| Component | Description |
|-----------|-------------|
| `LlamaMenubarApp` | @main entry. MenuBarExtra scene, holds ServerManager + SettingsWindowHost |
| `SettingsWindowHost` | Manages NSWindow lifecycle for settings (MenuBarExtra can't use Settings scene) |
| `MenuView` | Dropdown menu: model list, load/unload buttons, status, settings/help/about/quit |
| `SettingsView` | 4-tab window: Global, Per-Model, Help, About. Uses @State mirrors + onChange handlers |
| `ServerManager` | God object: model discovery, process lifecycle, settings persistence, ps sync, file watching, sleep/wake |
| `ModelEntry` | Value type: id (absolute path), name, path URL, backend (.gguf/.mlx) |
| `ModelState` | Runtime state: isRunning, pid, port, ctxSize |
| `AppSettings` | Persisted global settings (struct, saved to UserDefaults) |

## Key Patterns

- **`@Observable`** on ServerManager — SwiftUI views auto-redraw on property changes
- **UserDefaults** for all persistence — global settings under direct keys, per-model under `model.<md5hash>.<key>`
- **`refreshTrigger: Int`** — bumped to force re-render of per-model UI (reads from UserDefaults don't trigger @Observable)
- **`let _ = manager.refreshTrigger`** at top of `perModelOverrideFields()` — creates SwiftUI dependency so if/else re-evaluates on toggle/reset
- **`[weak self]`** in all closures, timers, observers — no retain cycles
- **`syncQueue`** (serial DispatchQueue) for background `ps` scanning
- **Process spawning** uses `Process()` with arguments array — no shell, safe from injection
- **`@State` mirrors** in SettingsView — local copies of settings synced via onChange handlers (verbose but works around SwiftUI type-checker limits)

## Per-Model Override System

```
perModelOverrideEnabled(for: model)  → Bool from UserDefaults
perModelKey("port", model: model)    → "model.<12hex>.port"
perModelSetting(key, default, model) → generic getter, falls back to global
setPerModelSetting(value, model, key) → writes to UserDefaults
resetPerModel(for: model)             → removes ALL per-model keys
```

In `loadModel`, the `overrides` flag gates ALL per-model reads:
```swift
let overrides = perModelOverrideEnabled(for: model)
let preferredPort = overrides ? perModelPort(for: model) : 0
let port = preferredPort > 0 ? preferredPort : nextAvailablePort()
let ctx = overrides ? perModelCtxSize(for: model) : settings.defaultCtxSize
// Then pm() helper: if overrides && keyExists, use per-model; else global
```

UI: when override OFF → read-only global values. When ON → editable fields + "Reset to Global" + "Reset to Default". Both buttons always visible.

## Current Audit Findings (from AUDIT_REPORT.md)

30 findings total. The ones most likely to bite you:

| ID | Sev | File:Line | Issue |
|----|-----|-----------|-------|
| C-1 | CRITICAL | :2483 | Empty catch block — Process.run() failures silently swallowed (wrong binary path = no feedback) |
| C-2 | CRITICAL | llama:408 | Unquoted $LLAMA_EXTRA_ARGS — command injection risk |
| H-1 | HIGH | :1755,1879 | modelStates/processes dicts accessed from multiple threads without sync |
| H-3 | HIGH | :2744 | ps regex fails on model paths with spaces |
| H-4 | HIGH | :2528 | unloadAll leaves stale state for externally-launched processes |
| H-5 | HIGH | install.sh | No single-instance check — two instances collide on ports |
| M-6 | MEDIUM | :2181 | No recursion depth limit on model scan (symlink loops hang) |
| L-8 | LOW | install.sh:52 | install.sh doesn't copy src→bin (must do manually, see Build section) |

## Pending Work

1. ~~**Fix audit findings** — C-1, C-2, H-1, H-3, H-4, H-5~~ ✅ DONE (commit e0c6568, 2026-06-29).
2. ~~**Model switching** — menu bar app has no "switch"~~ ✅ DONE (commit bf8e2d?, 2026-06-29). Double-buffer atomic switch: loads new model on fresh port first, verifies readiness (5s timeout), then unloads old models. Rollback on failure. UI: "Switch" button in per-model card + "Switch to" in context menu. CLI: same double-buffer pattern.
3. ~~**Dead code cleanup** — `pendingCtxEdit`, `statusText`, `ModelState.extraArgs`~~ ✅ DONE (M-2, M-3, L-11 removed).
4. ~~**Remaining MEDIUM/LOW** — M-1 (port bind), M-5 (key filtering), M-6 (depth limit), M-8 (escape handling), L-2 (numeric sort), L-3 (regex quant), L-6 (@ObservationIgnored), L-7 (Python detect)~~ ✅ DONE.
5. **File splitting** — ~3200 lines in one file. Suggested split in audit report section A-1.

## User Preferences

- Prefers concise, table-formatted output
- "Porting" not "stealing" when adopting patterns from external tools
- Hands-on infra manager — does own reinstalls
- SwiftUI type-checker limit: Form with >5 onChange or >8 sections times out. Fix: split into computed properties + ViewModifier structs
- Toggle labels: short, no colons, ON/OFF colored indicator
- Per-model: model.<hash>.<key> UserDefaults, String(format:%d) no commas, refreshTrigger for render
- MTP off (Metal net loss). -ngl 99 auto. KV q8_0/q4_0 defaults
- Author: Roland Chia, z3r09er@gmail.com
