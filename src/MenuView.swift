// =============================================================================
//  MenuView.swift
//  LM Switcher — menu bar dropdown content
// =============================================================================

import SwiftUI
import AppKit


/// "6.3 GB" / "21 GB" — base-1024, one decimal below 10 (matches the MCP's
/// formatting so agent responses and the menu read the same).
func gbText(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    return gb < 10 ? String(format: "%.1f GB", gb) : String(format: "%.0f GB", gb)
}

func copyToClipboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

/// Quant chip ("Q4_K_M") — the #1 token users scan for when choosing
/// between variants of the same model (Phase 2).
func quantChip(_ q: String) -> some View {
    Text(q)
        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        .foregroundStyle(.secondary)
}

/// Small icon button revealed on row hover (Phase 1: the top actions stop
/// hiding behind right-click; the context menu keeps the full set).
func rowActionButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .semibold))
            .frame(width: 20, height: 18)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(help)
}


// MARK: - Menu View

struct MenuView: View {
    @Bindable var manager: ServerManager
    @ObservedObject var settingsHost: SettingsWindowHost
    @State private var loadingIDs: Set<String> = []

    // System memory shown in the footer. Computed only while the panel is
    // open (onAppear + 3 s timer, torn down onDisappear) — zero idle cost.
    @State private var metrics: SystemMetrics? = nil
    @State private var rssByPid: [Int32: UInt64] = [:]
    @State private var metricsTimer: Timer? = nil
    /// Stopped model currently hovered — its projected footprint ghosts
    /// onto the memory spine (Phase 3).
    @State private var ghostModel: ModelEntry? = nil
    /// Weights size per model id (bytes) — computed once per model, cached
    /// for the fit hint on stopped rows.
    @State private var sizeById: [String: UInt64] = [:]

    /// Transient confirmation shown after clipboard actions ("Copied …").
    @State private var toastText: String? = nil

    /// Type-to-filter text (Phase 5) — the field only appears once the
    /// library is large enough for scanning to matter.
    @State private var filterText: String = ""
    /// Toggled by the footer clock button: swaps the model list for a
    /// history of MCP agent actions, in the same 300pt surface rather
    /// than a system popover (this app avoids .popover/.sheet inside the
    /// MenuBarExtra window — they've been unreliable there).
    @State private var showingAgentFeed: Bool = false

