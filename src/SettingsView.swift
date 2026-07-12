// =============================================================================
//  SettingsView.swift
//  LLM Switcher — settings window (Global / Per-Model / Help / About)
// =============================================================================

import SwiftUI
import AppKit
import UniformTypeIdentifiers


// MARK: - onChange modifier bundles (help Swift's type checker)

private struct GlobalSettingsModifier: ViewModifier {
    @Bindable var manager: ServerManager
    @Binding var modelsDir: String
    @Binding var defaultPort: String
    @Binding var defaultCtxSize: String
    @Binding var globalExtraArgs: String
    @Binding var enableMtp: Bool
    @Binding var mcpEnabled: Bool
    @Binding var allowSwapLoads: Bool
    @Binding var notifyAgentActions: Bool
    @Binding var ttlMinutesStr: String
    @Binding var kvCacheTypeK: String
    @Binding var kvCacheTypeV: String
    @Binding var flashAttention: Bool
    @Binding var thinkingEnabled: Bool
    @Binding var suppressReasoning: Bool
    @Binding var llamaServerPath: String
    @Binding var mlxServerPath: String
    @Binding var chatTemplatePath: String
    @Binding var temperature: Double
    @Binding var topP: Double
    @Binding var topK: Int
    @Binding var repeatPenalty: Double
    @Binding var seedStr: String
    @Binding var cpuThreadsStr: String
    @Binding var batchSizeStr: String
    @Binding var mlock: Bool
    @Binding var noMmap: Bool
    @Binding var mlxMaxKvSizeStr: String

    func body(content: Content) -> some View {
        content
            .modifier(ServerDefaultsModifier(manager: manager, modelsDir: $modelsDir, defaultPort: $defaultPort, defaultCtxSize: $defaultCtxSize, globalExtraArgs: $globalExtraArgs, enableMtp: $enableMtp, mcpEnabled: $mcpEnabled, allowSwapLoads: $allowSwapLoads, notifyAgentActions: $notifyAgentActions, ttlMinutesStr: $ttlMinutesStr))
            .modifier(KvCacheModifier(manager: manager, kvCacheTypeK: $kvCacheTypeK, kvCacheTypeV: $kvCacheTypeV, flashAttention: $flashAttention, thinkingEnabled: $thinkingEnabled, suppressReasoning: $suppressReasoning, llamaServerPath: $llamaServerPath, mlxServerPath: $mlxServerPath, chatTemplatePath: $chatTemplatePath))
            .modifier(PerfSamplingModifier(manager: manager, temperature: $temperature, topP: $topP, topK: $topK, repeatPenalty: $repeatPenalty, seedStr: $seedStr, cpuThreadsStr: $cpuThreadsStr, batchSizeStr: $batchSizeStr, mlock: $mlock, noMmap: $noMmap, mlxMaxKvSizeStr: $mlxMaxKvSizeStr))
    }
}

private struct ServerDefaultsModifier: ViewModifier {
    @Bindable var manager: ServerManager
    @Binding var modelsDir: String
    @Binding var defaultPort: String
    @Binding var defaultCtxSize: String
    @Binding var globalExtraArgs: String
    @Binding var enableMtp: Bool
    @Binding var mcpEnabled: Bool
    @Binding var allowSwapLoads: Bool
    @Binding var notifyAgentActions: Bool
    @Binding var ttlMinutesStr: String
    func body(content: Content) -> some View {
        content
            .onChange(of: modelsDir)      { _, v in manager.settings.modelsDir = v; manager.refreshModels(); manager.startWatching() }
            .onChange(of: defaultPort)    { _, v in if let p = Int(v), p > 0, p < 65536 { manager.settings.defaultPort = p } }
            .onChange(of: defaultCtxSize) { _, v in if let c = manager.parseCtxInput(v) { manager.settings.defaultCtxSize = c } }
            .onChange(of: globalExtraArgs){ _, v in manager.settings.globalExtraArgs = v }
            .onChange(of: enableMtp)      { _, v in manager.settings.enableMtp = v }
            .onChange(of: mcpEnabled)     { _, v in manager.settings.mcpEnabled = v }
            .onChange(of: allowSwapLoads) { _, v in manager.settings.allowSwapLoads = v }
            .onChange(of: notifyAgentActions) { _, v in manager.settings.notifyAgentActions = v }
            .onChange(of: ttlMinutesStr)  { _, v in manager.settings.ttlMinutes = Int(v) ?? 0 }
    }
}

private struct KvCacheModifier: ViewModifier {
    @Bindable var manager: ServerManager
    @Binding var kvCacheTypeK: String
    @Binding var kvCacheTypeV: String
    @Binding var flashAttention: Bool
    @Binding var thinkingEnabled: Bool
    @Binding var suppressReasoning: Bool
    @Binding var llamaServerPath: String
    @Binding var mlxServerPath: String
    @Binding var chatTemplatePath: String
    func body(content: Content) -> some View {
        content
            .onChange(of: kvCacheTypeK)      { _, v in manager.settings.kvCacheTypeK = v }
            .onChange(of: kvCacheTypeV)      { _, v in manager.settings.kvCacheTypeV = v }
            .onChange(of: flashAttention)    { _, v in manager.settings.flashAttention = v }
            .onChange(of: thinkingEnabled)   { _, v in manager.settings.thinkingEnabled = v }
            .onChange(of: suppressReasoning) { _, v in manager.settings.suppressReasoning = v }
            .onChange(of: llamaServerPath)   { _, v in manager.settings.llamaServerPath = v }
            .onChange(of: mlxServerPath)     { _, v in manager.settings.mlxServerPath = v }
            .onChange(of: chatTemplatePath)  { _, v in manager.settings.chatTemplatePath = v }
    }
}

private struct PerfSamplingModifier: ViewModifier {
    @Bindable var manager: ServerManager
    @Binding var temperature: Double
    @Binding var topP: Double
    @Binding var topK: Int
    @Binding var repeatPenalty: Double
    @Binding var seedStr: String
    @Binding var cpuThreadsStr: String
    @Binding var batchSizeStr: String
    @Binding var mlock: Bool
    @Binding var noMmap: Bool
    @Binding var mlxMaxKvSizeStr: String
    func body(content: Content) -> some View {
        content
            .onChange(of: temperature)   { _, v in manager.settings.temperature = v }
            .onChange(of: topP)          { _, v in manager.settings.topP = v }
            .onChange(of: topK)          { _, v in manager.settings.topK = v }
            .onChange(of: repeatPenalty) { _, v in manager.settings.repeatPenalty = v }
            .onChange(of: seedStr)       { _, v in manager.settings.seed = Int(v) ?? 0 }
            .modifier(PerfExtraModifier(manager: manager, cpuThreadsStr: $cpuThreadsStr, batchSizeStr: $batchSizeStr, mlock: $mlock, noMmap: $noMmap, mlxMaxKvSizeStr: $mlxMaxKvSizeStr))
    }
}

private struct PerfExtraModifier: ViewModifier {
    @Bindable var manager: ServerManager
    @Binding var cpuThreadsStr: String
    @Binding var batchSizeStr: String
    @Binding var mlock: Bool
    @Binding var noMmap: Bool
    @Binding var mlxMaxKvSizeStr: String
    func body(content: Content) -> some View {
        content
            .onChange(of: cpuThreadsStr)   { _, v in manager.settings.cpuThreads = Int(v) ?? 0 }
            .onChange(of: batchSizeStr)    { _, v in manager.settings.batchSize = Int(v) ?? 2048 }
            .onChange(of: mlock)           { _, v in manager.settings.mlock = v }
            .onChange(of: noMmap)          { _, v in manager.settings.noMmap = v }
            .onChange(of: mlxMaxKvSizeStr) { _, v in manager.settings.mlxMaxKvSize = Int(v) ?? 0 }
    }
}


// MARK: - Settings View

struct SettingsView: View {
    @Bindable var manager: ServerManager
    @State private var selectedTab: Int
    @State private var savedFeedback: Bool = false
    /// Selected model in the Per-Model master-detail view (redesign Phase 4).
    @State private var selectedModelID: String? = nil

