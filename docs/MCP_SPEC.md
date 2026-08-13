# LM Switcher MCP — Specification

Status: DRAFT for review · Target version: 1.2.0

## 1. Goals and non-goals

**Goals**

- Agents (Hermes, opencode, etc.) can list, load, unload, and switch models
  through a standard MCP stdio server, gated by a user toggle (default OFF).
- Agents always see live truth: running models, ports, endpoints, memory,
  swap, and pressure — including changes the user made from the menu bar.
- Loads that would push the system into swap are refused unless the user
  opts in (default: refuse).
- Zero regressions in the existing app. The menu bar app is running well;
  this project treats its current code paths as frozen.

**Non-goals (v1)**

- Settings mutation by agents (read-only).
- Arbitrary CLI args from agents (injection surface).
- Push notifications to agents on state change (MCP stdio has no reliable
  push; the polling + fresh-snapshot design covers it).
- TTL auto-unload, model aliases, parameter profiles, crash auto-restart
  (deferred to v1.3 — see §7).

## 2. Phasing

| Phase | Contents | App code touched |
|-------|----------|------------------|
| 1 | MCP binary, system metrics, swap guard, footprint estimation, pinning, 2 new settings + 1 settings card | ~30 lines, all additive |
| 2 | oMLX backend (REST client, discovery merge, badge) | Moderate, behind a default-OFF toggle |
| 3 | v1.3 niceties (TTL unload, aliases, notifications) | — |

Phase 1 ships alone and is verified before Phase 2 starts.

## 3. Phase 1

### 3.1 Components

New standalone executable: `lm-switcher-mcp`, installed to `~/bin`.
**Shares no source files with the app**, with one deliberate exception:
`src/SystemMetrics.swift` (read-only RAM/pressure/swap/RSS reads, no side
effects, no protocol surface) is compiled into both targets — the app uses
it for the menu footer memory line. Compiled as a second `swiftc`
target in `install.sh`. If the MCP build fails, the app install still
completes (build app first, MCP second, warn on failure).

```
src/mcp/
├── main.swift            # stdio loop, JSON-RPC dispatch
├── JsonRpc.swift         # minimal JSON-RPC 2.0 encode/decode
├── McpTools.swift        # tool registry, schemas, dispatch
├── StateReader.swift     # PID files + ps + lsof + UserDefaults reads
├── Launcher.swift        # mutations via the `llama` CLI subprocess
├── SystemMetrics.swift   # RAM / pressure / swap / RSS (clean-room)
├── FootprintEstimator.swift  # GGUF header parse, MLX config.json, KV math
└── ByteFormat.swift      # base-1024 human formatting
```

Registration (printed by install.sh):
`hermes mcp add lm-switcher --command ~/bin/lm-switcher-mcp`

### 3.2 Protocol

- MCP over stdio: newline-delimited JSON-RPC 2.0.
- Handles: `initialize`, `notifications/initialized` (no-op), `ping`,
  `tools/list`, `tools/call`. Unknown methods → JSON-RPC method-not-found.
- `initialize` response advertises server name `lm-switcher` and an
  `instructions` string:

> Models can be loaded and unloaded by the user from the menu bar at any
> time — never assume state persists between your calls. Call `status`
> before acting on assumptions. Every mutation response includes a fresh
> state snapshot; treat it as the current truth. Do not load models when
> memory_pressure is "warning" or "critical". Agent access can be disabled
> by the user at any time in LM Switcher settings.

### 3.3 Tool contract

Every response (success or error) embeds a fresh `state` snapshot:

```json
"state": {
  "running": [
    {
      "name": "Qwythos-9B-Max",
      "backend": "GGUF",
      "port": 8080,
      "endpoint": "http://127.0.0.1:8080/v1",
      "pid": 4411,
      "state": "ready",
      "ctx_size": 16384,
      "max_context_window": 32768,
      "estimated_footprint": "6.3 GB",
      "actual_rss": "6.1 GB",
      "pinned": true
    }
  ],
  "ports": {
    "8080": {"occupied_by": "Qwythos-9B-Max", "source": "lm-switcher"},
    "8082": {"occupied_by": "pid 7301 (node)", "source": "external"},
    "next_free": 8081
  },
  "system": {
    "ram_total": "32 GB",
    "ram_used": "21.4 GB",
    "ram_available": "10.6 GB",
    "memory_pressure": "normal",
    "swap_total": "2 GB",
    "swap_used": "1.1 GB",
    "allow_swap_loads": false
  }
}
```

