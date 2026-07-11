// =============================================================================
//  MenuView.swift
//  LLM Switcher — menu bar dropdown content
// =============================================================================

import SwiftUI
import AppKit


/// "6.3 GB" / "21 GB" — base-1024, one decimal below 10 (matches the MCP's
/// formatting so agent responses and the menu read the same).
func gbText(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    return gb < 10 ? String(format: "%.1f GB", gb) : String(format: "%.0f GB", gb)
}


// MARK: - Menu View

struct MenuView: View {
    @Bindable var manager: ServerManager
    @ObservedObject var settingsHost: SettingsWindowHost
    @State private var loadingIDs: Set<String> = []

    // System memory shown in the footer. Computed only while the panel is
    // open (onAppear + 3 s timer, torn down onDisappear) — zero idle cost.
    @State private var metrics: SystemMetrics? = nil
    @State private var rssByPid: [Int32: String] = [:]
    @State private var metricsTimer: Timer? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            modelScroll
            Divider()
            memoryRow
            footerRow
        }
        .frame(width: 300)
        .onAppear {
            refreshMetrics()
            let t = Timer(timeInterval: 3, repeats: true) { _ in refreshMetrics() }
            t.tolerance = 1
            RunLoop.main.add(t, forMode: .common)
            metricsTimer = t
        }
        .onDisappear {
            metricsTimer?.invalidate()
            metricsTimer = nil
        }
    }

    /// Read metrics off-main (RSS spawns one `ps` per running model),
    /// publish on main.
    private func refreshMetrics() {
        let pids = manager.models.compactMap { manager.state(for: $0).pid }
        DispatchQueue.global(qos: .utility).async {
            let m = SystemMetrics.read()
            var rss: [Int32: String] = [:]
            for pid in pids {
                if let bytes = SystemMetrics.rssBytes(pid: pid) { rss[pid] = gbText(bytes) }
            }
            DispatchQueue.main.async {
                metrics = m
                rssByPid = rss
            }
        }
    }

    // MARK: - Memory line

    /// "11 GB free of 32 · normal" — swap appears only when something is
    /// actually wrong (swap in use or pressure above normal).
    private var memoryRow: some View {
        HStack(spacing: 4) {
            if let m = metrics {
                let unwell = m.memoryPressure != "normal" || m.swapUsed > 0
                Text("\(gbText(m.ramAvailable)) free of \(gbText(m.ramTotal))")
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.secondary)
                Text(m.memoryPressure)
                    .foregroundStyle(pressureColor(m.memoryPressure))
                if unwell, m.swapUsed > 0 {
                    Text("·").foregroundStyle(.secondary)
                    Text("swap \(gbText(m.swapUsed))")
                        .foregroundStyle(m.memoryPressure == "critical" ? Color.red : Color.orange)
                }
            } else {
                Text(" ")   // reserve the row height before the first read
            }
            Spacer()
        }
        .font(.system(size: 10))
        .padding(.horizontal, 12)
        .padding(.top, 5)
        .padding(.bottom, 1)
    }

    private func pressureColor(_ level: String) -> Color {
        switch level {
        case "normal":   return .green
        case "warning":  return .orange
        case "critical": return .red
        default:         return .secondary
        }
    }

    // MARK: - Scrollable model list

    @ViewBuilder
    private var modelScroll: some View {
        let running = manager.models.filter { manager.state(for: $0).isRunning }
        let stopped  = manager.models.filter { !manager.state(for: $0).isRunning }
        let rowH: CGFloat = 28
        let sectionH: CGFloat = 26
        let bulkH: CGFloat = 32
        let hintH: CGFloat = 26

        // Compute natural height so the panel auto-sizes for short lists
        // and scrolls for long ones (capped at 320).
        let naturalH: CGFloat = {
            var h: CGFloat = 0
            if !running.isEmpty {
                h += sectionH + CGFloat(running.count) * rowH
                if running.count >= 2 { h += bulkH }
                h += 10 // divider + padding
            }
            if manager.models.isEmpty {
                h += rowH
            } else if !stopped.isEmpty {
                h += (running.isEmpty ? hintH : sectionH)
                h += CGFloat(stopped.count) * rowH
            }
            return min(max(h, 60), 320)
        }()

        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {

                // --- Running section ---
                if !running.isEmpty {
                    sectionLabel("Running")
                    ForEach(running) { model in
                        RunningRow(model: model, manager: manager,
                                   rss: manager.state(for: model).pid.flatMap { rssByPid[$0] })
                    }
                    if running.count >= 2 {
                        bulkBar(running: running)
                    }
                    Divider()
                        .padding(.vertical, 2)
                }

                // --- Available section ---
                if manager.models.isEmpty {
                    Text("No models found")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else if !stopped.isEmpty {
                    if running.isEmpty {
                        Text("Click a model to load it")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11))
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                    } else {
                        sectionLabel("Available")
                    }
                    ForEach(stopped) { model in
                        StoppedRow(model: model, manager: manager, loadingIDs: $loadingIDs)
                    }
                }
            }
            .frame(width: 300, alignment: .leading)
        }
        .frame(width: 300, height: naturalH)
    }

    // MARK: - Section label

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    // MARK: - Bulk action bar (≥2 running)

    private func bulkBar(running: [ModelEntry]) -> some View {
        let selectedRunning = running.filter { manager.selected.contains($0.id) }
        return HStack(spacing: 6) {
            Button("Unload selected (\(selectedRunning.count))") {
                manager.unloadSelected(Set(selectedRunning.map { $0.id }))
            }
            .disabled(selectedRunning.isEmpty)
            .font(.system(size: 12))
            Spacer()
            Button("Clear") { manager.selected.removeAll() }
                .disabled(manager.selected.isEmpty)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack(spacing: 0) {
            footerIconButton(symbol: "gearshape", help: "Settings") {
                settingsHost.show(manager: manager)
            }
            .keyboardShortcut(",")

            footerIconButton(symbol: "arrow.clockwise", help: "Refresh models") {
                manager.refreshModels()
            }

            footerIconButton(symbol: "stop.fill", help: "Unload all") {
                manager.unloadAll()
            }
            .disabled(!manager.anyRunning)

            Spacer()

            Button("Quit") {
                manager.unloadAll()
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
            .foregroundStyle(.secondary)
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .padding(.leading, 2)
    }

    private func footerIconButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .imageScale(.medium)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}


// MARK: - Running model row

private struct RunningRow: View {
    let model: ModelEntry
    @Bindable var manager: ServerManager
    /// Resident memory of this server process, refreshed by MenuView's
    /// metrics tick. Shown as a hover tooltip — the 300 px row is full.
    let rss: String?

    var body: some View {
        let _        = manager.refreshTrigger
        let state    = manager.state(for: model)
        let multiRun = manager.models.filter { manager.state(for: $0).isRunning }.count >= 2
        let checked  = manager.selected.contains(model.id)
        let pinned   = manager.perModelSetting("pinned", default: false, for: model)

        HStack(spacing: 8) {
            if multiRun {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .imageScale(.small)
                    .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                    .onTapGesture {
                        if checked { manager.selected.remove(model.id) }
                        else       { manager.selected.insert(model.id) }
                    }
            } else {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
            }

            Text(model.name)
                .lineLimit(1)
                .font(.system(size: 13))

            // Pin protects against agent unloads only (MCP_SPEC §3.10);
            // the user's Unload buttons ignore it.
            if pinned {
                Image(systemName: "pin.fill")
                    .imageScale(.small)
                    .foregroundStyle(Color.secondary)
                    .help("Pinned — agents cannot unload this model")
            }

            Spacer()

            backendBadge(model)

            Text(":\(String(state.port))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.green)
                .help(rss.map { "Using \($0) of RAM" } ?? "")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.green.opacity(0.07))
        .contentShape(Rectangle())
        .contextMenu {
            Button("Unload") { manager.unloadModel(model) }
            Button(pinned ? "Unpin" : "Pin") {
                manager.setPerModelSetting(!pinned, for: model, key: "pinned")
                manager.refreshTrigger += 1
            }
        }
    }
}


// MARK: - Stopped model row

private struct StoppedRow: View {
    let model: ModelEntry
    @Bindable var manager: ServerManager
    @Binding var loadingIDs: Set<String>

    var body: some View {
        let state     = manager.state(for: model)
        let isLoading = loadingIDs.contains(model.id) && !state.isRunning

        HStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .scaleEffect(0.55)
                    .frame(width: 10, height: 10)
            } else {
                Circle()
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1.5)
                    .frame(width: 7, height: 7)
            }

            Text(model.name)
                .lineLimit(1)
                .font(.system(size: 13))
                .foregroundStyle(state.lastError != nil ? Color.red : Color.secondary)

            Spacer()

            backendBadge(model)

            if let err = state.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.red)
                    .imageScale(.small)
                    .help("Failed to load: \(err)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isLoading else { return }
            startLoading()
        }
        .contextMenu {
            Button("Load") { startLoading() }
            if manager.anyRunning {
                Button("Switch to") { manager.switchModel(model) }
            }
        }
        // Clear spinner once the model is confirmed running.
        .onChange(of: state.isRunning) { _, isNow in
            if isNow { loadingIDs.remove(model.id) }
        }
        // Also clear on error (lastError set means load failed).
        .onChange(of: state.lastError) { _, err in
            if err != nil { loadingIDs.remove(model.id) }
        }
    }

    private func startLoading() {
        loadingIDs.insert(model.id)
        manager.loadModel(model)
        // Safety timeout: clear spinner if server never reports back.
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            loadingIDs.remove(model.id)
        }
    }
}


// MARK: - Shared badge helper (file-private)

private func backendBadge(_ model: ModelEntry) -> some View {
    Text(model.backend.rawValue)
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(model.backend == .mlx
                      ? Color.purple.opacity(0.15)
                      : Color.blue.opacity(0.15))
        )
        .foregroundStyle(.secondary)
}