    // Local @State mirrors of manager.settings
    @State private var modelsDir: String
    @State private var defaultPort: String
    @State private var defaultCtxSize: String
    @State private var llamaServerPath: String
    @State private var mlxServerPath: String
    @State private var globalExtraArgs: String
    @State private var chatTemplatePath: String
    @State private var enableMtp: Bool
    @State private var mcpEnabled: Bool
    @State private var allowSwapLoads: Bool
    @State private var notifyAgentActions: Bool
    @State private var ttlMinutesStr: String
    @State private var kvCacheTypeK: String
    @State private var kvCacheTypeV: String
    @State private var flashAttention: Bool
    @State private var thinkingEnabled: Bool
    @State private var suppressReasoning: Bool
    @State private var temperature: Double
    @State private var topP: Double
    @State private var topK: Int
    @State private var repeatPenalty: Double
    @State private var seedStr: String
    @State private var cpuThreadsStr: String
    @State private var batchSizeStr: String
    @State private var mlock: Bool
    @State private var noMmap: Bool
    @State private var mlxMaxKvSizeStr: String

    init(manager: ServerManager, initialTab: Int = 0) {
        self.manager = manager
        _selectedTab    = State(initialValue: initialTab)
        _modelsDir      = State(initialValue: manager.settings.modelsDir)
        _defaultPort    = State(initialValue: "\(manager.settings.defaultPort)")
        _defaultCtxSize = State(initialValue: manager.formatCtxDisplay(manager.settings.defaultCtxSize))
        _llamaServerPath  = State(initialValue: manager.settings.llamaServerPath)
        _mlxServerPath    = State(initialValue: manager.settings.mlxServerPath)
        _globalExtraArgs  = State(initialValue: manager.settings.globalExtraArgs)
        _chatTemplatePath = State(initialValue: manager.settings.chatTemplatePath)
        _enableMtp        = State(initialValue: manager.settings.enableMtp)
        _mcpEnabled       = State(initialValue: manager.settings.mcpEnabled)
        _allowSwapLoads   = State(initialValue: manager.settings.allowSwapLoads)
        _notifyAgentActions = State(initialValue: manager.settings.notifyAgentActions)
        _ttlMinutesStr    = State(initialValue: manager.settings.ttlMinutes == 0 ? "" : "\(manager.settings.ttlMinutes)")
        _kvCacheTypeK     = State(initialValue: manager.settings.kvCacheTypeK)
        _kvCacheTypeV     = State(initialValue: manager.settings.kvCacheTypeV)
        _flashAttention   = State(initialValue: manager.settings.flashAttention)
        _thinkingEnabled  = State(initialValue: manager.settings.thinkingEnabled)
        _suppressReasoning = State(initialValue: manager.settings.suppressReasoning)
        _temperature      = State(initialValue: manager.settings.temperature)
        _topP             = State(initialValue: manager.settings.topP)
        _topK             = State(initialValue: manager.settings.topK)
        _repeatPenalty    = State(initialValue: manager.settings.repeatPenalty)
        _seedStr          = State(initialValue: manager.settings.seed == 0 ? "" : "\(manager.settings.seed)")
        _cpuThreadsStr    = State(initialValue: manager.settings.cpuThreads == 0 ? "" : "\(manager.settings.cpuThreads)")
        _batchSizeStr     = State(initialValue: "\(manager.settings.batchSize)")
        _mlock            = State(initialValue: manager.settings.mlock)
        _noMmap           = State(initialValue: manager.settings.noMmap)
        _mlxMaxKvSizeStr  = State(initialValue: manager.settings.mlxMaxKvSize == 0 ? "" : "\(manager.settings.mlxMaxKvSize)")
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                globalPane
                    .tabItem { Label("Global",    systemImage: "gear") }.tag(0)
                modelsPane
                    .tabItem { Label("Per-Model", systemImage: "cube") }.tag(1)
                helpPane
                    .tabItem { Label("Help",      systemImage: "questionmark.circle") }.tag(2)
                aboutPane
                    .tabItem { Label("About",     systemImage: "info.circle") }.tag(3)
            }

            // Pinned footer — hidden on Help and About tabs
            if selectedTab < 2 {
                Divider()
                HStack {
                    Button("Restore Defaults") { restoreDefaults() }
                    Spacer()
                    if savedFeedback {
                        Text("Saved")
                            .foregroundStyle(Color.green)
                            .font(.caption)
                    }
                    Button("Save") { save() }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .frame(width: 580, height: selectedTab < 2 ? 520 : 500)
        .onReceive(NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)) { _ in
            reloadMirrors()
        }
        .modifier(GlobalSettingsModifier(
            manager: manager,
            modelsDir: $modelsDir, defaultPort: $defaultPort,
            defaultCtxSize: $defaultCtxSize, globalExtraArgs: $globalExtraArgs,
            enableMtp: $enableMtp, mcpEnabled: $mcpEnabled, allowSwapLoads: $allowSwapLoads, notifyAgentActions: $notifyAgentActions, ttlMinutesStr: $ttlMinutesStr, kvCacheTypeK: $kvCacheTypeK,
            kvCacheTypeV: $kvCacheTypeV, flashAttention: $flashAttention,
            thinkingEnabled: $thinkingEnabled, suppressReasoning: $suppressReasoning,
            llamaServerPath: $llamaServerPath, mlxServerPath: $mlxServerPath,
            chatTemplatePath: $chatTemplatePath,
            temperature: $temperature, topP: $topP, topK: $topK,
            repeatPenalty: $repeatPenalty, seedStr: $seedStr,
            cpuThreadsStr: $cpuThreadsStr, batchSizeStr: $batchSizeStr,
            mlock: $mlock, noMmap: $noMmap, mlxMaxKvSizeStr: $mlxMaxKvSizeStr))
    }

    // MARK: - Save / Restore

    private func save() {
        manager.saveSettings()
        withAnimation { savedFeedback = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { savedFeedback = false }
        }
    }

    private func restoreDefaults() {
        let d = AppSettings()
        modelsDir       = d.modelsDir
        defaultPort     = "\(d.defaultPort)"
        defaultCtxSize  = manager.formatCtxDisplay(d.defaultCtxSize)
        llamaServerPath = d.llamaServerPath
        mlxServerPath   = d.mlxServerPath
        globalExtraArgs = d.globalExtraArgs
        chatTemplatePath = d.chatTemplatePath
        enableMtp       = d.enableMtp
        mcpEnabled      = d.mcpEnabled
        allowSwapLoads  = d.allowSwapLoads
        notifyAgentActions = d.notifyAgentActions
        ttlMinutesStr   = d.ttlMinutes == 0 ? "" : "\(d.ttlMinutes)"
        kvCacheTypeK    = d.kvCacheTypeK
        kvCacheTypeV    = d.kvCacheTypeV
        flashAttention  = d.flashAttention
        thinkingEnabled = d.thinkingEnabled
        suppressReasoning = d.suppressReasoning
        temperature     = d.temperature
        topP            = d.topP
        topK            = d.topK
        repeatPenalty   = d.repeatPenalty
        seedStr         = d.seed == 0 ? "" : "\(d.seed)"
        cpuThreadsStr   = d.cpuThreads == 0 ? "" : "\(d.cpuThreads)"
        batchSizeStr    = "\(d.batchSize)"
        mlock           = d.mlock
        noMmap          = d.noMmap
        mlxMaxKvSizeStr = d.mlxMaxKvSize == 0 ? "" : "\(d.mlxMaxKvSize)"
        manager.settings = d
        manager.settings.modelsDir = modelsDir
        manager.saveSettings()
        manager.refreshModels()
        manager.startWatching()
        withAnimation { savedFeedback = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { savedFeedback = false }
        }
    }

    private func reloadMirrors() {
        manager.loadSettings()
        let s = manager.settings
        modelsDir       = s.modelsDir
        defaultPort     = "\(s.defaultPort)"
        defaultCtxSize  = manager.formatCtxDisplay(s.defaultCtxSize)
        llamaServerPath = s.llamaServerPath
        mlxServerPath   = s.mlxServerPath
        globalExtraArgs = s.globalExtraArgs
        chatTemplatePath = s.chatTemplatePath
        enableMtp       = s.enableMtp
        mcpEnabled      = s.mcpEnabled
        allowSwapLoads  = s.allowSwapLoads
        notifyAgentActions = s.notifyAgentActions
        ttlMinutesStr   = s.ttlMinutes == 0 ? "" : "\(s.ttlMinutes)"
        kvCacheTypeK    = s.kvCacheTypeK
        kvCacheTypeV    = s.kvCacheTypeV
        flashAttention  = s.flashAttention
        thinkingEnabled = s.thinkingEnabled
        suppressReasoning = s.suppressReasoning
        temperature     = s.temperature
        topP            = s.topP
        topK            = s.topK
        repeatPenalty   = s.repeatPenalty
        seedStr         = s.seed == 0 ? "" : "\(s.seed)"
        cpuThreadsStr   = s.cpuThreads == 0 ? "" : "\(s.cpuThreads)"
        batchSizeStr    = "\(s.batchSize)"
        mlock           = s.mlock
        noMmap          = s.noMmap
        mlxMaxKvSizeStr = s.mlxMaxKvSize == 0 ? "" : "\(s.mlxMaxKvSize)"
    }


