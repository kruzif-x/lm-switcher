# Architecture

This document describes the runtime architecture of LLM Switcher: how the
components fit together, what each one is responsible for, and how they
communicate.

## High-level view

```
                  ┌─────────────────────────────────────────────┐
                  │   User (clicks menu bar or runs CLI)        │
                  └────────────────────┬────────────────────────┘
                                       │
                  ┌────────────────────┴────────────────────────┐
                  │                                             │
           ┌──────▼──────┐                              ┌───────▼──────┐
           │  Menu bar   │                              │   CLI        │
           │  app        │                              │  (llama)     │
           │  (Swift)    │                              │  (bash)      │
           └──────┬──────┘                              └───────┬──────┘
                  │                                            │
                  │   shared UserDefaults (local.llama-menubar) │
                  │ ◄──────────────────────────────────────────►│
                  │                                            │
                  │   shared PID files in                       │
                  │   ~/.local/share/llama-menubar/pids/        │
                  │ ◄──────────────────────────────────────────►│
                  │                                            │
                  ▼                                            ▼
            ┌────────────────────────────────────────────────────────┐
            │  llama-server / mlx_lm.server processes                │
            │  (one per model, each on its own port)                 │
            └────────────────────────────────────────────────────────┘
```

The two user-facing tools (menu bar app + CLI) are *peers* — neither
owns the other, and either can launch/kill server processes. They
coordinate by reading each other's state from disk.

## Process model

Each model is **one** `llama-server` (or `mlx_lm.server`) process:

```
                 ┌─────────────────────────────────────────┐
                 │  ServerManager (in Swift)                │
                 │  models: [gemma, cerebras, omnicoder]   │
                 └────────────────┬────────────────────────┘
                                  │ loadModel(_:)
                                  ▼
        ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
        │  llama-server    │  │  llama-server    │  │  llama-server    │
        │  -m gemma.gguf   │  │  -m cerebras...  │  │  -m omnicoder..  │
        │  --port 8080     │  │  --port 8081     │  │  --port 8082     │
        │  --ctx-size 4096 │  │  --ctx-size 8192 │  │  --ctx-size 4096 │
        │  --reasoning off │  │  --reasoning off │  │  --reasoning off │
        │  PID 1234        │  │  PID 1235        │  │  PID 1236        │
        └──────────────────┘  └──────────────────┘  └──────────────────┘
```

**Why one process per model?** Because llama-server can't run multiple
distinct models in a single instance (each model is loaded into GPU
memory once and bound to that process). And it allows independent
unload of any model without affecting the others.

Note: every GGUF model is launched with `--reasoning off --reasoning-format
none` to suppress Gemma 4's `reasoning_content` field, which breaks
OpenAI-compatible clients. See [GEMMA4_LOADING_DETAILS.md](GEMMA4_LOADING_DETAILS.md)
for a full flag-by-flag explanation.

## Communication paths

### 1. Settings (UserDefaults)

Both the Swift app and the bash CLI read/write settings under the
`local.llama-menubar` domain:

```bash
# From bash:
defaults read local.llama-menubar modelsDir
defaults write local.llama-menubar "model.3962161681452358307.port" -int 9000
```

```swift
// From Swift:
let d = UserDefaults.standard
let port = d.integer(forKey: "model.3962161681452358307.port")
```

This is why the menu bar app and the CLI stay in sync. They don't
talk to each other directly — they both read/write the same plist.

### 2. PID files (one per model)

When a server is started, the manager writes a PID file at
`~/.local/share/llama-menubar/pids/<safe-name>.pid`. The first
line is the PID; the second line is `PID --port N` for fast port
recovery without re-scanning `ps`.

Example PID file for a model loaded as `/Users/foo/gguf/gemma.gguf`:
```
1234
1234 --port 8080
```

### 3. Process detection (`ps`)

Every 3 seconds, the menu bar app runs `ps -ax -o pid=,command=` and
parses out any `llama-server` / `mlx_lm.server` processes. This lets
the menu bar app show models that were launched by the CLI (or by
hand, or by another tool). It also clears "stale" state for models
that have died.

This is the same mechanism the CLI uses (lazily, on `status` calls).

## Component responsibilities

### `LlamaMenubarApp.swift`

