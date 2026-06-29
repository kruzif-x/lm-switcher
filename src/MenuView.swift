// =============================================================================
//  MenuView.swift
//  LLM Switcher — the menu bar dropdown content
// =============================================================================
//  Extracted from the former single-file LlamaMenubarApp.swift (audit A-1).
// =============================================================================

import SwiftUI
import AppKit


// MARK: - Menu View
// -----------------------------------------------------------------------------
//  `MenuView` is the SwiftUI body of the dropdown menu that appears when the
//  user clicks the menu bar icon. It's a vertical stack of sections:
//
//      ┌─────────────────────────────────┐
//      │  ◉ 2 models loaded              │  <- header
//      │  ─────────────────────────────  │  <- divider
//      │  ☐ cerebras...                  │  <- model list (each row is
//      │  ☑ gemma-4-12B-it   [GGUF]  ●8080│    a Toggle with checkbox style)
//      │  ☐ GLM-4.7-Flash...            │
//      │  ☑ omnicoder...       [GGUF]  ●8081│
//      │  ─────────────────────────────  │
//      │  [Load Selected (2)]   [Clear]  │  <- bulk actions
//      │  ─────────────────────────────  │
//      │  [⏹ Unload All]   [↻ Refresh]  │
//      │  ─────────────────────────────  │
//      │  ● 2 on :8080, 8081            │  <- summary
//      │  ─────────────────────────────  │
//      │  ⚙ Settings…                   │
//      │  Quit                           │
//      └─────────────────────────────────┘
struct MenuView: View {
    /// The shared `ServerManager`. `@Bindable` lets us use `$manager.foo`
    /// for two-way bindings. The view is re-evaluated whenever any
    /// `@Observable` property of `manager` changes.
    @Bindable var manager: ServerManager

    /// Settings window host. Observed so SwiftUI re-renders if the window
    /// is opened/closed (mostly future-proofing; not strictly required).
    @ObservedObject var settingsHost: SettingsWindowHost

    /// The set of model IDs the user has ticked with their checkboxes.
    /// We use a local `@State` set (not a server property) because this is
    /// purely view-level state — the checkboxes reset when the menu closes.