    // MARK: - Global tab

    // MARK: - Global tab

    private var globalPane: some View {
        ScrollView {
            VStack(spacing: 12) {
                modelsCard
                backendsCard
                inferenceCard
                agentCard
                advancedCard
            }
            .padding(16)
        }
    }

    // MARK: - Models card

    private var modelsCard: some View {
        settingsCard(label: "Models", symbol: "folder") {
            pathRow(
                label: "Models directory",
                hint: "Root directory scanned for .gguf files and MLX model folders",
                text: $modelsDir,
                isDir: true
            ) { url in
                modelsDir = url.path
                manager.settings.modelsDir = url.path
                manager.refreshModels()
                manager.startWatching()
            }
            Divider().padding(.leading, 14)
            HStack(spacing: 0) {
                shortFieldRow(label: "Default port", placeholder: "8080", text: $defaultPort)
                    .help("Starting port. Additional models increment — 8080, 8081…")
                Divider().frame(width: 1)
                shortFieldRow(label: "Context size", placeholder: "4k", text: $defaultCtxSize)
                    .help("Context window in tokens. Accepts k-suffix (4k, 8k) or plain integers.")
                Divider().frame(width: 1)
                shortFieldRow(label: "Idle unload (min)", placeholder: "off", text: $ttlMinutesStr)
                    .help("Auto-unload GGUF models idle this long. Empty/0 = off. Pinned and MLX models exempt.")
            }
            Divider().padding(.leading, 14)
            inlineFieldRow(label: "Extra args", placeholder: "--no-mmap", text: $globalExtraArgs)
                .help("Arguments appended to every server launch.")
        }
    }

    // MARK: - Backends card

    private var backendsCard: some View {
        settingsCard(label: "Backends", symbol: "terminal") {
            pathRow(
                label: "llama-server",
                hint: "Binary for GGUF inference",
                text: $llamaServerPath,
                isDir: false
            ) { url in
                llamaServerPath = url.path
                manager.settings.llamaServerPath = url.path
            }
            Divider().padding(.leading, 14)
            pathRow(
                label: "mlx_lm.server",
                hint: "Binary for Apple MLX inference",
                text: $mlxServerPath,
                isDir: false
            ) { url in
                mlxServerPath = url.path
                manager.settings.mlxServerPath = url.path
            }
            Divider().padding(.leading, 14)
            pathRow(
                label: "Chat template",
                hint: "Custom .jinja/.json override for agentic harnesses — leave empty for built-in",
                text: $chatTemplatePath,
                isDir: false,
                placeholder: "Use built-in template",
                allowedExts: ["jinja", "json"]
            ) { url in
                chatTemplatePath = url.path
                manager.settings.chatTemplatePath = url.path
            }
        }
    }

    // MARK: - Inference card

    private var inferenceCard: some View {
        settingsCard(label: "Inference", symbol: "slider.horizontal.3") {
            toggleRow(
                label: "Flash attention",
                hint: "Reduces KV memory on Apple Silicon — no reason to disable",
                isOn: $flashAttention
            )
            Divider().padding(.leading, 14)
            toggleRow(
                label: "Thinking mode",
                hint: "Model reasons before responding — better for coding, slower",
                isOn: $thinkingEnabled
            )
            Divider().padding(.leading, 14)
            toggleRow(
                label: "Suppress reasoning",
                hint: "Hides Gemma 4 reasoning_content from clients that don't handle it",
                isOn: $suppressReasoning
            )
            Divider().padding(.leading, 14)
            toggleRow(
                label: "MTP",
                hint: "Multi-token prediction — ON by default, auto-disabled for models without MTP",
                isOn: $enableMtp,
                tint: Color.orange
            )
            Divider().padding(.leading, 14)
            toggleRow(label: "Mlock", hint: "Lock model in RAM to prevent swap — GGUF only", isOn: $mlock)
            Divider().padding(.leading, 14)
            toggleRow(label: "No-mmap", hint: "Disable memory-mapped file loading — GGUF only", isOn: $noMmap)
        }
    }

    // MARK: - Agent access card (redesign Phase 2: graduated from the
    // Inference card once it grew to three toggles + a caption)