`state` for a running model is derived: PID alive + HTTP health probe on its
port (llama-server `/health`, mlx `/v1/models`) → `ready`; PID alive but
port not serving → `starting`.

#### Tools

| Tool | Params | Notes |
|------|--------|-------|
| `status` | — | Snapshot only |
| `list_models` | — | All discovered models: name, backend, file size, `max_context_window`, running?, vision (mmproj)?, pinned?, per-model overrides? |
| `load_model` | `name` (req), `ctx_size?`, `port?`, `timeout_s?` (default 180, clamp 10–600) | Blocks until health probe passes or timeout. Returns endpoint + model id for API calls |
| `unload_model` | `name` (req) | Refuses pinned models (`model_pinned`) |
| `unload_all` | — | Skips pinned models; reports `skipped_pinned: [...]` |
| `switch_model` | `name` (req), `ctx_size?`, `unload_first?` (default false) | See §3.7 for the overlap check |
| `get_settings` | — | Read-only dump of global settings + per-model overrides + toggle states |

Name resolution mirrors the CLI: case-insensitive substring match; exact
match wins; multiple candidates → `ambiguous_name` error listing them.

**Idempotency:** `load_model` on a running model → success,
`"already running on :8080"` + endpoint. `unload_model` on a stopped model
→ success with note. Agent/user races become harmless no-ops.

**Ephemeral overrides:** `ctx_size`/`port` are passed to the launch via
environment (`LLAMA_CTX_SIZE`, `LLAMA_PORT`) — never persisted. The user's
saved settings are untouched by agent activity.
*(Implementation gate: verify the CLI honors these env vars over per-model
overrides; if not, add an additive `--ctx/--port` flag to the CLI rather
than changing existing precedence.)*

### 3.4 Error taxonomy

Tool errors return `isError: true` with structured content:

```json
{
  "error_code": "insufficient_memory",
  "message": "gemma-4-12B at ctx 32768 needs ~14.8 GB; 9.2 GB available (2.0 GB headroom reserved). Fits at ctx <= 12288. Or unload Qwythos-9B (6.1 GB).",
  "max_ctx_that_fits": 12288,
  "state": { }
}
```

| Code | Meaning |
|------|---------|
| `agent_access_disabled` | Toggle is OFF |
| `not_found` | No model matches `name` |
| `ambiguous_name` | Multiple matches (listed) |
| `already_loading` | Same model is mid-load |
| `insufficient_memory` | Swap guard refusal (incl. `max_ctx_that_fits`) |
| `port_conflict` | Requested port occupied (occupant named) |
| `backend_missing` | Server binary not found / not configured |
| `load_timeout` | Process spawned but never became healthy |
| `load_failed` | Process exited; captured stderr tail included |
| `model_pinned` | Unload refused; user pinned it |

### 3.5 State reading — truth model

The MCP holds **no state in memory** between calls. Per call it reads:

- PID files: `~/.local/share/llama-menubar/pids/`
- Process table: `ps` (same matching as the CLI/app)
- Port occupancy: `lsof -nP -iTCP -sTCP:LISTEN` filtered to the scan range
- Settings/toggles: `CFPreferencesAppSynchronize` then
  `CFPreferencesCopyAppValue` on domain `local.llama-menubar` — sync first,
  every call, so a toggle flip in the app is seen immediately

From the app's perspective the MCP is indistinguishable from the CLI: same
launch path, same PID files, same reconciliation via the existing
`mergeExternalStates` poll. **No app changes are needed for the app to see
agent actions — this mechanism already exists and is battle-tested.**

### 3.6 System metrics (clean-room implementations)