    var body: some View {
        VStack(alignment: .leading) {
            // Header section: shows what's currently loaded.
            header

            Divider()

            // Scrollable list of all discovered models.
            modelList

            if manager.models.isEmpty {
                // Friendly message if the user has no models yet.
                Text("No models found")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            } else {
                // Bulk action row. The selection set can hold both running
                // and stopped models, so we offer two targeted actions:
                //   • Load Selected   — loads the stopped models in the set
                //   • Unload Selected — stops the running models in the set
                // This lets the user unload a chosen subset when several
                // models are loaded, without the all-or-one alternatives.
                let selectedStopped = manager.models.filter {
                    manager.selected.contains($0.id) && !manager.state(for: $0).isRunning
                }
                let selectedRunning = manager.models.filter {
                    manager.selected.contains($0.id) && manager.state(for: $0).isRunning
                }
                HStack {
                    Button("Load Selected (\(selectedStopped.count))") {
                        for m in selectedStopped {
                            manager.loadModel(m)
                        }
                    }
                    .disabled(selectedStopped.isEmpty)
                    if manager.runningCount >= 2 || !selectedRunning.isEmpty {
                        Button("Unload Selected (\(selectedRunning.count))") {
                            manager.unloadSelected(Set(selectedRunning.map { $0.id }))
                        }
                        .disabled(selectedRunning.isEmpty)
                    }
                    Spacer()
                    Button("Clear") { manager.selected.removeAll() }
                        .disabled(manager.selected.isEmpty)
                }
                .padding(.horizontal, 4)
            }

            Divider()

            // Bottom: status + actions in one compact row.
            HStack {
                Circle()
                    .fill(manager.anyRunning ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(manager.summaryText)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("↻") { manager.refreshModels() }
                    .help("Refresh models")
                Button("⏹") { manager.unloadAll() }
                    .disabled(!manager.anyRunning)
                    .help("Unload all models")
            }
            .padding(.horizontal, 4)

            Divider()

            // Bottom row: Settings, Help, About, Quit side by side.
            HStack {
                Button("⚙") { settingsHost.show(manager: manager) }
                    .keyboardShortcut(",")
                    .help("Settings")
                Button("?") { settingsHost.show(manager: manager, initialTab: 2) }
                    .help("Help")
                Button("ℹ") { settingsHost.show(manager: manager, initialTab: 3) }
                    .help("About")
                Spacer()
                Button("Quit") {
                    manager.unloadAll()
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(.horizontal, 4)
        }
        .padding(4)
    }

    /// Header text: shows the count of running models and (for multi-model
    /// scenarios) the list of currently loaded model names + ports.
    @ViewBuilder
    private var header: some View {
        // Filter the model list down to those that are currently running.
        let running = manager.models.filter { manager.state(for: $0).isRunning }

        if running.isEmpty {
            // Nothing loaded.
            Text("◌ No models loaded")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        } else if running.count == 1 {
            // One model: show its name and backend.
            Text("◉ \(running[0].name) [\(running[0].backend.rawValue)]")
                .font(.headline)
                .padding(.horizontal, 4)
        } else {
            // Multiple: show a small list of "name :port" lines.
            VStack(alignment: .leading, spacing: 2) {
                Text("◉ \(running.count) models loaded")
                    .font(.headline)
                    .padding(.horizontal, 4)
                ForEach(running, id: \.id) { m in
                    // Wrap the port in String(...) so SwiftUI's
                    // LocalizedStringKey interpolation doesn't apply the
                    // locale's number grouping (which renders 8080 as
                    // "8,080"). Same guard the model rows use below.
                    Text("  • \(m.name) [\(m.backend.rawValue)] :\(String(manager.state(for: m).port))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    /// Renders one row per model. Each row is a `Toggle` styled as a
    /// checkbox. The toggle drives both the local `selected` set (for
    /// bulk "Load Selected") and visual state.
    @ViewBuilder
    private var modelList: some View {
        ForEach(manager.models) { model in
            modelRow(for: model)
        }
    }

    /// One row of the model list: a checkbox toggle + a horizontal stack
    /// with the model's icon, name, backend badge, and a status indicator.
    ///
    /// A model is "checked" iff it's in the `selected` set. Running models
    /// are auto-added to `selected` (on load, switch, or external discovery),
    /// so they appear checked — but the user can UNCHECK a running model to
    /// exclude it from "Unload Selected" (the checkmark stays cleared because
    /// `isChecked` reads `selected` only, never `state.isRunning`).
    ///
    /// The checkbox drives the `selected` set, which feeds both bulk actions:
    /// "Load Selected" (stopped models in the set) and "Unload Selected"
    /// (running models in the set). Per-model context menu offers direct
    /// load/unload/switch. The green status dot (rendered separately below)
    /// always reflects the true running state regardless of the checkbox.
    private func modelRow(for model: ModelEntry) -> some View {
        let state = manager.state(for: model)
        // Checked == in the `selected` set. Running models are auto-added to
        // `selected` (on load/switch/external-discovery), so they show
        // checked. We deliberately do NOT OR in `state.isRunning` here:
        // doing so made a running model impossible to UNCHECK (unchecking
        // removed it from `selected`, but the getter still returned true
        // because it was still running, so the checkmark snapped back). The
        // checkbox is a selection control — unchecking a running model marks
        // it to be spared by "Unload Selected", it doesn't stop it.
        let isChecked = manager.selected.contains(model.id)

        return Toggle(isOn: Binding(
            get: { isChecked },
            set: { isOn in
                if isOn { manager.selected.insert(model.id) } else { manager.selected.remove(model.id) }
            }
        )) {
            HStack(spacing: 6) {
                // Backend icon (small, colored).
                Image(systemName: model.backend.sfSymbol)
                    .imageScale(.small)
                    .foregroundColor(model.backend == .mlx ? .purple : .blue)

                // Model name (truncates with ellipsis if too long).
                Text(model.name)
                    .lineLimit(1)

                Spacer()

                // Backend badge: a small pill with the backend name.
                Text(model.backend.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            // Light tinted background.
                            .fill(model.backend == .mlx
                                  ? Color.purple.opacity(0.2)
                                  : Color.blue.opacity(0.2))
                    )
                    .foregroundStyle(.secondary)

                // Status indicator: green filled dot + port if running,
                // hollow gray dot if not. If the last load attempt failed
                // (C-1), show a red warning triangle with the error as a
                // help tooltip so the user knows *why* it didn't start.
                if state.isRunning {
                    Image(systemName: "circle.fill")
                        .foregroundColor(.green)
                        .imageScale(.small)
                    Text(":\(String(state.port))")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                } else if let err = state.lastError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .imageScale(.small)
                        .help("Failed to load: \(err)")
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.secondary)
                        .imageScale(.small)
                }
            }
        }
        .toggleStyle(.checkbox)
        // Right-click context menu: quickly load or unload a single model
        // without going through the checkbox + "Load Selected" flow.
        .contextMenu {
            Button(state.isRunning ? "Unload" : "Load") {
                if state.isRunning { manager.unloadModel(model) }
                else { manager.loadModel(model) }
            }
            // "Switch to" — atomically unload all other models and load
            // this one. Only shown when the target isn't already running
            // and at least one other model is loaded.
            if !state.isRunning && manager.anyRunning {
                Button("Switch to") { manager.switchModel(model) }
            }
        }
    }
}


