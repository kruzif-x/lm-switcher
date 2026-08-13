#!/bin/zsh
# =============================================================================
#  install.sh — Build and install LM Switcher
# =============================================================================
#
#  PURPOSE
#  -------
#  This script performs a clean build of the LM Switcher menu bar app
#  from source, packages it as a proper macOS `.app` bundle, registers it
#  with Launch Services (so it shows in Launchpad and Spotlight), and
#  installs an auto-start LaunchAgent.
#
#  WHAT IT DOES
#  -------------
#  1. Compiles `LlamaMenubarApp.swift` with `swiftc` to a single binary.
#  2. Wraps the binary in an `.app` bundle at `~/Applications/`, copying
#     the compiled icon and writing a proper Info.plist.
#  3. Ad-hoc codesigns the bundle so Launchpad/Spotlight recognize it.
#  4. Calls `lsregister` to refresh Launch Services.
#  5. Installs the `llama` CLI script to `~/bin/`.
#  6. Writes a `~/Library/LaunchAgents/local.llama-menubar.plist` so the
#     menu bar app starts automatically on login.
#  7. Bootstraps the LaunchAgent (starts it now).
#
#  USAGE
#  -----
#  Default install (everything in ~/bin and ~/Applications/):
#      ./install.sh
#
#  Custom bin dir:
#      ./install.sh /custom/bin
#
#  UNINSTALL
#  ---------
#  Run `llama uninstall` or `~/bin/uninstall.sh`.
# =============================================================================


# Exit immediately on any error. We use `set -e` (not `set -euo pipefail`)
# because some commands (like `which`) intentionally return non-zero.
set -e

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

# Where the source, CLI, and (after build) compiled binary live.
# Default: ~/bin
BIN_DIR="${1:-$HOME/bin}"

# Directory holding the Swift sources. install.sh copies all of src/*.swift
# into $BIN_DIR before compiling (the app is split across several files since
# audit A-1; they're compiled together as one module).
# Resolve the repo's src/ relative to this script so a fresh clone works.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"

# Compiled binary (intermediate; copied into the .app bundle).
COMPILED_BIN="$BIN_DIR/lm-switcher"

# The `llama` CLI script (installed from the repo's src/llama).
CLI_SCRIPT="$BIN_DIR/llama"

# LaunchAgent plist (auto-start on login).
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_FILE="$PLIST_DIR/local.llama-menubar.plist"

# App bundle location. We put it in `~/Applications/` (user-scoped) rather
# than `/Applications/` (system-scoped) so we don't need sudo. macOS
# treats both as equivalent for most purposes (Launchpad, Spotlight,
# `open` command).
APP_DIR="$HOME/Applications"
APP_BUNDLE="$APP_DIR/LM Switcher.app"

# Ensure the directories we need exist.
mkdir -p "$BIN_DIR"
mkdir -p "$PLIST_DIR"
mkdir -p "$APP_DIR"

# Remove any stale binaries from previous installs so the rebuild starts
# clean (otherwise a failed compile could leave an outdated binary in place
# and the install would still report success).
rm -f "$BIN_DIR/lm-switcher" "$BIN_DIR/lm-switcher-mcp"


# -----------------------------------------------------------------------------
# Step 1: Compile Swift source
# -----------------------------------------------------------------------------
# `swiftc -parse-as-library` is REQUIRED because we use `@main`. Without
# it, the compiler treats the file as a top-level script and rejects
# `@main`. `-O` enables optimizations (slightly smaller + faster binary).
#
# Frameworks we link against:
#   - SwiftUI: declarative UI.
#   - AppKit: NSWindow, NSOpenPanel, NSApplication.

