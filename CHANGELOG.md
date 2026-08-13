# Changelog

All notable changes to LM Switcher are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] - 2026-08-13

### Fixed
- **CLI/MCP loads now honor the app's saved `defaultCtxSize`/`defaultPort`**
  — previously the CLI fell back to a hardcoded 4096 ctx (vs the app's
  65536), so MCP-driven loads silently launched at 4096 while menu-bar
  loads used the setting, and MCP swap-guard estimates diverged from the
  actual launch. Env overrides (`LLAMA_CTX_SIZE`/`LLAMA_PORT`) still win.
- **PID file migration shim** — pre-8250ec5 binaries wrote
  `$PIDS_DIR/<hash>.pid`; the current scheme is `<hash>.<basename>.pid`.
  `pidfile_for` now falls back to a legacy file holding a live PID, so
  servers loaded by an older CLI can still be `status`/`unload`ed after
  upgrading the binary.
- **MCP `readRunning` hash extraction** — `StateReader` parsed the pid
  file stem with `dropLast(4)`, which on the new `<hash>.<basename>.pid`
  naming produced a bogus hash (`<hash>.<basename>`), so `unload_model`
  reported "not running" and refused to stop the server. Now the hash is
  the first dot-separated component (handles both naming schemes).

## [1.4.0] - 2026-08-12

