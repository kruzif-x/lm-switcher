# LLM Switcher

A macOS menu bar app + CLI for managing local LLM models (GGUF and Apple MLX).

![LLM Switcher icon](assets/AppIcon.icns)

## What is this?

LLM Switcher is a native macOS app that lives in your menu bar (next to the clock). It lets you:

- 🔍 **Discover** GGUF and MLX models in a directory of your choice (recursive scan)
- ▶️ **Load** any model with one click (spawns the right backend: `llama-server` or `mlx_lm.server`)
- ⏹ **Unload** any model independently — no more "kill the wrong process" surprises
- 🔄 **Run multiple models simultaneously**, each on its own port (e.g. one chat model on :8080, an embedder on :8081)
- 🎨 **Auto-pair** `mmproj-*.gguf` projection files with their vision-capable base models (with fallback matching for QAT/generic naming)
- 🧠 **MTP exclusion** — `mtp-*.gguf` encoder files are excluded from the model list; loaded automatically by llama-server
- 📝 **Chat Template Override** — configure a custom `.jinja` or `.json` template for agentic harnesses (opencode, pi)
- 🤖 **Gemma 4 ready** — auto-applies `--reasoning off --reasoning-format none` so OpenAI-compatible clients (opencode, pi, OpenClaw) don't break on `reasoning_content`
- ⚙️ **Tune per-model port, context size, and extra args** via a settings window
- 🔌 **Sync** with externally-launched servers (started by the companion CLI or by hand)
- 📁 **Show up in Launchpad, Spotlight, and `~/Applications/`** like a real Mac app

A companion shell command `llama` provides the same functionality from your terminal, and the two tools share state automatically.

## Features Explained

### mmproj Auto-Pairing with Fallback Matching

Vision-capable GGUF models (e.g. Gemma 3, Gemma 4) need a separate **mmproj** (multimodal projection) file to process images. LLM Switcher automatically finds and attaches the right `--mmproj` flag when loading a model.

**How it works:**

1. **Name-based matching** — strips quantization suffixes from the model name (e.g. `gemma-4-12B-it-Q4_K_M` → `gemma-4-12B-it`), then looks for `mmproj-gemma-4-12B-it-*.gguf` in the same directory.

2. **Fallback matching** — if name-based matching fails, scans the directory for **any** `mmproj-*.gguf` file. This handles QAT (Quantization-Aware Training) models where the mmproj might be named `mmproj-BF16.gguf` instead of following the standard naming convention.

```
# Standard naming — name-based match works:
~/models/gguf/
├── gemma-4-12B-it-Q4_K_M.gguf          ← main model
└── mmproj-gemma-4-12B-it-Q8_0.gguf     ← matched by name

# QAT naming — fallback catches it:
~/models/gguf/gemma-4-12B-it-qat-GGUF/
├── gemma-4-12B-it-qat-UD-Q4_K_XL.gguf  ← main model (non-standard name)
└── mmproj-BF16.gguf                     ← matched by fallback
```

The same `findCompanion(for:prefix:)` helper is used for both Swift and bash, ensuring consistent behavior across the app and CLI.

### MTP File Exclusion

**MTP** (Multi-Token Prediction) is a technique where a model predicts multiple tokens per forward pass, speeding up inference. Some model distributions (e.g. unsloth QAT builds) include a separate `mtp-*.gguf` file alongside the main model.

These files are **not standalone models** — they're encoder heads that `llama-server` loads automatically from the model's metadata when the `--mmproj` is attached. If they appeared in the model list, users would try to load them directly and get confusing errors.

**What LLM Switcher does:**
- **Excludes** `mtp-*.gguf` files from the model list (files starting with `mtp-` prefix)
- **Does NOT exclude** files containing `-mtp-` as an infix (e.g. `gemma-3-mtp-Q4_K_M.gguf`) — those are standalone models

```
# Excluded from model list (not standalone):
mtp-gemma-4-12B-it.gguf          ← MTP head, loaded automatically
mtp-Q4_K_M.gguf                  ← MTP head, loaded automatically

# Included in model list (standalone model):
gemma-3-mtp-Q4_K_M.gguf          ← a model with "mtp" in its name
```

### Chat Template Override

`llama-server` includes built-in chat templates for each model family, but **agentic coding harnesses** (opencode, pi, OpenClaw, etc.) need custom templates to handle tool-calling correctly.

**Why the standard template breaks for agentic use:**

The standard Gemma 4 chat template has four edge cases that only surface during multi-turn tool calling:

