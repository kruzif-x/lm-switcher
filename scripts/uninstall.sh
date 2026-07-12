#!/bin/zsh
# =============================================================================
#  uninstall.sh — Remove LLM Switcher
# =============================================================================
#
#  PURPOSE
#  -------
#  Cleanly remove the LLM Switcher menu bar app, CLI, source files,
#  app bundle, LaunchAgent, runtime data, and saved settings.
#
#  WHAT IT DOES
#  -------------
#  1. Stops any running `llama-server` / `mlx_lm.server` processes that
#     were launched by us (identified by their PID files).
#  2. Stops the menu bar app process.
#  3. Unloads and removes the LaunchAgent.
#  4. Removes the `.app` bundle from `~/Applications/`.
#  5. Removes the legacy `.app` bundle from `~/bin/` (older installs).
#  6. Removes the compiled binary, `llm-switcher-mcp` agent-access
#     server, CLI script, Swift source, install scripts, and icon
#     assets from `~/bin/`.
#  7. Removes the runtime data directory (`~/.local/share/llama-menubar/`).
#  8. Clears the per-app `defaults` settings.
#
#  WHAT IT DOES NOT DO
#  -------------------
#  - It does NOT remove the `~/bin/` directory itself (in case you have
#    other tools there).
#  - It does NOT remove the `~/Applications/` directory.
#  - It does NOT remove your models (`~/models/`) or your gguf cache.
#  - It does NOT deregister `llm-switcher-mcp` from any MCP client
#    (Claude Code, Hermes, etc.) — those keep their own config outside
#    this app, so removing the binary would otherwise leave a dangling
#    reference. The script prints a reminder at the end.
#
#  USAGE
#  -----
#      ./uninstall.sh             # default: cleans ~/bin
#      ./uninstall.sh /opt/bin    # custom bin dir
# =============================================================================


# Exit on any error.
set -e

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

# Where the source, CLI, and compiled binary live.
BIN_DIR="${1:-$HOME/bin}"

# App bundle location (the new, recommended one).
APP_DIR="$HOME/Applications"
APP_BUNDLE="$APP_DIR/LLM Switcher.app"

# Legacy location (older versions of the installer put it here).
OLD_APP_BUNDLE="$BIN_DIR/llama-menubar.app"

# LaunchAgent.
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_FILE="$PLIST_DIR/local.llama-menubar.plist"

# Runtime data (PID files, logs).
LLAMA_DIR="${LLAMA_DIR:-$HOME/.local/share/llama-menubar}"


# -----------------------------------------------------------------------------
# Step 1: Stop running model servers
# -----------------------------------------------------------------------------
# We look for our PID files (one per model) and SIGTERM each process.
# If a process doesn't respond within a second, we escalate to SIGKILL.
# We also do a `pkill` as a safety net to catch any orphaned processes.

echo "==> Stopping llama-server / mlx_lm.server processes..."
PID_FILE="$LLAMA_DIR/server.pid"
if [[ -f "$PID_FILE" ]]; then
    pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        sleep 1
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        echo "  ✓ Server stopped"
    fi
    rm -f "$PID_FILE"
fi

