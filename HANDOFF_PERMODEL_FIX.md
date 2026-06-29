# LLM Switcher — Per-Model Settings Bug Fix (In Progress)

## Date: 2026-06-29

## Source File
`/Users/rolandchia/Projects/llm-switcher/src/LlamaMenubarApp.swift`

## Build/Install
- Source must be copied to `~/bin/llama-menubar.swift` before running install.sh
- `cd /Users/rolandchia/Projects/llm-switcher && bash scripts/install.sh`
- Install script compiles from `~/bin/llama-menubar.swift`, NOT from `src/`
- Binary: `/Users/rolandchia/Applications/LLM Switcher.app/Contents/MacOS/llama-menubar`
- Verify changes in binary: `strings <binary> | grep "Settings apply on next"`

## Three Fixes Applied (all compiled, built, installed)

### Fix 1: "Reset to Default" button visible for all models
**File:** LlamaMenubarApp.swift, `perModelOverrideFields()` function
**Change:** Moved "Reset to Default" button OUTSIDE the `if !override / else` block so it's always visible whether override is ON or OFF. Previously it was inside the `else` (override ON) branch only.
- Line ~1681: `}` closes the `else` block
- Line ~1683-1707: "Reset to Default" `HStack` is now after the if/else, inside the outer `VStack`
- Verified in binary: `strings ... | grep "always visible"` returns 1 match

### Fix 2: Override OFF truly uses global settings
**Two changes:**

**2a. UI display (line ~1536-1551):** When override is OFF, the read-only summary now shows `manager.settings.defaultPort` and `manager.settings.defaultCtxSize` instead of `manager.perModelPort(for: model)` and `manager.perModelCtxSize(for: model)`. Previously, stale saved per-model values would show even when override was OFF.

**2b. Launch logic (line ~2271-2278 in `loadModel`):** Port and ctx now check `overrides` before reading per-model values:
```swift
let overrides = perModelOverrideEnabled(for: model)
let preferredPort = overrides ? perModelPort(for: model) : 0
let port = preferredPort > 0 ? preferredPort : nextAvailablePort()
let ctx = overrides ? perModelCtxSize(for: model) : settings.defaultCtxSize
```
Previously, per-model port/ctx were read unconditionally, so stale values leaked into the launch even with override OFF.

### Fix 3: Help section note about settings requiring reload
**File:** LlamaMenubarApp.swift, help pane `perModelOverrides` section (line ~1274)
**Change:** Updated help text to include:
- "Reset to Default" description (always visible)
- "⚠️ IMPORTANT: Per-model settings only take effect when a model is (re)loaded. If a model is already running, you must unload it and load it again for the new settings to apply. Changing settings while a model is running does NOT hot-reload — the running process keeps its original launch arguments until restarted."
- Also updated subtitle on per-model pane (line ~1441): "Settings apply on next model (re)load"

## Status: ALL THREE FIXES COMPILED AND INSTALLED

**Binary verified to contain changes:**
- `strings ... | grep "Settings apply on next"` → 1 match ✓
- `strings ... | grep "IMPORTANT"` → 1 match ✓  
- `strings ... | grep "always visible"` → 1 match ✓

## What the user reported BEFORE these fixes:
1. Not all models have "Reset to Default" button when pressed → FIXED (moved outside if/else)
2. When override toggle is OFF, fields can still be edited → FIXED (read-only shows global; launch uses global)
3. Settings only take effect after model reload → NOTE ADDED in help section

## NOT YET VERIFIED by user
The app has been rebuilt and restarted (pkill + open), but the user has not yet tested the changes. The user asked to stop and create this handoff doc before verifying.

## Key Code Locations (in src/LlamaMenubarApp.swift)
- `perModelOverrideFields()`: line ~1508 — renders the override toggle, read-only/editable fields, and Reset buttons
- `perModelCard()`: line ~1466 — the DisclosureGroup card per model
- `modelsPane`: line ~1423 — the Per-Model tab content
- `loadModel()`: line ~2260 — launch logic, reads per-model settings
- `perModelOverrideEnabled()`: line ~2041 — reads overrideEnabled from UserDefaults
- `resetPerModel()`: line ~2086 — removes ALL per-model keys (used by "Reset to Global")
- Help pane: line ~1271 — Per-Model Overrides help section
- `AppSettings`: struct with default values — used for "Reset to Default"
