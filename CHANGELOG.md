# Changelog

All notable changes to LLM Switcher are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
  - Creates `~/Applications/LLM Switcher.app` bundle
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