| Type | Responsibility |
|---|---|
| `LlamaMenubarApp` | `@main` entry point. Holds the singleton `ServerManager` and `SettingsWindowHost`. Declares the `MenuBarExtra` scene. |
| `SettingsWindowHost` | Manages the lifecycle of the settings `NSWindow`. Necessary because SwiftUI's `Settings` scene doesn't work in menu-bar-only apps. |
| `MenuView` | The dropdown menu content (model list, status, buttons, settings link, quit). |
| `SettingsView` | Two-tab settings window (Global / Per-Model). |
| `ServerManager` | The brain. Owns model discovery, lifecycle, state, settings persistence, directory watching, and external-process sync. Marked `@Observable` so views auto-rerender. |
| `ModelBackend` | Enum: `.gguf` or `.mlx`. Each backend has its own launch command and SF Symbol. |
| `ModelEntry` | A discovered model (immutable value type). |
| `ModelState` | Per-model runtime state (isRunning, pid, port, ctx). |
| `AppSettings` | Persisted global settings. |

### `llama` (bash CLI)

| Function | Responsibility |
|---|---|
| `list_all_models` | Recursive scan of `$LLAMA_MODELS_DIR`, emit `TYPE\|PATH\|NAME` lines. |
| `resolve_query` | Fuzzy-match a user query to a single model. |
| `is_loaded`, `get_port_for` | Read PID files to determine state. |
| `per_model_port`, `per_model_ctx` | Read per-model overrides from `defaults`. |
| `id_hash` | Stable short hash of a model path (for PID filenames and `defaults` keys). |
| `next_port` | Find the smallest unused port starting at `$LLAMA_PORT`. |
| `load_model` | Spawn the right backend with the right args. |
| `unload_model` | SIGTERM (then SIGKILL after 1s) one process. |
| `cmd_*` | One per subcommand (`list`, `status`, `load`, `unload`, etc.). |

## Lifecycle

```
   install.sh                            user logs in
       │                                       │
       ▼                                       ▼
  ┌─────────────┐   launchctl    ┌────────────────────────┐
  │  Compile    │  ───────────►  │  LaunchAgent starts     │
  │  Bundle .app│                │  ~/Applications/...     │
  │  Sign + reg │                │  /Contents/MacOS/...    │
  └─────────────┘                └────────────────────────┘
                                          │
                                          ▼
                                ┌────────────────────────┐
                                │  LlamaMenubarApp runs   │
                                │  - loads settings       │
                                │  - scans ~/models       │
                                │  - starts FS watcher    │
                                │  - 3s sync timer        │
                                │  - waits for clicks     │
                                └────────────────────────┘
                                          │
                  ┌───────────────────────┼──────────────────────┐
                  │                       │                      │
              user clicks              user clicks         user clicks
              "Load Selected"          "⚙ Settings…"       "Quit"
                  │                       │                      │
                  ▼                       ▼                      ▼
            ┌──────────┐          ┌────────────────┐         ┌──────────┐
            │  spawn   │          │  show NSWindow │         │  SIGTERM │
            │  process │          │  (floating)    │         │  all     │
            │  write   │          └────────────────┘         │  quit    │
            │  PID file│                                     └──────────┘
            └──────────┘
```

## Why is the menu bar app written in Swift, not bash?

Because menu bar apps need:
- A real GUI toolkit (AppKit, NSWindow, NSOpenPanel)
- A SwiftUI scene (`MenuBarExtra`) for the menu
- An `Info.plist` with `LSUIElement=true` to hide from the dock

Bash can do none of these. Swift gives us:
- A single-binary executable (no interpreter)
- Direct access to `Process`, `UserDefaults`, `DispatchSource`
- SwiftUI declarative UI
- Native performance (no shell startup cost)

The CLI is bash because:
- The user invokes it from a shell anyway
- File I/O + `defaults` + process management are easy in bash
- Zero dependencies (just standard Unix tools + `defaults`)

## Extending

### Add a new backend (e.g. Ollama)

1. Add a case to `ModelBackend` in Swift:
   ```swift
   case ollama = "Ollama"
   var sfSymbol: String {
       switch self {
       case .gguf: return "doc.text"
       case .mlx: return "cpu"
       case .ollama: return "wand.and.stars"
       }
   }
   ```
2. Add a case in `ServerManager.loadModel(_:)` for the new backend.
3. Add a config field in `AppSettings` (e.g. `ollamaServerPath`).
4. Add a CLI detection in `list_all_models` and `load_model`.

### Add a new per-model attribute

1. Add a field to `ModelState` in Swift.
2. Add a getter/setter in `ServerManager` that uses `UserDefaults`.
3. Add a row in `SettingsView.modelsPane` and `perModelRow(for:)`.
4. Add a CLI command (e.g. `llama ctx <model> <size>` → set ctx, persist to defaults).