# Also stop any per-model server processes (the new multi-process layout
# uses one PID file per model in $LLAMA_DIR/pids/).
if [[ -d "$LLAMA_DIR/pids" ]]; then
    for pf in "$LLAMA_DIR/pids"/*.pid; do
        [[ -f "$pf" ]] || continue
        pid=$(head -1 "$pf" 2>/dev/null)
        [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null
    done
    sleep 1
    # SIGKILL anything still alive.
    for pf in "$LLAMA_DIR/pids"/*.pid; do
        [[ -f "$pf" ]] || continue
        pid=$(head -1 "$pf" 2>/dev/null)
        [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    done
    rm -rf "$LLAMA_DIR/pids"
fi

# Safety net: kill any remaining processes whose command line references
# our config. This is broader than the PID-file approach but harmless.
if pgrep -f "llama-server.*cache/llama.cpp\|mlx_lm.server" >/dev/null 2>&1; then
    pkill -f "llama-server.*cache/llama.cpp" 2>/dev/null || true
    pkill -f "mlx_lm.server" 2>/dev/null || true
    echo "  ✓ All model servers stopped"
fi

# Clean up the logs directory.
if [[ -d "$LLAMA_DIR/logs" ]]; then
    rm -rf "$LLAMA_DIR/logs"
fi


# -----------------------------------------------------------------------------
# Step 2: Unload the LaunchAgent
# -----------------------------------------------------------------------------
# `launchctl bootout` tells launchd to stop the agent and remove it
# from the loaded set. We then delete the .plist file. After bootout
# the agent is no longer loaded, so even if the file is gone, the
# process is gone too.

echo "==> Unloading LaunchAgent..."
if [[ -f "$PLIST_FILE" ]]; then
    launchctl bootout gui/$(id -u) "$PLIST_FILE" 2>/dev/null || true
    rm -f "$PLIST_FILE"
    echo "  ✓ LaunchAgent removed"
fi


# -----------------------------------------------------------------------------
# Step 3: Stop the menu bar app
# -----------------------------------------------------------------------------
# The menu bar app itself is a long-running process. We SIGTERM it
# (and SIGKILL if necessary) so it doesn't keep running after we
# delete the .app bundle underneath it.

echo "==> Stopping menu bar app..."
pkill -f "llm-switcher" 2>/dev/null || true
sleep 1


# -----------------------------------------------------------------------------
# Step 4: Remove the .app bundle(s)
# -----------------------------------------------------------------------------
# We remove BOTH the new `~/Applications/LLM Switcher.app` and the
# legacy `~/bin/llama-menubar.app` (in case the user upgraded from
# an older install).

echo "==> Removing app bundle..."
if [[ -d "$APP_BUNDLE" ]]; then
    rm -rf "$APP_BUNDLE"
    echo "  ✓ $APP_BUNDLE removed"
fi
if [[ -d "$OLD_APP_BUNDLE" ]]; then
    rm -rf "$OLD_APP_BUNDLE"
    echo "  ✓ $OLD_APP_BUNDLE (legacy) removed"
fi


# -----------------------------------------------------------------------------
# Step 5: Remove source/binary files from ~/bin
# -----------------------------------------------------------------------------
# We remove each file individually and report what we did, so the user
# can see exactly what was cleaned up.

echo "==> Removing files from $BIN_DIR..."

# Compiled binary.
if [[ -f "$BIN_DIR/llm-switcher" ]]; then
    rm -f "$BIN_DIR/llm-switcher"
    echo "  ✓ llm-switcher binary removed"
fi

# MCP agent-access server (separate binary; may not exist if that
# build failed or the user is on a pre-1.2.0 install).
if [[ -f "$BIN_DIR/llm-switcher-mcp" ]]; then
    rm -f "$BIN_DIR/llm-switcher-mcp"
    echo "  ✓ llm-switcher-mcp removed"
fi

# CLI script.
if [[ -f "$BIN_DIR/llama" ]]; then
    rm -f "$BIN_DIR/llama"
    echo "  ✓ llama CLI removed"
fi

# Swift source. install.sh copies the whole multi-file module (audit A-1:
# LlamaMenubarApp.swift, ServerManager.swift, MenuView.swift,
# SettingsView.swift, DomainTypes.swift) into $BIN_DIR, plus older installs
# left a single llama-menubar.swift. Remove all of them.
shopt -s nullglob 2>/dev/null || setopt NULL_GLOB 2>/dev/null || true
for swift_src in "$BIN_DIR"/*.swift; do
    [[ -f "$swift_src" ]] || continue
    rm -f "$swift_src"
    echo "  ✓ $(basename "$swift_src") removed"
done

# Icon assets.
if [[ -f "$BIN_DIR/AppIcon.icns" ]]; then
    rm -f "$BIN_DIR/AppIcon.icns"
    echo "  ✓ AppIcon.icns removed"
fi
if [[ -d "$BIN_DIR/icon.iconset" ]]; then
    rm -rf "$BIN_DIR/icon.iconset"
    echo "  ✓ icon.iconset removed"
fi
if [[ -f "$BIN_DIR/make_icon.py" ]]; then
    rm -f "$BIN_DIR/make_icon.py"
    echo "  ✓ make_icon.py removed"
fi

# Install / uninstall scripts.
if [[ -f "$BIN_DIR/install.sh" ]]; then
    rm -f "$BIN_DIR/install.sh"
    echo "  ✓ install.sh removed"
fi
if [[ -f "$BIN_DIR/uninstall.sh" ]]; then
    rm -f "$BIN_DIR/uninstall.sh"
    echo "  ✓ uninstall.sh removed"
fi


# -----------------------------------------------------------------------------
# Step 6: Remove runtime data
# -----------------------------------------------------------------------------
# This deletes the entire `~/.local/share/llama-menubar/` directory,
# which contains all PID files and logs. We use `rm -rf` for atomic
# removal.

echo "==> Removing runtime data..."
if [[ -d "$LLAMA_DIR" ]]; then
    rm -rf "$LLAMA_DIR"
    echo "  ✓ $LLAMA_DIR removed"
fi


# -----------------------------------------------------------------------------
# Step 7: Clear saved settings
# -----------------------------------------------------------------------------
# We use the `defaults` command to delete the per-app preferences plist.
# The `|| true` at the end handles the case where the plist doesn't
# exist (e.g. on a fresh install).

echo "==> Removing saved settings..."
if defaults delete local.llama-menubar 2>/dev/null; then
    echo "  ✓ Settings cleared"
else
    echo "  (no settings to clear)"
fi


# -----------------------------------------------------------------------------
# Done!
# -----------------------------------------------------------------------------
echo ""
echo "✓ Uninstalled!"
echo ""
echo "Note: ~/bin/ is left intact. If you want to remove it:"
echo "  rmdir ~/bin   # (only if empty)"
echo ""
echo "Note: ~/Applications/ is left intact. If empty, you can remove it too."
echo ""
echo "If you registered the MCP agent-access server (llm-switcher-mcp)"
echo "with any client, deregister it there too — this script can't reach"
echo "into their config:"
echo "  claude mcp remove llm-switcher          # Claude Code"
echo "  # Hermes: remove the llm-switcher entry from"
echo "  #   ~/.hermes/config.yaml → mcp_servers:, then restart the gateway"