Adapted as techniques from vorssaint-utils (GPL) — **reimplemented, no code
copied**; public Apple APIs only:

1. **RAM used** — `host_statistics64(HOST_VM_INFO64)`:
   `used = total − (free + speculative + file-backed) × page_size`
   (matches Activity Monitor). Must `mach_port_deallocate` the
   `mach_host_self()` port each call (leak otherwise).
2. **Memory pressure** — `sysctl kern.memorystatus_vm_pressure_level`:
   1 → normal, 2 → warning, 4 → critical, else unknown.
3. **Swap** — `sysctl vm.swapusage` → `xsw_usage` total/used/free.
4. **Per-model RSS** — `ps -o rss= -p <pid>`.
5. **Formatting** — base-1024; one decimal below 10, none at or above.

### 3.7 Footprint estimation and swap guard

```
footprint ≈ weights + kv_cache + overhead
weights   = model file size (GGUF) or Σ safetensors sizes (MLX)
kv_cache  = layers × kv_heads × head_dim × ctx × (bytes_K + bytes_V)
bytes/el  : f16 = 2.0, q8_0 = 1.0625, q4_0 = 0.5625
overhead  = 10% of weights + 512 MB compute buffer
headroom  = max(2 GB, 10% of total RAM)   // reserved for the OS, always
```

- **GGUF:** parse the header only (magic `GGUF`, v2/v3; read metadata KVs:
  `general.architecture`, `<arch>.block_count`,
  `<arch>.attention.head_count_kv`, key/value length or
  embedding_length ÷ head_count, `<arch>.context_length` →
  `max_context_window`). Never read tensor data. Parse failure → fall back
  to file-size-only estimate, flagged `"estimate_quality": "file_size_only"`.
- **MLX:** `config.json` (`num_hidden_layers`, `num_key_value_heads`,
  `head_dim`/`hidden_size`, `max_position_embeddings`); respect
  `mlxMaxKvSize` cap when set.
- MoE models: file size ≈ fully mapped weights → estimate is conservative
  (safe direction).
- KV bytes respect the user's configured cache types (global or per-model).

**Guard (on `load_model` / `switch_model`):**

- `allowSwapLoads == false` (default): refuse when
  `footprint > ram_available − headroom`, error `insufficient_memory` with
  `max_ctx_that_fits` (solved from the same equation) and unload
  suggestions.
- `allowSwapLoads == true`: proceed; response includes a `warning` block
  with the projected overshoot and current swap usage.
- `memory_pressure == critical`: refuse when toggle OFF; strong warning
  when ON.
- **mlock interplay:** if the user's mlock is ON and the guard would refuse,
  the error notes the load would likely fail outright rather than swap.

**`switch_model` overlap:** new + old are transiently co-resident. Guard
checks `footprint_new ≤ available − headroom` with old still counted. If
that fails but would pass after unloading current models, error suggests
`unload_first: true`. With `unload_first: true`: unload others, then load —
response notes the downtime window and that a failed load leaves nothing
running.

### 3.8 Mutations path

Load/unload/switch shell out to the existing `llama` CLI (subprocess with
controlled argv — no shell interpolation of agent input; model names are
passed as single argv elements). Rationale: one battle-tested launch path;
the MCP adds pre-flight (guard) and post-flight (health wait) around it.

Health wait after load: poll the target port every 500 ms until healthy or
`timeout_s`. On process exit before healthy → `load_failed` with stderr
tail (captured from the CLI subprocess).

### 3.9 Settings and toggles (app side)

`AppSettings` gains two fields (additive, defaulted — absent keys read as
defaults, no migration):

```swift
var mcpEnabled: Bool = false       // master toggle for agent access
var allowSwapLoads: Bool = false   // permit loads that exceed free RAM
```

SettingsView Global tab gains one card, **"Agent access (MCP)"**, below
Inference:

- Toggle: "Allow agent control (MCP)" — hint: "Lets MCP-connected agents
  (Hermes, opencode, etc.) list, load, and unload models. Off = agents are
  fully blocked."
- Toggle: "Allow swap for model loads" — hint: "When off, agent loads that
  don't fit in free RAM are refused instead of swapping to disk."
