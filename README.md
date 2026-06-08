# LLM Switcher

A macOS menu bar app + CLI for managing local LLM models (GGUF and Apple MLX).

![LLM Switcher icon](assets/AppIcon.icns)

## What is this?

LLM Switcher is a native macOS app that lives in your menu bar (next to the clock). It lets you:

- 🔍 **Discover** GGUF and MLX models in a directory of your choice (recursive scan)
- ▶️ **Load** any model with one click (spawns the right backend: `llama-server` or `mlx_lm.server`)
- ⏹ **Unload** any model independently — no more "kill the wrong process" surprises
- 🔄 **Run multiple models simultaneously**, each on its own port (e.g. one chat model on :8080, an embedder on :8081)
- 🎨 **Auto-pair** `mmproj-*.gguf` projection files with their vision-capable base models
- ⚙️ **Tune per-model port, context size, and extra args** via a settings window
- 🔌 **Sync** with externally-launched servers (started by the companion CLI or by hand)
- 📁 **Show up in Launchpad, Spotlight, and `~/Applications/`** like a real Mac app

A companion shell command `llama` provides the same functionality from your terminal, and the two tools share state automatically.

## Screenshot

The menu bar app looks like this:

```
┌─────────────────────────────────┐
│  ◉ 2 models loaded              │
│  • gemma-4-12B-it [GGUF] :8080  │
│  • omnicoder-9b    [GGUF] :8081 │
│  ─────────────────────────────  │
│  ☐ cerebras_Qwen3...            │
│  ☑ gemma-4-12B-it     [GGUF] ●8080│
│  ☐ GLM-4.7-Flash...            │
│  ☑ omnicoder-9b        [GGUF] ●8081│
│  ─────────────────────────────  │
│  [Load Selected (2)]  [Clear]   │
│  ─────────────────────────────  │
│  [⏹ Unload All]  [↻ Refresh]   │
│  ─────────────────────────────  │
│  ● 2 on :8080, 8081             │
│  ─────────────────────────────  │
│  ⚙ Settings…                    │
│  Quit                            │
└─────────────────────────────────┘
```

## Quick start

### 1. Build & install

```bash
cd ~/Projects/LLM-Switcher
./scripts/install.sh
```

This will:
1. Compile `LlamaMenubarApp.swift` to a binary
2. Wrap it in `~/Applications/LLM Switcher.app`
3. Install the `llama` CLI to `~/bin/llama`
4. Install a LaunchAgent so the app starts at login
5. Register the app with Launch Services (so it shows in Launchpad/Spotlight)

### 2. Use it

**From the menu bar:**
- Click the ⚡ icon in your menu bar
- Tick the models you want → click "Load Selected"
- Click "⏹ Unload All" or right-click a model to unload it individually

**From the CLI:**

```bash
llama list                       # list all discovered models
llama load gemma                 # load one (fuzzy match)
llama load cerebras omnicoder    # load multiple
llama switch gemma               # unload all, load gemma
llama unload cerebras            # unload just cerebras
llama unload all                 # unload everything
llama status                     # show running models + ports
llama ctx gemma 8192             # set per-model ctx (applies next load)
llama port cerebras 9000         # set per-model port (0 = auto)
llama menubar                    # launch the menu bar app
llama help                       # full usage
```

**Recommended model directory layout** (configurable in Settings → Models Directory):
```
~/models/
├── gguf/                    # scanned recursively
│   ├── gemma-4-12B-it-Q4_K_M.gguf
│   ├── mmproj-gemma-4-12B-it-Q8_0.gguf   # auto-paired with gemma
│   ├── cerebras_Qwen3-Coder-25B-A3B-Q4_K_M.gguf
│   └── omnicoder-9b-q4_k_m.gguf
└── mlx/                     # one dir per model
    └── llama-3.2-3b/
        ├── config.json
        └── model.safetensors
```

The app **automatically excludes** these files from the model list (they're not standalone chat models):
- `mmproj-*.gguf` — vision projection, auto-paired with vision-capable base models
- `modernbert-embed-*.gguf` — embedding model used by the gbrain system

## Architecture

```
~/Projects/LLM-Switcher/
├── src/
│   ├── LlamaMenubarApp.swift     # the menu bar app (Swift + SwiftUI)
│   └── llama                     # the CLI (bash)
├── scripts/
│   ├── install.sh                # build & install
│   ├── uninstall.sh              # remove everything
│   └── make_icon.py              # generate the app icon
├── assets/
│   ├── AppIcon.icns              # compiled icon (1024x1024)
│   └── icon.iconset/             # source PNGs at all sizes
└── docs/
    ├── ARCHITECTURE.md           # how the pieces fit together
    └── STATE.md                  # where state lives
```

### How the pieces talk to each other

```
┌─────────────────────┐                  ┌─────────────────────┐
│  Menu bar app       │   UserDefaults    │  llama CLI           │
│  (Swift)            │ ◄──────────────► │  (bash)              │
│                     │   (same domain)   │                      │
└──────────┬──────────┘                  └──────────┬──────────┘
           │                                        │
           │  spawns  (each model = 1 process)      │
           ▼                                        ▼
   ┌───────────────┐                         ┌───────────────┐
   │ llama-server  │                         │ llama-server  │
   │ :8080  (PID)  │                         │ :8081  (PID)  │
   └───────────────┘                         └───────────────┘
           ▲                                        ▲
           │                                        │
           └────────── shared PID files in ─────────┘
                    ~/.local/share/llama-menubar/pids/
```

Both the menu bar app and the CLI can:
- **Start/stop** server processes (each model = one process on its own port)
- **Read settings** from `~/Library/Preferences/local.llama-menubar.plist` via the `defaults` command
- **See each other's processes** by parsing `ps` output and matching model paths

## Build

The Swift app requires macOS 13+ (uses `MenuBarExtra`, `@Observable`, `Settings` scene).

```bash
# Compile just the Swift source (manual, no bundle)
swiftc -parse-as-library -O \
    -framework SwiftUI -framework AppKit \
    src/LlamaMenubarApp.swift \
    -o llama-menubar

# Full build + install (recommended)
./scripts/install.sh
```

The `-parse-as-library` flag is **required** because we use `@main`; without it the compiler treats the file as a top-level script and rejects `@main`.

## Why a menu bar app?

Because that's the lightest-weight way to keep a tool always available on macOS without:
- Taking up dock space
- Showing up in Cmd-Tab
- Needing a main window
- Feeling heavy when you just want to toggle a model

`LSUIElement = true` in Info.plist is what makes the app a "true" menu bar app — invisible in the dock and app switcher.

## License

Personal use. Modify and redistribute freely.