1. **Broken tool call arguments** — when a harness sends `arguments` as a JSON string (common with Vercel AI SDK), the standard template wraps it in extra braces, producing invalid output like `call:fn{{"city":"Tokyo"}}`
2. **Dropped reasoning** — after 3-4 rounds, the model's prior reasoning is stripped from history, causing tool calls to collapse to `arguments: {}`
3. **Thinking disabled** — `enable_thinking` defaults to false in the standard template, and OpenAI-compatible adapters drop unknown fields, so thinking never activates
4. **Null corruption** — `null` values in tool parameters render as the Python string `"None"` instead of JSON `null`

Custom `.jinja` templates (like `gemma4_chat_template.jinja`) fix these issues but may cause tokenization errors if used with `llama-server`'s built-in tokenizer for regular chat.

**How to use it:**
- **Menu bar app:** Open Settings → Global → Chat Template Override → browse to your `.jinja` file
- **CLI:** `LLAMA_CHAT_TEMPLATE=~/models/gemma4_chat_template.jinja llama load gemma-4-12B-it-qat-UD-Q4_K_XL`
- **Leave empty** to use the model's built-in template (works for regular chat, web UI, Hermes, etc.)

```
# When chat template is NOT set:
llama-server -m model.gguf --mmproj mmproj.gguf
# → uses built-in GGUF template (correct for regular use)

# When chat template IS set:
llama-server -m model.gguf --mmproj mmproj.gguf --chat-template gemma4_chat_template.jinja
# → uses custom template (correct for agentic harnesses)
```

## Gemma 4 Loading Details

For a deep dive into how `llama-server` loads Gemma 4 12B and Gemma 4
12B QAT — including every flag passed, how the SigLIP vision encoder
(mmproj) is loaded, how Multi-Token Prediction (MTP) heads are
discovered and loaded from model metadata, QAT vs standard differences,
and why a custom Jinja template is only required for agentic use cases —
see:

**[docs/GEMMA4_LOADING_DETAILS.md](docs/GEMMA4_LOADING_DETAILS.md)**

Highlights:

- The full annotated `llama-server` command line for both variants
- Why `--reasoning off --reasoning-format none` is required (Gemma 4
  emits a `reasoning_content` field that crashes OpenAI-compatible
  clients; LLM Switcher applies these flags automatically)
- Decision table: when to use the built-in chat template vs a custom
  `.jinja` (Gemma 4 is the only common model that needs an override)
- Manual verification steps (server logs, `/v1/models`, GGUF metadata
  inspection)

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
│   ├── omnicoder-9b-q4_k_m.gguf
│   └── gemma-4-12B-it-qat-GGUF/          # QAT model with companion files
│       ├── gemma-4-12B-it-qat-UD-Q4_K_XL.gguf
│       ├── mmproj-BF16.gguf              # auto-paired via fallback
│       ├── mtp-gemma-4-12B-it.gguf       # excluded, loaded automatically
│       └── gemma4_chat_template.jinja    # custom template (optional)
└── mlx/                     # one dir per model
    └── llama-3.2-3b/
        ├── config.json
        └── model.safetensors
```

The app **automatically excludes** these files from the model list (they're not standalone chat models):
- `mmproj-*.gguf` — vision projection, auto-paired with vision-capable base models
- `mtp-*.gguf` — multi-token prediction head, loaded automatically by llama-server
- `modernbert-embed-*.gguf` — embedding model used by the gbrain system

## Settings

Open Settings from the menu bar dropdown (⚙ Settings…).

**Global tab:**
- **Models Directory** — root directory to scan recursively for GGUF and MLX models
- **Default Port** — base port for auto-assignment (each model gets the next available)
- **Default Ctx Size** — context window size in tokens (accepts "k" suffix, e.g. "8k")
- **Global Extra Args** — extra arguments passed to every `llama-server` process
- **Chat Template Override** — optional path to a custom `.jinja` or `.json` chat template (for agentic harnesses like opencode/pi that need custom tool-calling templates)
- **llama-server** / **mlx_lm.server** — backend binary paths

**Per-Model tab:**
- Editable port and context size for each discovered model
- Load/Unload buttons per model

**CLI environment variables:**
```bash
LLAMA_MODELS_DIR=~/models    # models directory (default: ~/models)
LLAMA_PORT=8080              # default port
LLAMA_CTX_SIZE=4096          # default context size
LLAMA_EXTRA_ARGS=""          # extra args for llama-server
LLAMA_SERVER=/opt/homebrew/bin/llama-server
MLX_SERVER=~/Library/Python/3.14/bin/mlx_lm.server
LLAMA_CHAT_TEMPLATE=""       # optional chat template override
```

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

## Version

Current: **v2.0** — MTP exclusion, mmproj fallback matching, chat template settings, layout overhaul.

See `CHANGELOG.md` for full version history.

## License

Personal use. Modify and redistribute freely.