- Static caption: registration one-liner
  (`hermes mcp add lm-switcher --command ~/bin/lm-switcher-mcp`).

Enforcement: `mcpEnabled` checked on **every** `tools/call` (fresh read per
§3.5). OFF blocks all tools including reads. `tools/list` still responds
(schema discovery is harmless). Flipping the toggle never affects already-
running models — it revokes control, not servers (documented in Help).

### 3.10 Pinning

- Per-model flag stored via the **existing** per-model settings mechanism
  (key `pinned`, default false) — no new storage code.
- Menu bar: right-click a running model → "Pin" / "Unpin"; pinned rows show
  a small `pin.fill` icon. Purely additive context-menu item + icon.
- **Consumed only by the MCP**: `unload_model` on a pinned model →
  `model_pinned` error; `unload_all` skips pinned and reports them.
- **User actions are NOT affected by pins in v1** — the menu bar Unload
  buttons behave exactly as today (zero behavior change to existing
  controls; the pin protects against agents, not the user). Stated in Help.

### 3.11 App-side changes — exhaustive list

| File | Change | Nature |
|------|--------|--------|
| `DomainTypes.swift` | +2 `AppSettings` fields with defaults | Additive |
| `ServerManager.swift` | +2 keys in `loadSettings`/`saveSettings` | Additive (~4 lines) |
| `SettingsView.swift` | +1 card (2 toggles + caption), +2 mirrors | Additive UI |
| `MenuView.swift` | +Pin/Unpin context item, +pin icon on row | Additive UI |
| `SettingsView.swift` Help tab | +"Agent access" section | Additive content |
| `scripts/install.sh` | +second swiftc target, +registration hint | Additive; MCP build failure does not block app install |

**Explicitly untouched:** process spawn/unload paths, `mergeExternalStates`
and the poll loop, bulk-selection behavior, menu sizing (the `naturalH` fix),
window-panel plumbing, the CLI. (Pin icon adds a subview to the running
row; row height unchanged.)

### 3.12 DFlash drafter + per-model reasoning suppression

- `get_settings` exposes `enableDflash` (global bool, default `true`) and
  the per-model suffix `suppressReasoning` alongside the existing keys.
- `StateReader.discoverModels` excludes `dflash-*.gguf` from the model
  list (in sync with the Swift app and CLI).
- Loads shell out to the `llama` CLI, which now reads per-model
  overrides via `pm()`/`pm_bool()` (`model.<hash>.<key>` first, global
  fallback) — so agent-driven loads apply the same per-model
  temperature/KV-cache/reasoning/DFlash settings as app loads.
- DFlash-specific launch flags when a drafter is attached:
  `--spec-type draft-dflash --spec-draft-model <file> --spec-draft-n-max
  15 --spec-draft-p-min 0.4`; `--top-p`/`--top-k`/`--repeat-penalty` are
  omitted (they collapse block acceptance).

## 4. Regression-safety analysis

| Risk | Mitigation |
|------|------------|
| MCP binary bugs affect the app | Impossible by construction: separate process, separate compilation, app never invokes it |
| New AppSettings fields corrupt persisted settings | Additive keys with defaults; absent key → default; no schema migration exists to break |
| Settings card breaks Global tab layout | Additive card in the existing card stack; no changes to other cards; verified visually before commit |
| Pin item breaks the context menu | Additive `Button` in existing `contextMenu`; no handler changes to Load/Unload/Switch |
| install.sh change breaks app build | App target builds first, unchanged; MCP target second; MCP failure warns and continues |
| MCP double-spawns a model the app is loading | Pre-flight checks PID file + `ps` before spawn (same as CLI today); residual same-second race is identical to the existing CLI/app race — not a new class of bug |
| Env-var ctx/port override has unexpected precedence | Gated implementation check (§3.3); fallback is an additive CLI flag, not a precedence change |
| `lsof`/`ps` calls slow the MCP | Only run inside MCP tool calls — never in the app; app poll loop untouched |

## 5. Verification plan (before commit)

