# Changelog

All notable changes to LLM Switcher are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-06-08

### Added
- **Menu bar app** (Swift/SwiftUI) for managing local LLM models
  - Recursive directory scan for GGUF and MLX models
  - Per-model load/unload with checkbox selection
  - Per-model port auto-assignment
  - Per-model context size configuration
  - Custom app icon (purple-to-blue gradient with neural-network motif)
  - Gradient menu bar icon (`bolt.fill`)
  - Two-tab settings window (Global / Per-Model)
  - Real-time directory watching (DispatchSource)
  - Cross-process state sync via `ps` (every 3s)
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