    /// Models captured just before "Unload all", offered back via Undo.
    @State private var undoStash: [ModelEntry] = []
    @State private var undoSecondsLeft: Int = 0
    @State private var undoTimer: Timer? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            memorySpine
            Divider()
            if showingAgentFeed {
                agentFeedView
            } else {
                if manager.models.count > 10 { filterField }
                modelScroll
            }
            Divider()
            footerRow
        }
        .frame(width: 300)
        .overlay(alignment: .bottom) {
            VStack(spacing: 6) {
                if !undoStash.isEmpty {
                    undoSnackbar
                }
                if let t = toastText {
                    Text(t)
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 260)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .transition(.opacity)
                }
            }
            .padding(.bottom, 38)
            .padding(.horizontal, 12)
        }
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
    /// publish on main. Model weight sizes are computed once per model.
    private func refreshMetrics() {
        let pids = manager.models.compactMap { manager.state(for: $0).pid }
        let unsized = manager.models.filter { sizeById[$0.id] == nil }
            .map { (id: $0.id, path: $0.path, backend: $0.backend) }
        DispatchQueue.global(qos: .utility).async {
            let m = SystemMetrics.read()
            var rss: [Int32: UInt64] = [:]
            for pid in pids {
                if let bytes = SystemMetrics.rssBytes(pid: pid) { rss[pid] = bytes }
            }
            var sizes: [String: UInt64] = [:]
            let fm = FileManager.default
            for entry in unsized {
                if entry.backend == .gguf {
                    sizes[entry.id] = ((try? fm.attributesOfItem(atPath: entry.path.path))?[.size] as? UInt64) ?? 0
                } else if let files = try? fm.contentsOfDirectory(atPath: entry.path.path) {
                    sizes[entry.id] = files.filter { $0.hasSuffix(".safetensors") }.reduce(0 as UInt64) {
                        $0 + ((((try? fm.attributesOfItem(atPath: entry.path.path + "/" + $1))?[.size]) as? UInt64) ?? 0)
                    }
                }
            }
            DispatchQueue.main.async {
                metrics = m
                rssByPid = rss
                sizeById.merge(sizes) { _, new in new }
            }
        }
    }

    /// Fit hint for stopped rows: weights + 10% + compute buffer + OS
    /// headroom vs. available RAM. File-size-based (no header parse), so
    /// it under-estimates a little — a hint, not a guard.
    private func unlikelyToFit(_ model: ModelEntry) -> Bool {
        guard let m = metrics, let size = sizeById[model.id], size > 0 else { return false }
        let headroom = max(UInt64(2) << 30, m.ramTotal / 10)
        return size + size / 10 + (UInt64(512) << 20) + headroom > m.ramAvailable
    }

    // MARK: - Memory spine (redesign Phase 3)
    //
    //  A stacked bar makes "who is eating my RAM" a glance: grey =
    //  system + other apps, colored segments = your running models,
    //  track = free. Hovering a stopped model ghosts its projected
    //  footprint on — accent when it fits, red when it won't.

    /// (name, resident bytes) per running model, from the RSS tick.
    private func runningSegments() -> [(name: String, bytes: UInt64)] {
        manager.models.compactMap { m in
            let st = manager.state(for: m)
            guard st.isRunning, let pid = st.pid, let bytes = rssByPid[pid] else { return nil }
            return (parseModelName(m.name).display, bytes)
        }
    }

    /// File-size-based projection, matching the fit hint's formula
    /// (weights + 10% + compute buffer). No KV term — it's a hint.
    private func projectedBytes(_ model: ModelEntry) -> UInt64? {
        guard let size = sizeById[model.id], size > 0 else { return nil }
        return size + size / 10 + (UInt64(512) << 20)
    }

    private var memorySpine: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(metrics.map { "\(gbText($0.ramUsed)) / \(gbText($0.ramTotal))" } ?? " ")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(metrics?.memoryPressure ?? "")
                    .fontWeight(.semibold)
                    .foregroundStyle(pressureColor(metrics?.memoryPressure ?? ""))
            }
            .font(.system(size: 10))

            GeometryReader { geo in
                HStack(spacing: 0.5) {
                    if let m = metrics {
                        let total = Double(m.ramTotal)
                        let segs = runningSegments()
                        let modelSum = segs.reduce(0 as UInt64) { $0 + $1.bytes }
                        let other = m.ramUsed > modelSum ? m.ramUsed - modelSum : 0

                        barSeg(other, total: total, width: geo.size.width,
                               color: Color.secondary.opacity(0.45),
                               help: "System + other apps — \(gbText(other))")
                        ForEach(Array(segs.enumerated()), id: \.offset) { i, s in
                            barSeg(s.bytes, total: total, width: geo.size.width,
                                   color: i % 2 == 0 ? Color.blue : Color.teal,
                                   help: "\(s.name) — \(gbText(s.bytes))")
                        }
                        if let g = ghostModel, let proj = projectedBytes(g) {
                            let fits = !unlikelyToFit(g)
                            barSeg(min(proj, m.ramAvailable), total: total, width: geo.size.width,
                                   color: (fits ? Color.accentColor : Color.red).opacity(0.55),
                                   help: "Projected — \(gbText(proj))")
                        }
                    }
                }
            }
            .frame(height: 8)
            .background(Color.secondary.opacity(0.13))
            .clipShape(RoundedRectangle(cornerRadius: 4))

            memHint
                .font(.system(size: 9.5))
                .lineLimit(1)
                .frame(height: 12, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func barSeg(_ bytes: UInt64, total: Double, width: CGFloat,
                        color: Color, help: String) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: max(0, width * CGFloat(Double(bytes) / total)))
            .help(help)
    }

    @ViewBuilder
    private var memHint: some View {
        if let g = ghostModel, let proj = projectedBytes(g), let m = metrics {
            if !unlikelyToFit(g) {
                let remain = m.ramAvailable > proj ? m.ramAvailable - proj : 0
                Text("+\(gbText(proj)) if loaded → \(gbText(remain)) would remain")
                    .foregroundStyle(Color.accentColor)
            } else {
                Text("won't fit — needs \(gbText(proj)), \(gbText(m.ramAvailable)) free")
                    .foregroundStyle(Color.red)
            }
        } else if let m = metrics, m.memoryPressure != "normal" {
            // Pressure elevated: actively churning — unloading now helps.
            Text("swap \(gbText(m.swapUsed)) — unload something")
                .foregroundStyle(m.memoryPressure == "critical" ? Color.red : Color.orange)
        } else if let m = metrics, m.swapUsed > 0 {
            // Normal pressure with leftover swap: this is OTHER apps'
            // memory macOS displaced while something big was loaded —
            // not the unloaded model's (that's freed immediately on
            // exit). Nothing to unload here; it drains passively as
            // those apps touch their memory again, or clears on reboot.
            Text("swap \(gbText(m.swapUsed)) left over — clears as apps wake, or on reboot")
                .foregroundStyle(.secondary)
        } else {
            Text(" ")
        }
    }

    private func pressureColor(_ level: String) -> Color {
        switch level {
        case "normal":   return .green
        case "warning":  return .orange
        case "critical": return .red
        default:         return .secondary
        }
    }

    private func showToast(_ text: String, duration: Double = 1.8) {
        withAnimation(.easeOut(duration: 0.15)) { toastText = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            if toastText == text {
                withAnimation(.easeIn(duration: 0.25)) { toastText = nil }
            }
        }
    }

    // MARK: - Type-to-filter (Phase 5 — appears once the library is
    // large enough that scanning by eye stops being the fastest option)

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("Filter models…", text: $filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !filterText.isEmpty {
                Button { filterText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    // MARK: - Undo, not confirm (Phase 5)
    //
    //  "Unload all" has no confirmation dialog by design — the recovery
    //  path is a 5 s Undo instead of a click-through prompt that trains
    //  users to dismiss it without reading.

    private func performUnloadAllWithUndo() {
        let running = manager.models.filter { manager.state(for: $0).isRunning }
        guard !running.isEmpty else { return }
        manager.unloadAll()
        undoStash = running
        undoSecondsLeft = 5
        undoTimer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            undoSecondsLeft -= 1
            if undoSecondsLeft <= 0 {
                undoTimer?.invalidate()
                undoTimer = nil
                withAnimation { undoStash = [] }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        undoTimer = t
    }

    private func undoUnloadAll() {
        for m in undoStash { manager.loadModel(m) }
        undoTimer?.invalidate()
        undoTimer = nil
        withAnimation { undoStash = [] }
    }

    private var undoSnackbar: some View {
        HStack(spacing: 10) {
            Text("Unloaded \(undoStash.count) model\(undoStash.count == 1 ? "" : "s")")
                .font(.system(size: 11.5))
            Spacer()
            Button("Undo (\(undoSecondsLeft))") { undoUnloadAll() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .transition(.opacity)
    }

    // MARK: - Agent activity feed (Phase 5)
    //
    //  Toggled by the footer clock button in place of the model list
    //  (kept inline rather than a system .popover/.sheet — those have
    //  been unreliable inside this app's MenuBarExtra window).

    private var agentFeedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AGENT ACTIVITY")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if manager.recentAgentEvents.isEmpty {
                Text("No agent activity yet — nothing has loaded or unloaded a model.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(manager.recentAgentEvents.reversed()) { ev in
                            agentEventRow(ev)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .frame(width: 300, height: 220)
    }

    private func agentEventRow(_ ev: AgentEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ev.action == "loaded" ? "arrow.down.circle" : "arrow.up.circle")
                .font(.system(size: 11))
                .foregroundStyle(ev.action == "loaded" ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(ev.action == "loaded" ? "Loaded" : "Unloaded") \(parseModelName(ev.model).display)\(ev.port.map { " on :\($0)" } ?? "")")
                    .font(.system(size: 11.5))
                    .lineLimit(2)
                Text(relativeTime(ev.timestamp))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Scrollable model list

    private func matchesFilter(_ model: ModelEntry, _ q: String) -> Bool {
        guard !q.isEmpty else { return true }
        return parseModelName(model.name).display.lowercased().contains(q)
            || model.name.lowercased().contains(q)
    }

    @ViewBuilder
    private var modelScroll: some View {
        let q = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        let running = manager.models.filter { manager.state(for: $0).isRunning && matchesFilter($0, q) }
        let stopped  = manager.models.filter { !manager.state(for: $0).isRunning && matchesFilter($0, q) }
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
                h += 288   // first-run onboarding view
            } else if !stopped.isEmpty {
                h += (running.isEmpty ? hintH : sectionH)
                h += CGFloat(stopped.count) * rowH
                // Inline error captions add a line under failed rows.
                let errCount = stopped.filter { manager.state(for: $0).lastError != nil }.count
                h += CGFloat(errCount) * 18
            } else if running.isEmpty {
                h += rowH   // "no models match" line
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
                                   rss: manager.state(for: model).pid.flatMap { rssByPid[$0] }.map(gbText),
                                   onToast: { showToast($0) })
                    }
                    if running.count >= 2 {
                        bulkBar(running: running)
                    }
                    Divider()
                        .padding(.vertical, 2)
                }

                // --- Available section ---
                if manager.models.isEmpty {
                    firstRunView
                } else if stopped.isEmpty && running.isEmpty {
                    Text("No models match “\(filterText)”")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
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
                        let wontFit = unlikelyToFit(model)
                        StoppedRow(model: model, manager: manager, loadingIDs: $loadingIDs,
                                   unlikelyToFit: wontFit,
                                   swapWarning: wontFit ? projectedBytes(model).map {
                                       "Loading will push ~\(gbText($0)) to swap — expect slowdown"
                                   } : nil,
                                   onHoverChange: { h in
                                       if h { ghostModel = model }
                                       else if ghostModel?.id == model.id { ghostModel = nil }
                                   },
                                   onToast: { showToast($0, duration: 3.2) })
                    }
                }
            }
            .frame(width: 300, alignment: .leading)
        }
        .frame(width: 300, height: naturalH)
    }

    // MARK: - First run (empty models list)

    private var engineFound: Bool {
        let p = manager.settings.llamaServerPath
        let path = p.isEmpty ? "/opt/homebrew/bin/llama-server" : p
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// Shown when no models are discovered: Help section 1, condensed
    /// into the moment it's needed.
    private var firstRunView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Welcome to LM Switcher")
                .font(.system(size: 13, weight: .bold))
            Text("Run AI models entirely on this Mac. Three steps and you're chatting.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            stepRow(n: "1", done: engineFound, text: "Install the engine") {
                Button {
                    copyToClipboard("brew install llama.cpp")
                    showToast("Copied — paste it in Terminal")
                } label: {
                    Text("brew install llama.cpp  ⧉")
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("Click to copy")
            }
            stepRow(n: "2", done: false, text: "Download a model") {
                Group {
                    if let url = URL(string: "https://huggingface.co/models?library=gguf") {
                        Link("Free files from Hugging Face — with 16 GB RAM, grab a 9B Q4_K_M.gguf", destination: url)
                            .font(.system(size: 10))
                    }
                }
            }
            stepRow(n: "3", done: false, text: "Point the app at your downloads") {
                Text("It watches the folder — new models appear automatically")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            Button {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.prompt = "Choose"
                if panel.runModal() == .OK, let url = panel.url {
                    manager.settings.modelsDir = url.path
                    manager.saveSettings()
                    manager.refreshModels()
                    manager.startWatching()
                }
            } label: {
                Text("Choose Models Folder…")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func stepRow<Content: View>(n: String, done: Bool, text: String,
                                        @ViewBuilder detail: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(done ? "✓" : n)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 18, height: 18)
                .background(done ? Color.green : Color.secondary.opacity(0.15), in: Circle())
                .foregroundStyle(done ? Color.white : Color.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.system(size: 12, weight: .medium))
                detail()
            }
        }
        .padding(.vertical, 2)
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
                performUnloadAllWithUndo()
            }
            .disabled(!manager.anyRunning)

            footerIconButton(symbol: showingAgentFeed ? "xmark" : "clock",
                              help: showingAgentFeed ? "Back to models" : "Agent activity") {
                showingAgentFeed.toggle()
            }

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
    /// Parent toast trigger for clipboard feedback.
    let onToast: (String) -> Void

    @State private var hovering = false

    var body: some View {
        let _        = manager.refreshTrigger
        let state    = manager.state(for: model)
        let multiRun = manager.models.filter { manager.state(for: $0).isRunning }.count >= 2
        let checked  = manager.selected.contains(model.id)
        let pinned   = manager.perModelSetting("pinned", default: false, for: model)
        let parsed   = parseModelName(model.name)

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

            Text(parsed.display)
                .lineLimit(1)
                .font(.system(size: 13))
                .help(model.name)

            // Pin protects against agent unloads only (MCP_SPEC §3.10);
            // the user's Unload buttons ignore it.
            if pinned {
                Image(systemName: "pin.fill")
                    .imageScale(.small)
                    .foregroundStyle(Color.secondary)
                    .help("Pinned — agents cannot unload this model")
            }

            Spacer()

            // Hover-revealed quick actions (full set stays in the
            // context menu; this fixes its discoverability).
            if hovering {
                HStack(spacing: 1) {
                    rowActionButton("doc.on.doc", help: "Copy endpoint") {
                        copyToClipboard("http://127.0.0.1:\(state.port)/v1")
                        onToast("Copied http://127.0.0.1:\(state.port)/v1")
                    }
                    rowActionButton(pinned ? "pin.slash" : "pin",
                                    help: pinned ? "Unpin" : "Pin — agents can't unload") {
                        manager.setPerModelSetting(!pinned, for: model, key: "pinned")
                        manager.refreshTrigger += 1
                    }
                    rowActionButton("stop.fill", help: "Unload") {
                        manager.unloadModel(model)
                    }
                }
            }

            if let q = parsed.quant { quantChip(q) }

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
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Unload") { manager.unloadModel(model) }
            Button("Copy endpoint") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("http://127.0.0.1:\(state.port)/v1", forType: .string)
            }
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
    /// True when the model's weights likely exceed current free RAM —
    /// the row dims as a hint (loading stays allowed; it's not a guard).
    let unlikelyToFit: Bool
    /// Precomputed "will push ~X GB to swap" message, non-nil only when
    /// unlikelyToFit — shown as a toast the moment Load is pressed, so
    /// the consequence is visible before it happens (no confirm dialog).
    let swapWarning: String?
    /// Reports hover to MenuView so the memory spine can ghost this
    /// model's projected footprint (Phase 3).
    let onHoverChange: (Bool) -> Void
    /// Parent toast trigger, shared with RunningRow's clipboard feedback.
    let onToast: (String) -> Void

    @State private var hovering = false

    var body: some View {
        let state     = manager.state(for: model)
        let isLoading = loadingIDs.contains(model.id) && !state.isRunning
        let parsed    = parseModelName(model.name)

        VStack(alignment: .leading, spacing: 0) {
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

                Text(parsed.display)
                    .lineLimit(1)
                    .font(.system(size: 13))
                    .foregroundStyle(state.lastError != nil ? Color.red : Color.secondary)
                    .help(model.name)

                Spacer()

                if hovering && !isLoading {
                    rowActionButton("play.fill", help: "Load") { startLoading() }
                }

                // Visible tag beats opacity alone — dimming without a
                // label just reads as a broken row.
                if unlikelyToFit {
                    Text("won't fit")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.orange.opacity(0.5), lineWidth: 0.5))
                        .help("Larger than current free RAM — loading it will likely swap")
                }

                if let q = parsed.quant { quantChip(q) }

                backendBadge(model)
            }
            .opacity(unlikelyToFit ? 0.55 : 1.0)

            // Inline error: failures explain themselves under the row
            // instead of hiding behind a hover-only icon.
            if let err = state.lastError {
                Text("⚠ \(err)")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.red)
                    .lineLimit(2)
                    .padding(.leading, 15)
                    .padding(.top, 1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
            onHoverChange(h)
        }
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
        if let warning = swapWarning { onToast(warning) }
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