echo "==> Compiling lm-switcher (multi-file module)..."
# Copy all Swift sources from the repo into $BIN_DIR so the build is
# self-contained and reproducible from a fresh clone (audit L-8 + A-1).
cp "$SRC_DIR"/*.swift "$BIN_DIR"/
# Compile every .swift file together as one module. Swift's
# whole-module optimization requires all sources in one invocation.
swiftc -parse-as-library -o "$COMPILED_BIN" -O \
    -framework SwiftUI -framework AppKit \
    "$BIN_DIR"/*.swift

# MCP agent-access server (MCP_SPEC.md Phase 1). A separate binary that
# shares no source files with the app. Built SECOND so a broken MCP build
# can never block the app install — the `if` also keeps `set -e` from
# aborting on failure.
echo "==> Compiling lm-switcher-mcp (agent access server)..."
if swiftc -O -o "$BIN_DIR/lm-switcher-mcp" "$SRC_DIR"/mcp/*.swift "$SRC_DIR/SystemMetrics.swift" 2>"$BIN_DIR/.mcp-build.log"; then
    rm -f "$BIN_DIR/.mcp-build.log"
    echo "  ✓ MCP server: $BIN_DIR/lm-switcher-mcp"
else
    echo "  ⚠ MCP server build FAILED — app install continues."
    echo "    Log: $BIN_DIR/.mcp-build.log"
fi


# -----------------------------------------------------------------------------
# Step 2: Create the .app bundle
# -----------------------------------------------------------------------------
# A macOS .app bundle is just a directory with a specific layout:
#
#   LM Switcher.app/
#   └── Contents/
#       ├── Info.plist            (bundle metadata)
#       ├── MacOS/
#       │   └── lm-switcher       (the executable)
#       └── Resources/
#           └── AppIcon.icns       (the app icon)
#
# macOS recognizes a directory as an .app bundle by the `.app` extension
# AND a valid `Contents/Info.plist` with `CFBundlePackageType` = APPL.

echo "==> Creating app bundle in $APP_BUNDLE (visible in Launchpad)..."

# Remove any prior bundle to avoid stale files. We don't worry about
# losing any state — the app keeps state in `~/Library/Preferences`
# and the CLI keeps state in `~/.local/share/llama-menubar/`.
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$COMPILED_BIN" "$APP_BUNDLE/Contents/MacOS/lm-switcher"

# Install the app icon if we have one. The icon is generated by
# `make_icon.py` and committed to the repo at assets/AppIcon.icns. Source it
# from the repo (resolved relative to this script) so a fresh clone installs
# the icon — previously this only checked $BIN_DIR, where the icon was never
# placed, so the bundle always shipped iconless.
ICON_SRC="$SCRIPT_DIR/../assets/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "  ✓ App icon installed"
else
    echo "  (no icon found at $ICON_SRC — bundle will use the default icon)"
fi


# -----------------------------------------------------------------------------
# Step 3: Write Info.plist
# -----------------------------------------------------------------------------
# The Info.plist is the "ID card" of the .app bundle. macOS reads it
# to know the app's name, identifier, version, supported systems, etc.
# Important keys:
#   - CFBundleIdentifier   : reverse-DNS unique ID (used by Launch Services)
#   - CFBundleName         : short name (used in some places)
#   - CFBundleDisplayName  : user-visible name (Launchpad, Spotlight)
#   - CFBundleExecutable   : the binary inside Contents/MacOS/
#   - CFBundleIconFile     : the .icns filename (no extension)
#   - LSUIElement          : true = no dock icon, no Cmd-Tab entry.
#                            This is what makes us a "menu bar app".
#   - LSMinimumSystemVersion : minimum macOS version we support.
#   - NSHighResolutionCapable : allow @2x/@3x rendering.

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>lm-switcher</string>
    <key>CFBundleIdentifier</key>
    <string>local.llama-menubar</string>
    <key>CFBundleName</key>
    <string>LM Switcher</string>
    <key>CFBundleDisplayName</key>
    <string>LM Switcher</string>
    <key>CFBundleVersion</key>
    <string>1.4.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.4.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Roland Chia. All rights reserved.</string>
</dict>
</plist>
EOF


# -----------------------------------------------------------------------------
# Step 4: Codesign
# -----------------------------------------------------------------------------
# macOS requires apps to be signed. For a personal app you can use an
# "ad-hoc" signature (`--sign -`), which doesn't require a developer
# certificate. The signature lets Launchpad/Spotlight/Quarantine
# accept the app without complaints. The `--force` flag overwrites any
# existing signature.

echo "==> Ad-hoc codesigning app bundle..."
# B-4 fix: `--deep` is deprecated. For this single-binary bundle (no nested
# frameworks), sign the inner executable first, then the bundle.
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/lm-switcher" 2>/dev/null || true
codesign --force --sign - "$APP_BUNDLE" 2>/dev/null || true


# -----------------------------------------------------------------------------
# Step 5: Register with Launch Services
# -----------------------------------------------------------------------------
# `lsregister` (part of CoreServices) tells the system about the new
# .app bundle. Without this, Launchpad might not pick up the new
# app for several minutes (until the next periodic reindex). We
# pass the `-f` flag to force a fresh registration.

echo "==> Registering with Launch Services..."
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$APP_BUNDLE" 2>/dev/null || true
fi


# -----------------------------------------------------------------------------
# Step 6: Install the CLI script
# -----------------------------------------------------------------------------
# We copy the source `llama` to `~/bin/llama` (making it idempotent: if
# identical, no copy). Then we make it executable.

echo "==> Installing CLI script..."
# Copy the CLI from the repo source (audit L-8). Idempotent: skip if identical.
if ! cmp -s "$SRC_DIR/llama" "$BIN_DIR/llama" 2>/dev/null; then
    cp "$SRC_DIR/llama" "$BIN_DIR/llama"
fi
chmod +x "$BIN_DIR/llama"


# -----------------------------------------------------------------------------
# Step 7: Install the LaunchAgent
# -----------------------------------------------------------------------------
# A LaunchAgent is a per-user background service. Our plist tells
# launchd to start the menu bar app at login. The `RunAtLoad` key
# means it starts as soon as the agent is loaded; we also bootstrap
# the agent at the end of this script so the app starts now (no
# need to log out and back in).
#
# `KeepAlive = {SuccessfulExit: false}` (L-9 fix): restart the app only if
# it exits NON-zero (a crash). A clean exit (the user picks Quit, which
# calls NSApp.terminate → exit 0) is respected and the app stays closed.
# This gives crash recovery without overriding the user's explicit quit.

echo "==> Installing LaunchAgent..."
cat > "$PLIST_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.llama-menubar</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_BUNDLE/Contents/MacOS/lm-switcher</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
</dict>
</plist>
EOF

# Load the LaunchAgent now (idempotent — if already loaded, this is a no-op).
launchctl bootstrap gui/$(id -u) "$PLIST_FILE" 2>/dev/null || true


# -----------------------------------------------------------------------------
# Done!
# -----------------------------------------------------------------------------
echo ""
echo "✓ Installed!"
echo "  - App:   $APP_BUNDLE  (in Launchpad, Spotlight, /Applications area)"
echo "  - CLI:   $BIN_DIR/llama"
echo "  - Agent: $PLIST_FILE  (auto-start at login)"
echo ""
echo "To launch:"
echo "  - From Launchpad: search 'LM Switcher'"
echo "  - From Spotlight: ⌘+Space then 'LM Switcher'"
echo "  - From CLI:       llama menubar"
echo "  - Direct:         open '$APP_BUNDLE'"
echo ""
echo "Agent access (MCP) — OFF by default; enable in Settings → Global:"
echo "  hermes mcp add lm-switcher --command $BIN_DIR/lm-switcher-mcp"
echo ""
echo "To use the CLI:"
echo "  llama list"
echo "  llama load <model>"
echo "  llama switch <model>"
echo "  llama unload"
echo "  llama status"
echo ""
echo "Make sure $BIN_DIR is in your PATH."