**App (regression):** build via install.sh; then menu: load 1 model, load
2nd, checkbox uncheck persists (snap-back regression check), bulk unload,
switch via context menu, refresh, settings open/save/restore, per-model
override roundtrip, quit.

**MCP (new, tested standalone by piping JSON-RPC over stdin):**

1. `initialize` → correct serverInfo + instructions
2. Toggle OFF (default): every tool → `agent_access_disabled`
3. Toggle ON: `status` on idle system; `list_models` matches menu
4. `load_model` small model → blocks, returns endpoint; curl the endpoint
5. Menu bar shows the model within ~3 s; bolt turns green
6. `load_model` same model again → idempotent "already running"
7. User unloads from menu → `status` reflects within one call
8. `unload_model` on stopped model → idempotent note
9. `load_model` with absurd `ctx_size` → `insufficient_memory` with
   plausible `max_ctx_that_fits`
10. Pin a model in menu → `unload_model` → `model_pinned`; `unload_all`
    skips it and reports
11. Toggle OFF mid-session → next call blocked; running models unaffected
12. `switch_model` between two models; verify overlap guard and
    `unload_first` path
13. GGUF header parse spot-check: reported `max_context_window` vs known
    model card values; corrupt/truncated file → `file_size_only` fallback

## 6. Phase 2 — oMLX backend (outline; full spec after Phase 1 ships)

- `ModelBackend.omlx` (badge OMLX, teal); `OmlxClient.swift` URLSession
  wrapper for `/health`, `/api/status`, `/v1/models/status`,
  `/v1/models/{id}/load|unload`.
- Settings → Backends: oMLX row (enable toggle **default OFF**, base URL
  default `http://127.0.0.1:8000`, optional API key). Toggle OFF ⇒ zero
  new code paths execute — regression-safe by default.
- Discovery: oMLX catalogue merged from `/v1/models/status` (not disk
  scan); dedupe by path with "Prefer oMLX for MLX models" toggle.
- Sync loop: one `GET /api/status` per poll tick, only when enabled.
- MCP routes oMLX loads via REST; translates its 507 memory errors into
  `insufficient_memory` (oMLX's own memory guard is authoritative for its
  models); all-models-on-:8000 reflected in the port map.
- Server lifecycle: auto-start via `omlx start` on first load (opt-in
  setting); "server offline" state in menu otherwise.

## 7. Phase 3 — deferred (v1.3 candidates)

TTL auto-unload (needs `/slots` activity polling) · model aliases +
parameter profiles · macOS notification on agent actions (own toggle) ·
user-configurable hide-from-list flag replacing hard-coded exclusions ·
pin/TTL passthrough for oMLX.

## 8. Docs and versioning

Version 1.2.0. CHANGELOG entry; README: "Agent control (MCP)" section with
tool table + registration; Help tab: section 9 "Agent access (MCP)" — what
it is, both toggles, pin protection, "toggle off does not unload models".

## 9. Review decisions (resolved 2026-07-11)

1. **Pins don't affect user actions** — confirmed. Menu buttons behave as
   today; pins gate agents only.
2. **Headroom is a fixed constant**, not a setting. The OS requirement is
   not a preference; the Allow-swap toggle is the sanctioned escape hatch.
3. **`tools/list` stays visible when disabled; every call blocked.** The
   `agent_access_disabled` error names the exact settings path, so agents
   can tell users how to enable it. Also avoids stale tool caches in MCP
   clients that fetch `tools/list` only at session start.
4. **Load timeout 180 s confirmed by measurement** (2026-07-11, M-series
   32 GB, SSD 4.7 GB/s): 6.3 GB model → healthy in 5.8 s; largest model
   (15.7 GB) → 11.0 s, zero swap. 180 s is ~16× worst-case margin here and
   covers slower Macs in the field (App Store distribution).

**Distribution note:** Mac App Store requires App Sandbox, which the
current architecture violates (spawns external binaries, `ps` scanning,
`~/bin` CLI, LaunchAgent). MAS distribution needs a separate re-architecture
scoping; notarized direct distribution has no such conflict.