    private var agentCard: some View {
        settingsCard(label: "Agent access (MCP)", symbol: "antenna.radiowaves.left.and.right") {
            toggleRow(
                label: "Allow agent control",
                hint: "Lets MCP-connected agents list, load, and unload models — OFF blocks all agent control",
                isOn: $mcpEnabled,
                tint: Color.purple
            )
            if mcpEnabled {
                Divider().padding(.leading, 14)
                toggleRow(
                    label: "Allow swap for agent loads",
                    hint: "OFF: agent loads that don't fit in free RAM are refused instead of swapping",
                    isOn: $allowSwapLoads
                )
                Divider().padding(.leading, 14)
                toggleRow(
                    label: "Notify on agent actions",
                    hint: "macOS notification when an agent loads or unloads a model",
                    isOn: $notifyAgentActions
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Register:  claude mcp add llm-switcher -- ~/bin/llm-switcher-mcp")
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Hermes, opencode, and other clients: see Help → 7. Agent access (MCP)")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Advanced card

    private var advancedCard: some View {
        DisclosureGroup {
            VStack(spacing: 0) {
                // KV Cache
                advSubHeader(label: "KV cache", symbol: "memorychip")
                HStack(spacing: 0) {
                    pickerRow(label: "K cache type", selection: $kvCacheTypeK, options: [
                        ("f16", "f16  (full)"), ("q8_0", "q8_0  (half)"), ("q4_0", "q4_0  (quarter)")
                    ]).help("Key cache quantization. Lower = less memory, slight quality loss.")
                    Divider().frame(width: 1)
                    pickerRow(label: "V cache type", selection: $kvCacheTypeV, options: [
                        ("f16", "f16  (full)"), ("q8_0", "q8_0  (half)"), ("q4_0", "q4_0  (quarter)")
                    ]).help("Value cache quantization. q8_0 K + q4_0 V is the Mac default.")
                }

                // Sampling
                Divider()
                advSubHeader(label: "Sampling", symbol: "dial.low")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                    shortFieldRow(label: "Temperature", placeholder: "0.8", text: Binding(
                        get: { String(format: "%.2f", temperature) },
                        set: { if let v = Double($0) { temperature = v } }
                    )).help("0.6 coding · 0.8 chat · 1.0 research")
                    Divider().frame(width: 1)
                    shortFieldRow(label: "Top-P", placeholder: "0.95", text: Binding(
                        get: { String(format: "%.2f", topP) },
                        set: { if let v = Double($0) { topP = v } }
                    )).help("Nucleus sampling threshold. 1.0 = off.")
                    Divider().frame(width: 1)
                    shortFieldRow(label: "Top-K", placeholder: "20", text: Binding(
                        get: { "\(topK)" },
                        set: { if let v = Int($0) { topK = v } }
                    )).help("Limits sampling to top K tokens. 0 = off.")
                }
                HStack(spacing: 0) {
                    shortFieldRow(label: "Repeat penalty", placeholder: "1.0", text: Binding(
                        get: { String(format: "%.2f", repeatPenalty) },
                        set: { if let v = Double($0) { repeatPenalty = v } }
                    )).help("Penalizes repeated tokens. 1.0 = off.")
                    Divider().frame(width: 1)
                    shortFieldRow(label: "Seed", placeholder: "random", text: $seedStr)
                        .help("Fixed seed for reproducible output. Empty = random.")
                }

                // Performance
                Divider()
                advSubHeader(label: "Performance  (llama-server)", symbol: "cpu")
                HStack(spacing: 0) {
                    shortFieldRow(label: "CPU threads", placeholder: "auto", text: $cpuThreadsStr)
                        .help("CPU threads for GGUF inference. Empty = auto-detect.")
                    Divider().frame(width: 1)
                    shortFieldRow(label: "Batch size", placeholder: "2048", text: $batchSizeStr)
                        .help("Prompt processing batch size.")
                }
                // MLX
                Divider()
                advSubHeader(label: "MLX", symbol: "m.square")
                shortFieldRow(label: "Max KV size", placeholder: "unlimited", text: $mlxMaxKvSizeStr)
                    .help("Caps KV cache memory for MLX. Empty = unlimited.")
            }
            .background(Color.secondary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
            )
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.below.square.filled.and.square")
                    .imageScale(.small)
                    .foregroundStyle(Color.secondary)
                Text("Advanced settings")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondary)
                Spacer()
                Text("KV cache · Sampling · Performance · MLX")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary.opacity(0.7))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }

    // MARK: - Card building blocks

    private func settingsCard<Content: View>(
        label: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .imageScale(.small)
                    .foregroundStyle(Color.secondary)
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .tracking(0.4)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.secondary.opacity(0.06))

            content()
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }

    private func advSubHeader(label: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).imageScale(.small).foregroundStyle(Color.secondary)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.secondary)
                .tracking(0.4)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.05))
    }

    private func pathRow(
        label: String,
        hint: String,
        text: Binding<String>,
        isDir: Bool,
        placeholder: String = "",
        allowedExts: [String] = [],
        onPick: @escaping (URL) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 12))
                Spacer()
                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = !isDir
                    panel.canChooseDirectories = isDir
                    panel.allowsMultipleSelection = false
                    if isDir { panel.directoryURL = URL(fileURLWithPath: text.wrappedValue) }
                    if !allowedExts.isEmpty {
                        panel.allowedContentTypes = allowedExts.compactMap { UTType(filenameExtension: $0) }
                    }
                    if panel.runModal() == .OK, let url = panel.url { onPick(url) }
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            TextField(placeholder.isEmpty ? (isDir ? "/Users/…/models" : "/usr/local/bin/…") : placeholder, text: text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(text.wrappedValue.isEmpty ? Color.secondary : Color.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func inlineFieldRow(label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).fixedSize()
            TextField(placeholder, text: text)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func shortFieldRow(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(Color.secondary)
            TextField(placeholder, text: text)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func toggleRow(label: String, hint: String, isOn: Binding<Bool>, tint: Color = Color.accentColor) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 12))
                Text(hint).font(.system(size: 11)).foregroundStyle(Color.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden()
                .tint(tint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func pickerRow(label: String, selection: Binding<String>, options: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(Color.secondary)
            Picker("", selection: selection) {
                ForEach(options, id: \.0) { tag, name in
                    Text(name).tag(tag)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }


    // MARK: - Per-Model tab (redesign Phase 4: master-detail)
    //
    //  Was a DisclosureGroup wall repeating 11 TextFields per model.
    //  Now a sidebar (running state + override-count pill) + a detail
    //  pane reusing the Global tab's row language, with per-field
    //  OVERRIDE/GLOBAL badges so "what did I customize?" reads at a
    //  glance instead of requiring a value-by-value diff against Global.

    /// The field keys that make up a model's overridable settings —
    /// shared by the sidebar's count pill and the detail rows' badges.
    private static let overrideKeys = [
        "port", "ctx", "temperature", "topP", "topK", "repeatPenalty",
        "kvCacheTypeK", "kvCacheTypeV", "thinkingEnabled", "enableMtp", "extraArgs",
    ]

    private func overrideCount(for model: ModelEntry) -> Int {
        guard manager.perModelOverrideEnabled(for: model) else { return 0 }
        return Self.overrideKeys.filter { manager.perModelSettingExists($0, for: model) }.count
    }

    private var selectedModel: ModelEntry? {
        manager.models.first(where: { $0.id == selectedModelID }) ?? manager.models.first
    }

    private var modelsPane: some View {
        Group {
            if manager.models.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "cube").font(.system(size: 26)).foregroundStyle(.secondary)
                    Text("No models found").font(.system(size: 13, weight: .medium))
                    Text("Set a Models directory in the Global tab.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    modelSidebar
                    Divider()
                    if let model = selectedModel {
                        modelDetail(for: model)
                    }
                }
            }
        }
    }

    // MARK: Sidebar

    private var modelSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(manager.models) { model in
                    sidebarRow(for: model)
                }
            }
            .padding(6)
        }
        .frame(width: 168)
        .background(Color.secondary.opacity(0.035))
    }

    private func sidebarRow(for model: ModelEntry) -> some View {
        let _ = manager.refreshTrigger
        let state = manager.state(for: model)
        let isSelected = selectedModel?.id == model.id
        let count = overrideCount(for: model)
        return HStack(spacing: 6) {
            Circle()
                .fill(state.isRunning ? Color.green : Color.clear)
                .overlay(
                    Circle().stroke(state.isRunning ? Color.clear : Color.secondary.opacity(0.5), lineWidth: 1.2)
                )
                .frame(width: 6, height: 6)
            Text(parseModelName(model.name).display)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.95) : Color.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        (isSelected ? Color.white.opacity(0.24) : Color.secondary.opacity(0.16)),
                        in: Capsule()
                    )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { selectedModelID = model.id }
    }

    // MARK: Detail

    @ViewBuilder
    private func modelActionButton(for model: ModelEntry, state: ModelState) -> some View {
        if state.isRunning {
            Button("Unload") { manager.unloadModel(model) }.controlSize(.small)
        } else if manager.switchingTo == model.id {
            Text("Switching…").font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                Button("Load") { manager.loadModel(model) }.controlSize(.small)
                if manager.anyRunning {
                    Button("Switch") { manager.switchModel(model) }.controlSize(.small)
                }
            }
        }
    }

    private func backendChip(_ backend: ModelBackend) -> some View {
        Text(backend.rawValue)
            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(backend == .mlx ? Color.purple : Color.secondary)
    }

    /// Small "OVERRIDE" / "GLOBAL" indicator — the badge language that
    /// makes per-field customization legible without a value-by-value
    /// comparison against the Global tab.
    private func overrideBadge(active: Bool) -> some View {
        Text(active ? "OVERRIDE" : "GLOBAL")
            .font(.system(size: 8, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(active ? Color.accentColor : Color.secondary.opacity(0.55))
            .frame(width: 58, alignment: .trailing)
    }

    private func overrideRow<Content: View>(
        label: String, key: String, model: ModelEntry, overrideOn: Bool,
        @ViewBuilder field: () -> Content
    ) -> some View {
        let active = overrideOn && manager.perModelSettingExists(key, for: model)
        return HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            field()
            Spacer()
            overrideBadge(active: active)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func modelDetail(for model: ModelEntry) -> some View {
        let _ = manager.refreshTrigger
        let state = manager.state(for: model)
        let overrideOn = manager.perModelOverrideEnabled(for: model)
        let parsed = parseModelName(model.name)

        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(parsed.display).font(.system(size: 14, weight: .bold)).lineLimit(1)
                    if let q = parsed.quant { quantChip(q) }
                    backendChip(model.backend)
                    Spacer()
                    modelActionButton(for: model, state: state)
                }
                Text(model.name)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)

                Divider()

                HStack {
                    Toggle(isOn: Binding<Bool>(
                        get: { overrideOn },
                        set: { newVal in
                            manager.setPerModelOverride(newVal, for: model)
                            manager.refreshTrigger += 1
                        }
                    )) { Text("Override Global Settings").font(.system(size: 12)) }
                    .toggleStyle(.switch).controlSize(.small)
                    Spacer()
                    if overrideOn {
                        Button("Reset to Global") {
                            manager.resetPerModel(for: model)
                            manager.refreshTrigger += 1
                        }
                        .controlSize(.small).foregroundStyle(Color.red)
                    }
                }

                VStack(spacing: 0) {
                    overrideRow(label: "Port", key: "port", model: model, overrideOn: overrideOn) {
                        TextField("", text: Binding<String>(
                            get: { String(format: "%d", manager.perModelPort(for: model)) },
                            set: { if let p = Int($0), p >= 0, p < 65536 { manager.setPerModelPort(p, for: model) } }
                        )).frame(width: 70).textFieldStyle(.roundedBorder).controlSize(.small).disabled(!overrideOn)
                    }
                    Divider().padding(.leading, 12)
                    overrideRow(label: "Context", key: "ctx", model: model, overrideOn: overrideOn) {
                        TextField("", text: Binding<String>(
                            get: { manager.formatCtxDisplay(manager.perModelCtxSize(for: model)) },
                            set: { if let c = manager.parseCtxInput($0) { manager.setPerModelCtxSize(c, for: model) } }
                        )).frame(width: 70).textFieldStyle(.roundedBorder).controlSize(.small).disabled(!overrideOn)
                    }
                    Divider().padding(.leading, 12)
                    overrideRow(label: "Temperature", key: "temperature", model: model, overrideOn: overrideOn) {
                        TextField("", text: Binding<String>(
                            get: { String(format: "%.2f", manager.perModelSetting("temperature", default: manager.settings.temperature, for: model) as Double) },
                            set: { if let v = Double($0) { manager.setPerModelSetting(v, for: model, key: "temperature") } }
                        )).frame(width: 60).textFieldStyle(.roundedBorder).controlSize(.small).disabled(!overrideOn)
                    }
                    Divider().padding(.leading, 12)
                    overrideRow(label: "Top-P", key: "topP", model: model, overrideOn: overrideOn) {
                        TextField("", text: Binding<String>(
                            get: { String(format: "%.2f", manager.perModelSetting("topP", default: manager.settings.topP, for: model) as Double) },
                            set: { if let v = Double($0) { manager.setPerModelSetting(v, for: model, key: "topP") } }
                        )).frame(width: 60).textFieldStyle(.roundedBorder).controlSize(.small).disabled(!overrideOn)
                    }
                    Divider().padding(.leading, 12)
                    overrideRow(label: "Top-K", key: "topK", model: model, overrideOn: overrideOn) {
                        TextField("", text: Binding<String>(
                            get: { String(format: "%d", manager.perModelSetting("topK", default: manager.settings.topK, for: model) as Int) },
                            set: { if let v = Int($0) { manager.setPerModelSetting(v, for: model, key: "topK") } }
                        )).frame(width: 60).textFieldStyle(.roundedBorder).controlSize(.small).disabled(!overrideOn)
                    }
                    Divider().padding(.leading, 12)
                    overrideRow(label: "Repeat penalty", key: "repeatPenalty", model: model, overrideOn: overrideOn) {
                        TextField("", text: Binding<String>(
                            get: { String(format: "%.2f", manager.perModelSetting("repeatPenalty", default: manager.settings.repeatPenalty, for: model) as Double) },
                            set: { if let v = Double($0) { manager.setPerModelSetting(v, for: model, key: "repeatPenalty") } }
                        )).frame(width: 60).textFieldStyle(.roundedBorder).controlSize(.small).disabled(!overrideOn)
                    }
                    Divider().padding(.leading, 12)
                    overrideRow(label: "K cache", key: "kvCacheTypeK", model: model, overrideOn: overrideOn) {
                        Picker("", selection: Binding<String>(
                            get: { manager.perModelSetting("kvCacheTypeK", default: manager.settings.kvCacheTypeK, for: model) },
                            set: { manager.setPerModelSetting($0, for: model, key: "kvCacheTypeK") }
                        )) {
                            Text("f16").tag("f16"); Text("q8_0").tag("q8_0"); Text("q4_0").tag("q4_0")
                        }.pickerStyle(.menu).frame(width: 80).controlSize(.small).disabled(!overrideOn)
                    }
                    Divider().padding(.leading, 12)
                    overrideRow(label: "V cache", key: "kvCacheTypeV", model: model, overrideOn: overrideOn) {
                        Picker("", selection: Binding<String>(
                            get: { manager.perModelSetting("kvCacheTypeV", default: manager.settings.kvCacheTypeV, for: model) },
                            set: { manager.setPerModelSetting($0, for: model, key: "kvCacheTypeV") }
                        )) {
                            Text("f16").tag("f16"); Text("q8_0").tag("q8_0"); Text("q4_0").tag("q4_0")
                        }.pickerStyle(.menu).frame(width: 80).controlSize(.small).disabled(!overrideOn)
                    }
                    Divider().padding(.leading, 12)
                    overrideRow(label: "Thinking", key: "thinkingEnabled", model: model, overrideOn: overrideOn) {
                        Toggle("", isOn: Binding<Bool>(
                            get: { manager.perModelSetting("thinkingEnabled", default: manager.settings.thinkingEnabled, for: model) },
                            set: { manager.setPerModelSetting($0, for: model, key: "thinkingEnabled") }
                        )).toggleStyle(.switch).controlSize(.small).labelsHidden().disabled(!overrideOn)
                    }
                    Divider().padding(.leading, 12)
                    overrideRow(label: "MTP", key: "enableMtp", model: model, overrideOn: overrideOn) {
                        Toggle("", isOn: Binding<Bool>(
                            get: { manager.perModelSetting("enableMtp", default: manager.settings.enableMtp, for: model) },
                            set: { manager.setPerModelSetting($0, for: model, key: "enableMtp") }
                        )).toggleStyle(.switch).controlSize(.small).labelsHidden().disabled(!overrideOn)
                    }
                    Divider().padding(.leading, 12)
                    overrideRow(label: "Extra args", key: "extraArgs", model: model, overrideOn: overrideOn) {
                        TextField("", text: Binding<String>(
                            get: { manager.perModelSetting("extraArgs", default: manager.settings.globalExtraArgs, for: model) },
                            set: { manager.setPerModelSetting($0, for: model, key: "extraArgs") }
                        )).textFieldStyle(.roundedBorder).controlSize(.small).disabled(!overrideOn)
                    }
                }
                .background(Color.secondary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                )

                if overrideOn {
                    HStack {
                        Spacer()
                        Button("Reset to Default") {
                            let d = AppSettings()
                            manager.setPerModelPort(d.defaultPort, for: model)
                            manager.setPerModelCtxSize(d.defaultCtxSize, for: model)
                            manager.setPerModelSetting(d.temperature, for: model, key: "temperature")
                            manager.setPerModelSetting(d.topP, for: model, key: "topP")
                            manager.setPerModelSetting(d.topK, for: model, key: "topK")
                            manager.setPerModelSetting(d.repeatPenalty, for: model, key: "repeatPenalty")
                            manager.setPerModelSetting(d.kvCacheTypeK, for: model, key: "kvCacheTypeK")
                            manager.setPerModelSetting(d.kvCacheTypeV, for: model, key: "kvCacheTypeV")
                            manager.setPerModelSetting(d.thinkingEnabled, for: model, key: "thinkingEnabled")
                            manager.setPerModelSetting(d.enableMtp, for: model, key: "enableMtp")
                            manager.setPerModelSetting(d.globalExtraArgs, for: model, key: "extraArgs")
                            manager.refreshTrigger += 1
                        }
                        .controlSize(.small).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
        }
    }


    // MARK: - Help tab

    private var helpPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Table of contents
                    tocSection(proxy: proxy)

                    // Sections — task-oriented: get started → daily use →
                    // tune → connect → fix. Reference material last.
                    helpSection(number: "1", title: "Getting started", id: "s1", proxy: proxy) {
                        helpEntry("LLM Switcher runs AI models entirely on your Mac.",
                                  "No account, no cloud, no data leaving your machine. You download model files; this app starts and stops them for you.",
                                  mono: false)
                        helpEntry("Step 0 — Install an engine (one-time)",
                                  "In Terminal: brew install llama.cpp — that covers GGUF models, which is all most people need. For Apple MLX models, also: pip install mlx-lm.",
                                  detail: "Paths are auto-detected; override in Global → Backends. Defaults: /opt/homebrew/bin/llama-server and the newest Python user-install of mlx_lm.server.",
                                  mono: false)
                        helpEntry("Step 1 — Download a model",
                                  "Models are free files from Hugging Face (links below). Not sure what fits your Mac? Use the table in section 5 — e.g. with 16 GB of RAM, search \"Qwen3.5 9B GGUF\" and download the file ending in Q4_K_M.gguf.",
                                  detail: "GGUF = a single .gguf file. MLX = a folder containing config.json + *.safetensors.",
                                  mono: false)
                        helpLinks([("Hugging Face — GGUF models", "https://huggingface.co/models?library=gguf"),
                                   ("MLX community", "https://huggingface.co/mlx-community")])
                        helpEntry("Step 2 — Tell the app where your models live",
                                  "Settings → Global → Models directory: pick the folder you download models into. The app watches it — new downloads appear automatically.",
                                  detail: "Scanned recursively. Hidden folders and mmproj-*/mtp-* companion files are excluded from the list on purpose — they belong to other models.",
                                  mono: false)
                        helpEntry("Step 3 — Load it",
                                  "Click the model in the menu bar dropdown. A green dot and a port number (like :8080) mean it's running.",
                                  mono: false)
                        helpEntry("Step 4 — Talk to it",
                                  "Simplest: open http://127.0.0.1:8080 in your browser — GGUF models include a built-in chat page. Or right-click the running model → Copy endpoint, and paste it into any chat app that accepts an \"OpenAI-compatible\" server (no API key needed — type anything if a key is required).",
                                  detail: "Endpoint is http://127.0.0.1:PORT/v1 — standard OpenAI chat-completions API, bound to 127.0.0.1, so other machines can't reach it.",
                                  mono: false)
                    }

                    helpSection(number: "2", title: "Everyday use", id: "s2", proxy: proxy) {
                        helpEntry("Click a model to load it; Unload to stop it.",
                                  "Each model gets its own port, so several can run at once — if they fit in memory.",
                                  mono: false)
                        helpEntry("Right-click for the good stuff.",
                                  "Running models: Unload · Copy endpoint · Pin. Stopped models: Load · Switch to.",
                                  mono: false)
                        helpEntry("Switch = swap safely.",
                                  "\"Switch to\" loads the new model first, checks it's healthy, THEN stops the others. If the new one fails, the old one keeps running.",
                                  mono: false)
                        helpEntry("Running 2+ models shows checkboxes.",
                                  "Untick the ones you want to keep, then \"Unload selected\". The ⏹ footer button stops everything at once — no confirmation dialog; you get a few seconds to Undo instead if that was a mistake. ↻ re-scans your models folder.",
                                  mono: false)
                        helpEntry("The memory bar is your dashboard.",
                                  "A stacked bar at the TOP of the menu — grey for other apps, colored segments for your running models, empty track for free RAM. Green normal = all is well. Orange warning or red critical = your Mac is running out of memory: unload something.",
                                  detail: "Refreshed every 3 s while the menu is open, same formula as Activity Monitor. Hover any segment for its name and size; hover a running model's port for that model's RAM use.",
                                  mono: false)
                        helpEntry("\"Swap left over\" ≠ unload anything.",
                                  "If you see this with a green normal state, it's memory OTHER apps got displaced while a big model was loaded — not the model you just unloaded (that memory is freed the instant it exits). It drains on its own as those apps wake up, or clears fully on reboot. Nothing to do here.",
                                  mono: false)
                        helpEntry("Hover a stopped model to preview it.",
                                  "The memory bar previews what loading that model WOULD do — a translucent segment appended to the bar, with a line underneath saying how much would be left, or that it won't fit.",
                                  mono: false)
                        helpEntry("Dimmed models probably won't fit.",
                                  "A greyed-out model, tagged \"won't fit\", is bigger than your current free memory. You can still load it, but expect serious slowdown.",
                                  mono: false)
                        helpEntry("Pin anything that must stay up.",
                                  "Pinning protects a model from automation — AI agents and idle auto-unload can't stop it. Your own Unload buttons always work.",
                                  mono: false)
                        helpEntry("Type to filter.",
                                  "Once your library gets large, a search field appears below the memory bar — type any part of a model's name to narrow the list.",
                                  mono: false)
                        helpEntry("Clock icon = agent activity.",
                                  "Shows what MCP-connected agents have loaded or unloaded while you weren't looking. Click again (now an ✕) to go back to your models.",
                                  mono: false)
                    }

                    helpSection(number: "3", title: "Settings explained", id: "s3", proxy: proxy) {
                        Group {
                            helpSub("Models card")
                            helpEntry("Models directory", "The folder the app scans for models.")
                            helpEntry("Default port", "Where the first model listens; the rest count up from it (8080, 8081, …). Change it if something else already uses 8080.")
                            helpEntry("Context size", "How much conversation the model remembers at once. 4k ≈ a few pages of text; 64k ≈ a short book. Bigger remembers more but uses more memory.",
                                      detail: "Tokens; accepts k-suffix or plain integers; passed as --ctx-size. Memory cost grows linearly — see section 5.")
                            helpEntry("Idle unload (min)", "Automatically stop models nobody has used for this many minutes. Empty = never. You get a notification when it happens; pinned models are exempt.",
                                      detail: "Activity observed via llama-server's /slots endpoint, checked ~every 30 s. GGUF only — MLX servers don't expose activity.")
                            helpEntry("Extra args", "Power-user field: anything typed here is passed to every server launch.",
                                      detail: "Quote-aware parsing; per-model extra args are appended after these.")
                        }
                        Group {
                            helpSub("Backends card")
                            helpEntry("llama-server / mlx_lm.server", "Where the two engines live. Only touch these if you installed an engine somewhere unusual.")
                            helpEntry("Chat template", "Leave empty — the model's built-in template is right for normal chat. Set a custom .jinja file only if a coding agent misbehaves with tool calls.",
                                      detail: "Passed as --chat-template-file. Needed mainly for Gemma 4 agentic use — see section 6.")
                        }
                        Group {
                            helpSub("Inference card")
                            helpEntry("Flash attention", "Faster and leaner on Apple Silicon. Leave ON.")
                            helpEntry("Thinking mode", "Whether the model reasons before answering: better code and tool use, slower replies. ON for quality, OFF for speed. Not the same as Suppress reasoning — this decides if thinking happens at all.",
                                      detail: "OFF sends --chat-template-kwargs {\"enable_thinking\":false}.")
                            helpEntry("Suppress reasoning", "Whether the thinking is SHOWN to your chat app. The model still reasons (if Thinking mode is ON); this just hides the internal monologue from apps that would crash or print it. Leave ON unless your app displays reasoning natively.",
                                      detail: "Strips Gemma 4's reasoning_content field; applied as --reasoning off --reasoning-format none.")
                            helpEntry("MTP (speed boost)", "Lets supported models write several words at a time. Leave ON; models without MTP simply ignore it.",
                                      detail: "Detected via companion mtp-*.gguf (same folder or MTP/ subfolder) or -MTP- in the filename; attached with --spec-type draft-mtp.")
                            helpEntry("Mlock", "Pins the model into RAM so macOS can never move it to disk. Only enable with plenty of spare memory. GGUF only.",
                                      detail: "Not related to \"Allow swap for agent loads\": Mlock governs the OS's treatment of a model already in memory, for every load, agent or not.")
                            helpEntry("No-mmap", "Loads the model into memory up front instead of streaming from disk. Can help on some setups; fine to ignore. GGUF only.")
                        }
                        Group {
                            helpSub("Agent access (MCP) card")
                            helpEntry("Allow agent control", "The master switch that lets AI assistants manage your models. OFF = agents are completely blocked. Turning it ON reveals the two toggles below. See section 7.")
                            helpEntry("Allow swap for agent loads", "Shown when agent control is ON. OFF: an agent load that doesn't fit in free RAM is refused, and the agent is told the largest context size that WOULD fit. ON: the load proceeds and the agent gets a swap warning.",
                                      detail: "An admission policy for agent requests only — it never changes how a loaded model is kept in memory (that's Mlock) and never affects loads you start yourself.")
                            helpEntry("Notify on agent actions", "Shown when agent control is ON. Posts a macOS notification whenever an agent loads or unloads a model — nothing happens behind your back. ON by default.")
                        }
                        Group {
                            helpSub("Advanced settings (collapsed at the bottom)")
                            helpEntry("K / V cache type", "Compresses conversation memory. The default (q8_0 + q4_0) roughly halves memory use with barely any quality loss. f16 = maximum quality, maximum memory.")
                            helpEntry("Temperature · Top-P · Top-K", "Creativity dials. Sensible temperatures: 0.6 coding, 0.8 chat, 1.0 brainstorming.",
                                      detail: "Qwen-recommended: top-p 0.95, top-k 20 across workloads.")
                            helpEntry("Repeat penalty", "Raise to 1.1–1.5 if the model gets stuck repeating itself. 1.0 = off.")
                            helpEntry("Seed", "Set a number to make output reproducible. Empty = random.")
                            helpEntry("CPU threads / Batch size", "Leave empty/default unless you know why. GGUF only.")
                            helpEntry("Max KV size (MLX)", "Caps conversation memory for MLX models. Set 4096–8192 on 16 GB Macs to avoid running out.")
                        }
                    }

                    helpSection(number: "4", title: "Per-model overrides", id: "s4", proxy: proxy) {
                        helpEntry("Pick a model on the left, then flip \"Override Global Settings\".",
                                  "The grey inherited values on the right become editable for that model only. A number badge in the sidebar shows how many fields you've actually customized.",
                                  mono: false)
                        helpEntry("OVERRIDE vs GLOBAL",
                                  "Each row is tagged: OVERRIDE means this field has its own value; GLOBAL means it's still inheriting from the Global tab, even with overrides turned on.",
                                  mono: false)
                        helpEntry("Changes apply on the next load.",
                                  "Already running? Unload and load again.",
                                  mono: false)
                        helpEntry("Two reset buttons.",
                                  "\"Reset to Global\" = inherit everything again. \"Reset to Default\" = factory values.",
                                  detail: "Overrides persist in the shared settings store, so the CLI honors them too. Per-model extra args are APPENDED to global extra args, not replacing them.",
                                  mono: false)
                    }

                    helpSection(number: "5", title: "Performance & memory", id: "s5", proxy: proxy) {
                        helpEntry("The one rule: models must fit in RAM.",
                                  "When they don't, macOS moves data to disk (\"swap\") and everything crawls. The memory line (section 2) warns you before that happens.",
                                  mono: false)
                        helpEntry("What to download for your Mac",
                                  "Model names below are examples — any similar-sized model works the same way.",
                                  mono: false)
                        Group {
                            helpEntry("8 GB",  "e.g. Qwen3.5-4B Q4_K_M — light chat only.")
                            helpEntry("16 GB", "e.g. Qwen3.5-9B Q4_K_M — the practical floor for agentic tool use.")
                            helpEntry("24 GB", "e.g. Qwen3.6-27B Q4_K_M — strong coding.")
                            helpEntry("32 GB", "e.g. Qwen3.6-35B-A3B MLX 4-bit — MoE sweet spot (~3B active per token).")
                            helpEntry("48 GB+", "e.g. Qwen3.6-27B Q6_K — the 'serious agent' quant. Q4 drifts on long tool traces.")
                            helpEntry("64 GB+", "e.g. Qwen3.6-27B Q8 — near-full precision.")
                        }
                        helpEntry("Q4? Q8? That's quantization — compression for models.",
                                  "Lower numbers = smaller and faster, slightly less precise. Q4_K_M is the everyday choice; Q6_K / Q8 when quality matters more than memory.",
                                  detail: "Model quantization is baked into the file. KV-cache quantization (Advanced settings) is separate and applies at runtime — any combination works.",
                                  mono: false)
                        helpEntry("Memory = model + conversation.",
                                  "The model file is the fixed cost; the conversation (KV cache) grows with context size. A 9B Q4_K_M at 4k context ≈ 6–7 GB total.",
                                  mono: false)
                        helpEntry("Three levers when memory is tight:",
                                  "Use a smaller quant, lower the context size, or keep KV cache at q8_0/q4_0. Idle unload (section 3) frees memory automatically when you forget.",
                                  mono: false)
                    }

                    helpSection(number: "6", title: "Vision models (Gemma 4 / Qwen2-VL)", id: "s6", proxy: proxy) {
                        helpEntry("mmproj auto-pairing",
                                  "Vision-capable models (Gemma 4, Qwen2-VL, and others) require a companion mmproj-*.gguf projection file for image processing. LLM Switcher finds and attaches it automatically — no configuration needed.")

                        // mmproj folder rules — highlighted
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Two rules for reliable auto-pairing:")
                                .font(.caption).fontWeight(.semibold)
                            Text("1. The model and its mmproj file must be in the same folder.")
                                .font(.caption)
                            Text("2. That folder must contain only one model. If multiple models share a folder, the app cannot tell which mmproj belongs to which model and may pair incorrectly.")
                                .font(.caption)
                            // Directory tree example
                            VStack(alignment: .leading, spacing: 2) {
                                Text("~/models/").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                Group {
                                    Text("  ✓  qwen2-vl-7b/                  ← one model per folder")
                                        .foregroundStyle(Color.green)
                                    Text("       qwen2-vl-7b-Q4_K_M.gguf")
                                        .foregroundStyle(.secondary)
                                    Text("       mmproj-qwen2-vl-7b-BF16.gguf")
                                        .foregroundStyle(.secondary)
                                    Text("")
                                    Text("  ✓  gemma-4-12b-it/               ← one model per folder")
                                        .foregroundStyle(Color.green)
                                    Text("       gemma-4-12b-it-Q4_K_M.gguf")
                                        .foregroundStyle(.secondary)
                                    Text("       mmproj-BF16.gguf")
                                        .foregroundStyle(.secondary)
                                    Text("")
                                    Text("  ✗  vision-models/                ← multiple models, ambiguous")
                                        .foregroundStyle(Color.red)
                                    Text("       qwen2-vl-7b-Q4_K_M.gguf")
                                        .foregroundStyle(.secondary)
                                    Text("       gemma-4-12b-it-Q4_K_M.gguf")
                                        .foregroundStyle(.secondary)
                                    Text("       mmproj-BF16.gguf            ← which model owns this?")
                                        .foregroundStyle(Color.red)
                                }
                                .font(.system(size: 11, design: .monospaced))
                            }
                            .padding(8)
                            .background(Color.secondary.opacity(0.07))
                            .cornerRadius(6)
                        }
                        .padding(.leading, 16)
                        .padding(.bottom, 8)

                        helpEntry("mtp-*.gguf exclusion", "MTP encoder heads are excluded from the model list — they are not standalone models. When MTP is ON, the app finds the head (same folder or MTP/ subfolder) and attaches it via --spec-type draft-mtp automatically.")
                        helpEntry("Reasoning suppression (Gemma 4)", "Applied automatically via --reasoning off --reasoning-format none. Turn OFF in Settings only if your client handles reasoning_content natively.")
                        helpEntry("Chat template bugs (Gemma 4)", "The standard Gemma 4 template has 4 bugs that break multi-turn tool calling. Use a custom .jinja template via Global → Backends → Chat template for agentic harnesses.")
                    }

                    helpSection(number: "7", title: "Agent access (MCP)", id: "s7", proxy: proxy) {
                        Group {
                            helpEntry("Let AI assistants drive.",
                                      "Claude Code, Hermes, opencode, and other AI agents can list, load, and switch your models themselves — your assistant says \"I need the coding model\" and makes it happen. MCP is the standard plug that makes this work.",
                                      mono: false)
                            helpLinks([("What is MCP?", "https://modelcontextprotocol.io")])
                            helpEntry("It's OFF by default, and you're always in charge.",
                                      "Nothing happens silently — every agent load/unload posts a notification. Pin any model an agent must never touch. Agents can't change your settings (read-only). Loads that would overflow memory are refused automatically unless you enable \"Allow swap for agent loads\". Flipping the toggle OFF blocks agents instantly but never stops running models.",
                                      mono: false)
                        }
                        Group {
                            helpEntry("Register — Claude Code", "One Terminal command (after turning the toggle ON):", mono: false)
                            helpCode(["claude mcp add --scope user llm-switcher -- ~/bin/llm-switcher-mcp"])
                            helpEntry("Register — Hermes", "Add under mcp_servers: in ~/.hermes/config.yaml, then restart the gateway:", mono: false)
                            helpCode(["llm-switcher:",
                                      "  command: /Users/YOU/bin/llm-switcher-mcp",
                                      "  args: []",
                                      "  timeout: 300"])
                            helpEntry("Register — anything else (opencode, pi, …)",
                                      "Configure a local/stdio MCP server with command ~/bin/llm-switcher-mcp and no arguments.",
                                      detail: "Standard JSON-RPC 2.0 over stdio. Tools: status, list_models, load_model, unload_model, unload_all, switch_model, get_settings. Every response embeds a fresh state snapshot.",
                                      mono: false)
                        }
                    }

                    helpSection(number: "8", title: "Command line (for terminal users)", id: "s8", proxy: proxy) {
                        helpEntry("Everything the menu does, scriptable.",
                                  "The llama CLI and the app share the same settings and see each other's models.",
                                  mono: false)
                        helpCode(["llama list                     all models + status",
                                  "llama load <name>              load (fuzzy match, e.g. \"qwen\")",
                                  "llama load --ctx 8192 <name>   one-off context override (not saved)",
                                  "llama unload <name> | all",
                                  "llama switch <name>            load new → verify → stop the rest",
                                  "llama status                   running models, ports, PIDs",
                                  "llama ctx <model> <size>       save a per-model context size",
                                  "llama port <model> <port>      save a per-model port",
                                  "llama menubar · uninstall · help"])
                        helpEntry("Environment overrides",
                                  "LLAMA_MODELS_DIR, LLAMA_PORT, LLAMA_CTX_SIZE, LLAMA_SERVER, MLX_SERVER.",
                                  detail: "Precedence for port/ctx: --flags → saved per-model → defaults.",
                                  mono: false)
                    }

                    helpSection(number: "9", title: "Troubleshooting & glossary", id: "s9", proxy: proxy) {
                        Group {
                            helpEntry("The list is empty",
                                      "Set the Models directory (section 1, step 2), then click ↻ Refresh. Note: mmproj-* and mtp-* files are hidden on purpose — they're companions, not models.",
                                      mono: false)
                            helpEntry("A model shows a red ⚠",
                                      "Hover it for the error. Most common: the engine isn't installed — run brew install llama.cpp (GGUF) or pip install mlx-lm (MLX).",
                                      mono: false)
                            helpEntry("It loads, then disappears",
                                      "Usually a port collision or out-of-memory. The last lines of the log say why: ~/.local/share/llama-menubar/logs/. Give the model its own port in Per-Model settings.",
                                      mono: false)
                            helpEntry("My Mac got very slow",
                                      "You're swapping. Check the memory line in the menu; unload a model or use a smaller quant (section 5).",
                                      mono: false)
                            helpEntry("The model repeats itself forever",
                                      "Advanced settings → Repeat penalty → 1.1.",
                                      mono: false)
                            helpEntry("Weird tokens or broken formatting in a coding agent",
                                      "Chat-template issue. For normal chat, leave Chat template empty. For Gemma 4 with agents, see section 6.",
                                      mono: false)
                            helpEntry("My chat app can't connect",
                                      "The model must be RUNNING (green dot), and the URL needs the /v1: http://127.0.0.1:8080/v1. Only apps on this Mac can reach it.",
                                      mono: false)
                            helpEntry("An agent says \"access disabled\"",
                                      "That's the Agent access toggle doing its job. Turn it ON in Settings → Global if you want agents in control.",
                                      mono: false)
                        }
                        Group {
                            helpSub("Mini-glossary")
                            VStack(alignment: .leading, spacing: 3) {
                                glossaryLine("Model", "the AI brain, a file you download. Bigger = more capable + more RAM.")
                                glossaryLine("GGUF / MLX", "the two model formats: single file vs. Apple-optimized folder.")
                                glossaryLine("Quantization (Q4, Q8)", "compression level of a model. Smaller = lighter, slightly less precise.")
                                glossaryLine("Token", "the word-pieces models read and write (≈ ¾ of an English word).")
                                glossaryLine("Context", "how much conversation the model can keep in mind at once.")
                                glossaryLine("KV cache", "the RAM your conversation occupies while the model runs.")
                                glossaryLine("Endpoint", "the local web address chat apps use to reach a loaded model.")
                                glossaryLine("Swap", "macOS spilling memory to disk when RAM runs out — the slowness you feel.")
                                glossaryLine("MCP / agent", "the standard plug, and the AI assistants that use it to control this app.")
                            }
                            .padding(.bottom, 8)
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
    }

    private func tocSection(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Contents")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            let items: [(String, String, String)] = [
                ("1", "s1", "Getting started"),
                ("2", "s2", "Everyday use"),
                ("3", "s3", "Settings explained"),
                ("4", "s4", "Per-model overrides"),
                ("5", "s5", "Performance & memory"),
                ("6", "s6", "Vision models"),
                ("7", "s7", "Agent access (MCP)"),
                ("8", "s8", "Command line"),
                ("9", "s9", "Troubleshooting"),
            ]

            let cols = [GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: cols, alignment: .leading, spacing: 4) {
                ForEach(items, id: \.1) { num, id, label in
                    Button {
                        withAnimation { proxy.scrollTo(id, anchor: .top) }
                    } label: {
                        HStack(spacing: 5) {
                            Text(num)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(width: 14, alignment: .trailing)
                            Text(label)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .id("toc")
    }

    private func helpSection<Content: View>(number: String, title: String, id: String, proxy: ScrollViewProxy, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(number) · \(title)".uppercased())
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
                Spacer()
                Button("↑ Contents") {
                    withAnimation { proxy.scrollTo("toc", anchor: .top) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            }
            .padding(.bottom, 2)

            content()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .id(id)
    }

    /// Two-tier help entry: a plain-language lead everyone reads, plus an
    /// optional smaller `detail` line for technical users. `mono: false`
    /// renders sentence-style leads in the regular face (setting names
    /// stay monospaced so they look like the controls they describe).
    private func helpEntry(_ key: String, _ description: String,
                           detail: String? = nil, mono: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key)
                .font(mono ? .system(.body, design: .monospaced).weight(.medium)
                           : .system(size: 12, weight: .semibold))
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text("⚙ \(detail)")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondary.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 6)
    }

    /// Card-name subheader inside a help section (MODELS, BACKENDS, …).
    private func helpSub(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.secondary.opacity(0.8))
            .tracking(0.6)
            .padding(.top, 2)
            .padding(.bottom, 4)
    }

    /// Copyable monospaced block (commands, config snippets).
    private func helpCode(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .textSelection(.enabled)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07))
        .cornerRadius(6)
        .padding(.bottom, 8)
    }

    /// One glossary line: bold term + plain definition.
    private func glossaryLine(_ term: String, _ def: String) -> some View {
        Text("\(Text(term).fontWeight(.semibold)) — \(def)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Inline external link row.
    private func helpLinks(_ links: [(String, String)]) -> some View {
        HStack(spacing: 14) {
            ForEach(Array(links.enumerated()), id: \.offset) { _, l in
                if let url = URL(string: l.1) {
                    Link(l.0, destination: url).font(.caption)
                }
            }
        }
        .padding(.bottom, 8)
    }


    // MARK: - About tab

    private var aboutPane: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Icon + title
                VStack(spacing: 8) {
                    if let img = NSImage(named: "AppIcon") {
                        Image(nsImage: img)
                            .resizable()
                            .frame(width: 72, height: 72)
                    } else {
                        Image(systemName: "cpu")
                            .font(.system(size: 48))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 72, height: 72)
                    }
                    Text("LLM Switcher")
                        .font(.title2).fontWeight(.medium)
                    Text("Version 1.2.0")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.top, 24)
                .padding(.bottom, 16)

                // Description
                VStack(alignment: .leading, spacing: 8) {
                    Text("LLM Switcher is a macOS menu bar app for running and switching between local language models without touching the terminal. It manages llama-server (GGUF) and mlx_lm.server (Apple MLX) processes on your behalf — each model gets its own port, starts on demand, and stops cleanly when you unload it.")
                        .font(.body).foregroundStyle(.secondary)
                    Text("Discovered models appear in the menu bar dropdown. Click one to load it, right-click for single-model actions, or use the bulk controls to load and unload multiple models at once. All settings — context size, KV cache, sampling, per-model overrides — are persisted and shared with the companion llama CLI, so the terminal and the app always stay in sync.")
                        .font(.body).foregroundStyle(.secondary)
                    Text("Built for Apple Silicon. Designed to stay out of your way.")
                        .font(.body).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 16)

                Divider().padding(.horizontal, 40)

                // Author
                VStack(spacing: 4) {
                    Text("Author")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .textCase(.uppercase).tracking(0.5)
                        .padding(.top, 14)
                    Text("Roland Chia").font(.headline)
                    if let url = URL(string: "mailto:z3r09er@gmail.com") {
                        Link("z3r09er@gmail.com", destination: url).font(.caption)
                    }
                    if let url = URL(string: "https://github.com/kruzif-x") {
                        Link("github.com/kruzif-x", destination: url).font(.caption)
                    }
                    if let url = URL(string: "https://x.com/rolandchia65") {
                        Link("x.com/rolandchia65", destination: url).font(.caption)
                    }
                }
                .padding(.bottom, 14)

                Divider().padding(.horizontal, 40)

                // References
                VStack(spacing: 6) {
                    Text("References")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .textCase(.uppercase).tracking(0.5)
                        .padding(.top, 14)
                    if let url = URL(string: "https://github.com/ggml-org/llama.cpp") {
                        Link("llama.cpp", destination: url).font(.caption)
                    }
                    if let url = URL(string: "https://github.com/ml-explore/mlx-examples") {
                        Link("MLX Examples", destination: url).font(.caption)
                    }
                    // MTP issue link removed — fixed in llama.cpp b9859+
                }
                .padding(.bottom, 14)

                Divider().padding(.horizontal, 40)

                // State
                VStack(spacing: 4) {
                    Text("State")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .textCase(.uppercase).tracking(0.5)
                        .padding(.top, 14)
                    Text("~/.local/share/llama-menubar/")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Text("UserDefaults: local.llama-menubar")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                .padding(.bottom, 16)

                Text("© 2026 Roland Chia · Free to use, no reselling")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
