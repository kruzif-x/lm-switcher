# State

This document describes where LLM Switcher keeps its runtime state, and
how to find/inspect/reset it.

## At a glance

| Kind of state | Where it lives | Format | Reset by |
|---|---|---|---|
| Global settings | `~/Library/Preferences/local.llama-menubar.plist` | macOS binary plist | `defaults delete local.llama-menubar` |
| Per-model overrides | (same plist, key prefix `model.<hash>.`) | macOS binary plist | (automatic, on unload) |
| Running processes | One file per model: `~/.local/share/llama-menubar/pids/<name>.pid` | Text (PID + port) | `llama unload` or process death |
| Server logs | One file per model: `~/.local/share/llama-menubar/logs/<name>.log` | Text | `rm` (not auto-cleaned) |
| Compiled binary | `~/bin/llama-menubar` | Mach-O | `uninstall.sh` |
| App bundle | `~/Applications/LLM Switcher.app` | macOS .app | `uninstall.sh` |
| LaunchAgent plist | `~/Library/LaunchAgents/local.llama-menubar.plist` | XML plist | `uninstall.sh` |
| Swift source | `~/bin/llama-menubar.swift` | Text | `uninstall.sh` (deletes) |

## Global settings (UserDefaults)

Stored under bundle domain `local.llama-menubar`.

### Keys

| Key | Type | Default | Description |
|---|---|---|---|
| `modelsDir` | String | `~/models` | Root directory to scan (recursively) |
| `defaultPort` | Int | `8080` | Default port if model has no per-model port |
| `defaultCtxSize` | Int | `4096` | Default context size (tokens) |
| `llamaServerPath` | String | `/opt/homebrew/bin/llama-server` | Path to GGUF backend binary |
| `mlxServerPath` | String | `~/Library/Python/3.14/bin/mlx_lm.server` | Path to MLX backend entry script |
| `globalExtraArgs` | String | `""` | Extra args passed to every server (parsed with quote handling) |
| `enableMtp` | Bool | `false` | Enable MTP (`--spec-type draft-mtp`). Off by default — net loss on Metal |
| `model.<hash>.port` | Int | — | Per-model port override |
| `model.<hash>.ctx` | Int | — | Per-model context size override |

`<hash>` is the first 12 chars of md5(model_path).

### Inspect

```bash
# All settings for this app
defaults read local.llama-menubar

# Just one key
defaults read local.llama-menubar modelsDir
```

### Reset

```bash
# Delete the entire plist
defaults delete local.llama-menubar

# Delete just one key
defaults delete local.llama-menubar modelsDir
```

The app reads these on launch and on every change in the settings UI,
so changes take effect immediately.

## Per-model state

Each model has state in three places:

1. **UserDefaults** — port override, ctx override (set by user)
2. **PID file** — running PID + port (set by manager when loaded)
3. **`ps` output** — actual running process (source of truth at runtime)

When the menu bar app starts, it reconciles all three:
- Any model in `UserDefaults` settings appears in the per-model list
- Any PID file marked `isRunning` is treated as loaded
- Any actual `llama-server` / `mlx_lm.server` process is detected and tracked

This reconciliation happens:
- On app launch
- Every 3 seconds (via `Timer.scheduledTimer`)
- On `refreshModels()` and `unloadAll()`

## Runtime data

`~/.local/share/llama-menubar/`:

```
~/.local/share/llama-menubar/
├── pids/                    # one .pid file per running model
│   ├── gemma-4-12B-it-Q4_K_M.gguf.pid
│   │   Line 1: 1234              (the PID)
│   │   Line 2: 1234 --port 8080 (for fast port recovery)
│   └── omnicoder-9b-q4_k_m.gguf.pid
│       ...
├── logs/                    # one .log file per running model
│   ├── gemma-4-12B-it-Q4_K_M.gguf.log
│   │   # stdout+stderr of `llama-server` for that model
│   └── omnicoder-9b-q4_k_m.gguf.log
└── server.log               # (legacy, unused by current versions)
```

The `pids/` and `logs/` filenames are derived from the model filename:
- Take the basename of the model path
- Replace `/` and ` ` with `_`
- Add `.pid` / `.log` suffix

For example, `/Users/foo/gguf/my model.gguf` becomes `my_model.gguf.pid`.

## Process management

### How a model gets loaded

1. User clicks "Load Selected" in the menu (or runs `llama load` in the CLI).
2. The manager picks a port (per-model override or next free).
3. The manager spawns the backend process with the right args:
   ```
   llama-server -m <model> --port <port> --host 127.0.0.1 [--ctx-size N] [--mmproj <vision>] --reasoning off --reasoning-format none [--chat-template <jinja>] [extra args]
   mlx_lm.server --model <dir> --port <port> --host 127.0.0.1 [extra args]
   ```
4. The process's PID is written to a file in `pids/`.
5. The process's stdout+stderr is redirected to a file in `logs/`.

### How a model gets unloaded

1. User clicks "⏹ Unload All" (or "Unload" on a specific model) in the menu.
2. The manager sends `SIGTERM` to the PID.
3. The process is given 1 second to shut down gracefully.
4. If still alive, the manager escalates to `SIGKILL`.
5. The PID file is removed.

### What happens if the process dies unexpectedly

The 3-second sync timer in the menu bar app runs `ps` and checks for
each tracked PID. If a PID is no longer alive, its state is cleared
in `modelStates`. The PID file is also cleaned up the next time the
CLI is run.

## Auto-start

`~/Library/LaunchAgents/local.llama-menubar.plist` registers the app
with `launchd` to start at login. The plist points to:

```
~/Applications/LLM Switcher.app/Contents/MacOS/llama-menubar
```

`RunAtLoad = true` means it starts as soon as launchd loads the
agent (i.e. immediately after `launchctl bootstrap` is called, which
the install script does).

`KeepAlive = false` means: if the app exits (because you clicked
"Quit"), launchd will NOT restart it. The next login will start it
again, but the current session won't see it come back.

To disable auto-start:

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/local.llama-menubar.plist
```

To re-enable:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.llama-menubar.plist
```

To remove auto-start permanently:

```bash
rm ~/Library/LaunchAgents/local.llama-menubar.plist
```

## Troubleshooting

### "The app doesn't see models I just downloaded"

The directory watcher fires on changes to the *parent* of the models
directory. If you added models in `~/models/gguf/`, the watcher
(firing on `~` changes) should see them. If for some reason it
didn't, click "↻ Refresh" in the menu, or run:

```bash
llama menubar     # the menu app is already running, this is a no-op
```

…or restart the app:

```bash
launchctl kickstart -k gui/$(id -u)/local.llama-menubar
```

### "I changed a setting in the menu, but the CLI doesn't see it"

The CLI reads settings on each invocation, so it should always see
the latest. If it doesn't, check the plist directly:

```bash
defaults read local.llama-menubar modelsDir
```

### "I see a model running in the menu, but `ps` shows nothing"

This means the model was killed but the menu's internal state hasn't
synced yet. The 3-second sync timer should clean it up. If not,
click "↻ Refresh" in the menu.