### Added
- **DFlash drafter support** — auto-detects a `dflash-*.gguf` companion
  (e.g. Muse Glimmer's `dflash-kquant.gguf`) next to a GGUF model and
  attaches `--spec-type draft-dflash --spec-draft-model <file>
  --spec-draft-n-max 15 --spec-draft-p-min 0.4`. New **DFlash** toggle in
  Settings → Global → Inference (default ON, skipped when no companion
  exists) plus a per-model override row. Mutually exclusive with MTP.
- **dflash-*.gguf exclusion** — drafter files no longer appear as
  standalone models in the menu bar, CLI (`llama list`), or MCP
  (`StateReader.discoverModels`).
- **Per-model `suppressReasoning` override** — reasoning suppression is
  no longer global-only; it can be flipped per model (Settings →
  Per-Model → Suppress reasoning, or `model.<hash>.suppressReasoning`).
  Required for Muse Glimmer, whose thinking leaks raw into content when
  `--reasoning off` is applied.
- **CLI honors per-model overrides** — new `pm()`/`pm_bool()` helpers in
  `src/llama` read `model.<hash>.<key>` first for temperature, topP,
  topK, repeatPenalty, kvCacheTypeK/V, thinkingEnabled,
  suppressReasoning, enableMtp, enableDflash (previously only port/ctx
  were per-model in the CLI). MCP loads (which shell out to the CLI) now
  behave like app loads.
- **DFlash-aware sampling** — `--top-p`/`--top-k`/`--repeat-penalty` are
  omitted when a DFlash drafter is attached (they skew the verification
  distribution and collapse block acceptance: measured 63% → 13%,
  25 → 7.5 t/s on Muse Glimmer). Temperature stays user-controlled.

### Fixed
- **Muse Glimmer speed trap** — q8_0/q4_0 KV cache costs ~23% on the
  muse-glimmer arch (7.4 vs 9.7 t/s); suppressReasoning garbles its
  output; the drafter was a net loss on open-ended prompts (7.5 vs 10
  t/s baseline) until `--spec-draft-p-min 0.4` was added so llama.cpp
  disengages the drafter adaptively. Documented in Help → Inference →
  DFlash and the hf-model-research reference.

## [1.3.0] - 2026-07-13

### Added
- **Redesign, phases 1–5** — the menu bar dropdown and Per-Model tab
  rebuilt around five focus areas:
  - *Discoverability*: hovering a running model reveals inline copy /
    pin / unload buttons (hovering a stopped model reveals load) —
    right-click keeps the full action list, including Switch to.
  - *Legibility*: model filenames are parsed into a clean display name
    with a monospaced quant chip (`Q4_K_M`, `Q8_0`, etc.); the raw
    filename moves to a tooltip. Agent access settings graduated from
    the Inference card into their own "Agent access (MCP)" card.
  - *Memory spine*: the old text memory line became a stacked bar at
    the top of the menu — system/other apps, each running model, free
    RAM — with a predictive ghost segment on hovering a stopped model
    showing whether it would fit before you click Load.
  - *Per-Model master-detail*: replaced the disclosure-group wall with
    a sidebar (running state + override-count badge) and a detail pane
    tagging every field OVERRIDE or GLOBAL, so customizations are
    visible without diffing against the Global tab by eye.
  - *Trust and speed*: an Agent Activity feed (clock icon) shows recent
    MCP loads/unloads; "Unload all" drops its would-be confirmation
    dialog in favor of a 5-second Undo; a type-to-filter field appears
    once the library passes 10 models.
- **TTL auto-unload** — optional "Idle unload (min)" setting stops GGUF
  models with no request activity (via llama-server's `/slots`
  endpoint), notifying when it happens. Off by default; pinned and MLX
  models are exempt.
- **Agent action notifications** — a macOS notification on every
  MCP-driven load/unload, toggleable independently of the Activity
  feed's history (the two used to be wrongly coupled — fixed here).
- **Smarter memory messaging** — the memory bar and Help now distinguish
  leftover swap during normal pressure (harmless, drains on its own)
  from swap under real memory pressure (actionable — unload something).
  Loading a model that's flagged "won't fit" shows a one-time toast
  estimating how much will go to swap before the load proceeds.
- **Copy endpoint** and a **first-run onboarding view** (engine check
  with a copyable install command, a Hugging Face link, and a folder
  picker) when no models are found yet.
- Help tab rewritten end-to-end: reorganized around what a new user is
  trying to do (getting started → everyday use → settings → tuning →
  agents → CLI → troubleshooting) instead of mirroring Settings' field
  order, with a plain-language line plus an optional technical detail
  line per entry, and a troubleshooting/glossary section.

### Fixed
- A model's error state now prints inline under the row instead of
  requiring a hover on a small warning icon.
- CLI `MODELS_DIR` now falls back to the app's saved Models Directory
  setting instead of a hardcoded `~/models`.

## [1.2.0] - 2026-07-12

### Added
- **Agent access (MCP)** — new standalone `lm-switcher-mcp` stdio server
  (MCP over newline-delimited JSON-RPC 2.0) lets agents (Hermes,
  Hermes, opencode…) list, load, unload, and switch models. Gated by the
  new **Agent access (MCP)** toggle (Settings → Global → Inference card,
  below MTP; OFF by default — every tool call is refused while OFF).
  Register with: `hermes mcp add lm-switcher --command ~/bin/lm-switcher-mcp`.
- **Swap guard** — agent loads that would exceed free RAM (minus a fixed
  OS headroom) are refused with the largest context size that would fit,
  unless the new **Allow swap for agent loads** toggle is ON. Footprint is
  estimated from the GGUF header / MLX config.json plus KV-cache math.
- **Model pinning** — right-click a running model → Pin. Agents cannot
  unload pinned models; the user's own Unload buttons are unaffected.
- **Ephemeral CLI overrides** — `llama load --ctx N --port N` beat saved
  per-model settings for that launch only and are never persisted (used
  by the MCP for per-call overrides).
- Help section 9 "Agent access (MCP)"; Mlock and No-mmap toggles surfaced
  in the Inference card; Help tab audited against the current UI.
- **TTL auto-unload** — Settings → Global → "Idle unload (min)": GGUF
  models with no request activity (observed via the server's /slots
  endpoint, launched with `--slots`) are auto-unloaded after the
  configured idle time, with a notification. Pinned and MLX models are
  exempt. Off by default.
- **Agent-action notifications** — the MCP logs successful loads/unloads
  to events.jsonl; the app posts a macOS notification per event
  ("Notify on agent actions" toggle, ON by default).
- **Copy endpoint** — right-click a running model → Copy endpoint puts
  `http://127.0.0.1:PORT/v1` on the clipboard.
- **Fit hint** — stopped models whose weights likely exceed current free
  RAM are dimmed in the dropdown (hover the badge for the explanation).
- **README** — new "Agent control (MCP)" section with the tool table and
  registration instructions.
- **Memory footer** — the menu dropdown shows "N GB free of M · pressure"
  (swap appears only when in use or pressure is elevated), refreshed every
  3 s while the panel is open, zero cost while closed. Hovering a running
  model's port shows that server's resident memory. `SystemMetrics.swift`
  is compiled into both the app and the MCP (the one deliberate exception
  to the no-shared-sources rule — read-only, no side effects).

### Removed
- r/hermesagent Reddit megathread link from the About page.

## [1.1.0] - 2026-06-29

### Added
- **MTP file exclusion** — `mtp-*.gguf` multi-token-prediction heads are
  excluded from the model list (loaded automatically by llama-server from
  model metadata). Only the `mtp-` prefix is excluded; `-mtp-` as an infix
  is treated as a normal model.
- **mmproj fallback matching** — when name-based matching fails, pair with
  any `mmproj-*.gguf` in the directory (handles QAT/generic naming like
  `mmproj-BF16.gguf`).
- **Chat Template Override** — configure a custom `.jinja`/`.json` template
  (Settings → Global, or `LLAMA_CHAT_TEMPLATE` for the CLI) for agentic
  harnesses that need custom tool-calling templates.
- **Gemma 4 reasoning suppression** — auto-applies
  `--reasoning off --reasoning-format none` (gated behind the
  `suppressReasoning` setting).
- Per-model port/context overrides, KV-cache quantization, flash attention,
  sampling, and performance settings; menu layout overhaul.

### Fixed
- **CLI `switch` never unloaded old models** — `cmd_switch` referenced an
  undefined `$PID_DIR` (typo for `$PIDS_DIR`), so the old-PID snapshot was
  always empty and `switch` just stacked a new model on top of the running
  ones.
- **CLI and app computed different per-model hashes** — `id_hash` used a
  here-string (`md5 -q <<< "$path"`), which appends a newline, so its digest
  never matched the app's MD5 of the raw path bytes. Per-model port/ctx set
  via the CLI were invisible to the app (and vice-versa). Switched to
  `md5 -q -s`.
- **App icon was never installed** — `install.sh` looked for the icon in
  `$BIN_DIR`, where nothing ever placed it; now sourced from
  `assets/AppIcon.icns`.
- **`uninstall.sh` left stale Swift sources** — only removed the legacy
  single-file `llama-menubar.swift`; now removes the whole multi-file module
  copied into `$BIN_DIR`.
- **`switchModel` froze the UI** — the readiness poll (up to 5s) ran on the
  main thread; moved to the background `syncQueue` with the final state
  mutation hopped back to main.

### Changed
- **CLI now matches the app's llama-server flags** — reads the shared
  `local.llama-menubar` settings (KV cache, flash attention, sampling,
  thinking, threads, batch, mlock/mmap) instead of hardcoding a small subset.
- **CLI mmproj quant-stripping** aligned with the Swift regex (now also
  strips I-quants and `F16/F32/BF16`).

## [1.0.1] - 2026-06-09

### Fixed
- **UI freeze after extended uptime** (the headline bug). Three issues
  were stacking to freeze the menu bar app:
  1. The 3-second `ps` reconciliation timer fired on the main run loop
     and called `Process.waitUntilExit()` + `readDataToEndOfFile()`
     there. A slow `ps` (large process table, sleep/wake races, NFS
     hiccups) blocked the main thread and the entire menu bar stopped
     responding. Moved the timer + spawn + pipe reads to a private
     background serial queue (`syncQueue`); state mutations are hopped
     back to main via `DispatchQueue.main.async`.
  2. The child server process (`llama-server` / `mlx_lm.server`) had
     its stdout/stderr wired to a `Pipe()` that the Swift app never
     read. The local `Pipe` reference went out of scope at the end of
     `loadModel`, the read end was closed, and the kernel pipe buffer
     (~64KB on macOS) filled the moment the child produced enough log
     output. The child's `write(2)` then blocked in the kernel and
     model loading froze silently (status said "loaded", server never
     served). Redirected child stdout/stderr to `/dev/null` via
     `FileHandle(forWritingAtPath:)`. The `llama` CLI continues to
     capture per-model log files as before.
  3. The reconciliation timer was never held or invalidated — leaking
     on every restart. Stored as `@ObservationIgnored private var
     syncTimer` and cancelled in `deinit` alongside the directory
     watcher.
- **`unloadAll` race condition**. After the refactor above, the
  `ps`-driven state merge ran asynchronously on the main queue, but
  `unloadAll` iterated over `modelStates` immediately after to send
  SIGTERM to external processes. External processes were never
  discovered before the loop. Extracted a synchronous
  `mergeExternalStates(_:)` helper and made `unloadAll` call
  `collectExternalStatesFromPS()` + `mergeExternalStates` inline.
- **Menu bar icon missing on macOS 26/Tahoe**. A custom `View` label
  (an `HStack` with a `LinearGradient` and a conditional `Text`) inside
  `MenuBarExtra` failed to register as an `NSStatusItem` on macOS 26:
  the app launched and stayed running, but the status bar item never
  appeared. Replaced the custom label with the simpler
  `Image(systemName:)` overload, which is reliably registered across
  macOS versions. The icon is now a solid `bolt.fill` (active) or
  `bolt` (inactive) SF Symbol.
- **Stale entries in `modelStates` / `processes`**. Entries for
  models that no longer exist on disk were never removed, causing the
  dictionaries to grow unboundedly over weeks of uptime. Added
  garbage-collection in `mergeExternalStates`.

### Changed
- Pre-existing corrupted type annotation (`var models: [URL>][ModelEntry]`)
  corrected to `[ModelEntry]` (the project did not compile before this
  fix).

### Verified
- Compiles cleanly with `swiftc -parse-as-library -O` (no warnings).
- Stress-tested continuously for several hours — no freeze.
- 30-second benchmark: app sits at 0.0-0.2% CPU with stable ~135 MB
  RSS while the timer fires every 3s.

## [1.0.0] - 2026-06-08

### Added
- **Menu bar app** (Swift/SwiftUI) for managing local LLM models
  - Recursive directory scan for GGUF and MLX models
  - Per-model load/unload with checkbox selection
  - Per-model port auto-assignment
  - Per-model context size configuration
  - Custom app icon (purple-to-blue gradient with neural-network motif)
  - Solid menu bar icon (`bolt.fill` when active, `bolt` when idle)
  - Two-tab settings window (Global / Per-Model)
  - Real-time directory watching (DispatchSource)
  - Cross-process state sync via `ps` (every 3s, off the main thread)
  - Auto-pairing of `mmproj-*.gguf` with vision-capable base models
  - Per-backend SF Symbols (GGUF: `doc.text`, MLX: `cpu`)
- **CLI** (`llama`, bash) with subcommands:
  - `list`, `load`, `unload`, `switch`, `status`
  - `ctx <model> <size>` — per-model context size
  - `port <model> <port>` — per-model port
  - `menubar`, `uninstall`, `help`
  - Recursive scan, fuzzy model matching
  - Per-model PID files in `~/.local/share/llama-menubar/pids/`
  - Per-model log files
  - Shared state with menu bar app via UserDefaults
- **Installer** (`install.sh`)
  - Compiles Swift to native binary
  - Creates `~/Applications/LM Switcher.app` bundle
  - Ad-hoc codesigning
  - Launch Services registration (Launchpad, Spotlight)
  - LaunchAgent for auto-start
- **Uninstaller** (`uninstall.sh`) — full cleanup
- **Icon generator** (`make_icon.py`) — procedural Python+Pillow
- **Per-model exclusion** of `mmproj-*` and `modernbert-embed-*` files
- **Multi-model concurrency** — each model gets its own process/port
- **Cross-tool sync** — CLI launches are detected by the menu bar app, and vice versa

### Notes
- Requires macOS 13+ (uses `MenuBarExtra`, `@Observable`, `Settings` scene)
- Universal binary (Apple Silicon + Intel)
- No external Swift dependencies (pure SwiftUI/AppKit)
- No external bash dependencies (just standard Unix tools + `defaults`)
