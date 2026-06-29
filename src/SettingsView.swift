// =============================================================================
//  SettingsView.swift
//  LLM Switcher — the settings window (Global / Per-Model / Help / About tabs)
// =============================================================================
//  Extracted from the former single-file LlamaMenubarApp.swift (audit A-1).
// =============================================================================

import SwiftUI
import AppKit
import UniformTypeIdentifiers


// MARK: - Settings View
// -----------------------------------------------------------------------------
//  The settings window. Two tabs:
//
//    [Global]              [Per-Model]
//    ┌───────────────┐     ┌────────────────────────────┐
//    │ Models Dir    │     │ (per-model editable rows)  │
//    │ Default Port  │     │ name  backend  port  ctx  …│
//    │ Default Ctx   │     │ ...                       │
//    │ Extra Args    │     │                           │
//    │               │     │                           │
//    │ Backend paths │     │                           │
//    └───────────────┘     └────────────────────────────┘
// ViewModifier that holds all onChange handlers for global settings.
// Extracting these from the Form body helps Swift's type checker.
private struct GlobalSettingsModifier: ViewModifier {
    @Bindable var manager: ServerManager
    @Binding var modelsDir: String
    @Binding var defaultPort: String
    @Binding var defaultCtxSize: String
    @Binding var globalExtraArgs: String
    @Binding var enableMtp: Bool
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
            .modifier(ServerDefaultsModifier(manager: manager, modelsDir: $modelsDir, defaultPort: $defaultPort, defaultCtxSize: $defaultCtxSize, globalExtraArgs: $globalExtraArgs, enableMtp: $enableMtp))
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
    func body(content: Content) -> some View {
        content
            .onChange(of: modelsDir) { _, v in manager.settings.modelsDir = v; manager.refreshModels(); manager.startWatching() }
            .onChange(of: defaultPort) { _, v in if let p = Int(v), p > 0, p < 65536 { manager.settings.defaultPort = p } }
            .onChange(of: defaultCtxSize) { _, v in if let c = manager.parseCtxInput(v) { manager.settings.defaultCtxSize = c } }
            .onChange(of: globalExtraArgs) { _, v in manager.settings.globalExtraArgs = v }
            .onChange(of: enableMtp) { _, v in manager.settings.enableMtp = v }
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
            .onChange(of: kvCacheTypeK) { _, v in manager.settings.kvCacheTypeK = v }
            .onChange(of: kvCacheTypeV) { _, v in manager.settings.kvCacheTypeV = v }
            .onChange(of: flashAttention) { _, v in manager.settings.flashAttention = v }
            .onChange(of: thinkingEnabled) { _, v in manager.settings.thinkingEnabled = v }
            .onChange(of: suppressReasoning) { _, v in manager.settings.suppressReasoning = v }
            .onChange(of: llamaServerPath) { _, v in manager.settings.llamaServerPath = v }
            .onChange(of: mlxServerPath) { _, v in manager.settings.mlxServerPath = v }
            .onChange(of: chatTemplatePath) { _, v in manager.settings.chatTemplatePath = v }
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
            .onChange(of: temperature) { _, v in manager.settings.temperature = v }
            .onChange(of: topP) { _, v in manager.settings.topP = v }
            .onChange(of: topK) { _, v in manager.settings.topK = v }
            .onChange(of: repeatPenalty) { _, v in manager.settings.repeatPenalty = v }
            .onChange(of: seedStr) { _, v in manager.settings.seed = Int(v) ?? 0 }
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
            .onChange(of: cpuThreadsStr) { _, v in manager.settings.cpuThreads = Int(v) ?? 0 }
            .onChange(of: batchSizeStr) { _, v in manager.settings.batchSize = Int(v) ?? 2048 }
            .onChange(of: mlock) { _, v in manager.settings.mlock = v }
            .onChange(of: noMmap) { _, v in manager.settings.noMmap = v }
            .onChange(of: mlxMaxKvSizeStr) { _, v in manager.settings.mlxMaxKvSize = Int(v) ?? 0 }
    }
}

struct SettingsView: View {
    @Bindable var manager: ServerManager
    @State private var selectedTab: Int

    // Local @State mirrors of the manager's settings.
    @State private var modelsDir: String
    @State private var defaultPort: String
    @State private var defaultCtxSize: String
    @State private var llamaServerPath: String
    @State private var mlxServerPath: String
    @State private var globalExtraArgs: String
    @State private var chatTemplatePath: String
    @State private var enableMtp: Bool
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
    @State private var savedFeedback: Bool = false

    init(manager: ServerManager, initialTab: Int = 0) {
        self.manager = manager
        _selectedTab = State(initialValue: initialTab)
        _modelsDir = State(initialValue: manager.settings.modelsDir)
        _defaultPort = State(initialValue: "\(manager.settings.defaultPort)")
        _defaultCtxSize = State(initialValue: manager.formatCtxDisplay(manager.settings.defaultCtxSize))
        _llamaServerPath = State(initialValue: manager.settings.llamaServerPath)
        _mlxServerPath = State(initialValue: manager.settings.mlxServerPath)
        _globalExtraArgs = State(initialValue: manager.settings.globalExtraArgs)
        _chatTemplatePath = State(initialValue: manager.settings.chatTemplatePath)
        _enableMtp = State(initialValue: manager.settings.enableMtp)
        _kvCacheTypeK = State(initialValue: manager.settings.kvCacheTypeK)
        _kvCacheTypeV = State(initialValue: manager.settings.kvCacheTypeV)
        _flashAttention = State(initialValue: manager.settings.flashAttention)
        _thinkingEnabled = State(initialValue: manager.settings.thinkingEnabled)
        _suppressReasoning = State(initialValue: manager.settings.suppressReasoning)
        _temperature = State(initialValue: manager.settings.temperature)
        _topP = State(initialValue: manager.settings.topP)
        _topK = State(initialValue: manager.settings.topK)
        _repeatPenalty = State(initialValue: manager.settings.repeatPenalty)
        _seedStr = State(initialValue: manager.settings.seed == 0 ? "" : "\(manager.settings.seed)")
        _cpuThreadsStr = State(initialValue: manager.settings.cpuThreads == 0 ? "" : "\(manager.settings.cpuThreads)")
        _batchSizeStr = State(initialValue: "\(manager.settings.batchSize)")
        _mlock = State(initialValue: manager.settings.mlock)
        _noMmap = State(initialValue: manager.settings.noMmap)
        _mlxMaxKvSizeStr = State(initialValue: manager.settings.mlxMaxKvSize == 0 ? "" : "\(manager.settings.mlxMaxKvSize)")
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            globalPane.tabItem { Label("Global", systemImage: "gear") }.tag(0)
            modelsPane.tabItem { Label("Per-Model", systemImage: "cube") }.tag(1)
            helpPane.tabItem { Label("Help", systemImage: "questionmark.circle") }.tag(2)
            aboutPane.tabItem { Label("About", systemImage: "info.circle") }.tag(3)
        }
        .padding()
        .frame(width: 580, height: 520)
        // M-4 fix: re-sync the @State mirrors from UserDefaults whenever it
        // changes externally (e.g. the companion `llama` CLI runs
        // `llama ctx`/`llama port` while this window is open). Without this,
        // the text fields show stale values until the window is reopened.
        // Debounced (0.4s) because per-model field edits also write
        // UserDefaults on every keystroke — coalescing avoids reloading the
        // global mirrors (and the loadSettings disk read) on each keypress.
        .onReceive(NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)) { _ in
            reloadMirrors()
        }
    }

    /// Re-read every persisted setting from UserDefaults into the local
    /// `@State` mirrors (M-4). Called when UserDefaults changes underneath an
    /// open window. Reloads `manager.settings` from disk first so we mirror
    /// the authoritative values, not whatever was last in memory.
    private func reloadMirrors() {
        manager.loadSettings()
        let s = manager.settings
        modelsDir = s.modelsDir
        defaultPort = "\(s.defaultPort)"
        defaultCtxSize = manager.formatCtxDisplay(s.defaultCtxSize)
        llamaServerPath = s.llamaServerPath
        mlxServerPath = s.mlxServerPath
        globalExtraArgs = s.globalExtraArgs
        chatTemplatePath = s.chatTemplatePath
        enableMtp = s.enableMtp
        kvCacheTypeK = s.kvCacheTypeK
        kvCacheTypeV = s.kvCacheTypeV
        flashAttention = s.flashAttention
        thinkingEnabled = s.thinkingEnabled
        suppressReasoning = s.suppressReasoning
        temperature = s.temperature
        topP = s.topP
        topK = s.topK
        repeatPenalty = s.repeatPenalty
        seedStr = s.seed == 0 ? "" : "\(s.seed)"
        cpuThreadsStr = s.cpuThreads == 0 ? "" : "\(s.cpuThreads)"
        batchSizeStr = "\(s.batchSize)"
        mlock = s.mlock
        noMmap = s.noMmap
        mlxMaxKvSizeStr = s.mlxMaxKvSize == 0 ? "" : "\(s.mlxMaxKvSize)"
    }

    /// "Global" tab: basic settings visible by default, advanced settings
    /// hidden inside a DisclosureGroup.
    private var globalPane: some View {
        ScrollView {
            Form {
                // --- Basic settings (always visible) ---
                basicSection
                backendsSection
                chatTemplateSection

                // --- Advanced settings (collapsed by default) ---
                DisclosureGroup("Advanced Settings") {
                    kvCacheSection
                    samplingSection
                    performanceSection
                    mlxSection
                }

                // --- Save / Restore ---
                saveSection
            }
            .padding(.bottom, 8)
        }
        .modifier(GlobalSettingsModifier(manager: manager,
            modelsDir: $modelsDir, defaultPort: $defaultPort,
            defaultCtxSize: $defaultCtxSize, globalExtraArgs: $globalExtraArgs,
            enableMtp: $enableMtp, kvCacheTypeK: $kvCacheTypeK,
            kvCacheTypeV: $kvCacheTypeV, flashAttention: $flashAttention,
            thinkingEnabled: $thinkingEnabled, suppressReasoning: $suppressReasoning,
            llamaServerPath: $llamaServerPath, mlxServerPath: $mlxServerPath,
            chatTemplatePath: $chatTemplatePath,
            temperature: $temperature, topP: $topP, topK: $topK,
            repeatPenalty: $repeatPenalty, seedStr: $seedStr,
            cpuThreadsStr: $cpuThreadsStr, batchSizeStr: $batchSizeStr,
            mlock: $mlock, noMmap: $noMmap, mlxMaxKvSizeStr: $mlxMaxKvSizeStr))
    }

    // MARK: - Global pane sections (split to help Swift's type checker)

    // Basic settings: models directory, port, context size, extra args, MTP.
    private var basicSection: some View {
        Section("Server Defaults") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Models Directory:")
                HStack {
                    TextField("~/models", text: $modelsDir)
                        .help("Root directory containing your .gguf files and MLX model folders.")
                    Button("Browse…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.directoryURL = URL(fileURLWithPath: modelsDir)
                        if panel.runModal() == .OK, let url = panel.url {
                            modelsDir = url.path
                            manager.settings.modelsDir = url.path
                            manager.refreshModels()
                            manager.startWatching()
                        }
                    }
                }
            }
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Default Port:")
                    TextField("8080", text: $defaultPort)
                        .frame(width: 120)
                        .help("TCP port for the first model launched. Subsequent models increment from here.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Default Ctx Size:")
                    TextField("4k", text: $defaultCtxSize)
                        .frame(width: 120)
                        .help("Context window in tokens. Accepts k-suffix (e.g. 4k, 8k) or plain integers (8192).")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Global Extra Args:")
                TextField("--no-mmap", text: $globalExtraArgs)
                    .help("Extra CLI arguments appended to every server launch (both GGUF and MLX).")
            }
            Toggle(isOn: $enableMtp) {
                HStack(spacing: 6) {
                    Text("MTP Enable")
                    Text(enableMtp ? "ON" : "OFF")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(enableMtp ? .orange : .secondary)
                }
            }
            .toggleStyle(.switch)
            .help("Multi-Token Prediction. Enables speculative decoding for faster generation on supported models.")
        }
    }

    private var kvCacheSection: some View {
        Section("KV Cache") {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("K Cache Type:")
                    Picker("", selection: $kvCacheTypeK) {
                        Text("f16 (full)").tag("f16")
                        Text("q8_0 (half)").tag("q8_0")
                        Text("q4_0 (quarter)").tag("q4_0")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 160)
                    .help("Key cache quantization. Lower = less memory, slight quality loss.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("V Cache Type:")
                    Picker("", selection: $kvCacheTypeV) {
                        Text("f16 (full)").tag("f16")
                        Text("q8_0 (half)").tag("q8_0")
                        Text("q4_0 (quarter)").tag("q4_0")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 160)
                    .help("Value cache quantization. q8_0 K + q4_0 V is the Mac default.")
                }
            }
            Toggle(isOn: $flashAttention) {
                HStack(spacing: 6) {
                    Text("Flash Attention")
                    Text(flashAttention ? "ON" : "OFF")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(flashAttention ? .green : .secondary)
                }
            }
            .toggleStyle(.switch)
            .help("Hardware-accelerated attention. Improves speed and reduces memory on Apple Silicon.")
            Toggle(isOn: $thinkingEnabled) {
                HStack(spacing: 6) {
                    Text("Thinking Mode")
                    Text(thinkingEnabled ? "ON" : "OFF")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(thinkingEnabled ? .blue : .secondary)
                }
            }
            .toggleStyle(.switch)
            .help("ON: model reasons before responding (better for coding). OFF: faster, direct answers.")
            Toggle(isOn: $suppressReasoning) {
                HStack(spacing: 6) {
                    Text("Suppress Reasoning Content")
                    Text(suppressReasoning ? "ON" : "OFF")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(suppressReasoning ? .green : .secondary)
                }
            }
            .toggleStyle(.switch)
            .help("Suppresses Gemma 4 reasoning_content that breaks OpenAI-compatible clients.")
        }
    }

    private var samplingSection: some View {
        Section("Sampling") {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Temperature:")
                    TextField("0.8", value: $temperature, format: .number)
                        .frame(width: 80)
                        .help("Randomness: 0.6 coding / 0.8 chat / 1.0 research. Shared by both backends.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top-P:")
                    TextField("0.95", value: $topP, format: .number)
                        .frame(width: 80)
                        .help("Nucleus sampling threshold. 1.0 = off.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top-K:")
                    TextField("20", value: $topK, format: .number)
                        .frame(width: 80)
                        .help("Limits sampling to top K tokens. 0 = off.")
                }
            }
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repeat Penalty:")
                    TextField("1.0", value: $repeatPenalty, format: .number)
                        .frame(width: 80)
                        .help("Penalizes repeated tokens. 1.0 = off, 1.1 = mild.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Seed:")
                    TextField("random", text: $seedStr)
                        .frame(width: 80)
                        .help("Fixed seed for reproducible output. Empty = random.")
                }
            }
        }
    }

    private var performanceSection: some View {
        Section("Performance (llama-server)") {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CPU Threads:")
                    TextField("auto", text: $cpuThreadsStr)
                        .frame(width: 100)
                        .help("Number of CPU threads for GGUF inference. Empty = auto-detect.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Batch Size:")
                    TextField("2048", text: $batchSizeStr)
                        .frame(width: 100)
                        .help("Prompt processing batch size. Larger = faster prompt eval, more memory.")
                }
            }
            Toggle(isOn: $mlock) {
                HStack(spacing: 6) {
                    Text("Mlock")
                    Text(mlock ? "ON" : "OFF")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(mlock ? .green : .secondary)
                }
            }
            .toggleStyle(.switch)
            .help("Lock model in RAM to prevent swapping. Increases memory usage but avoids slowdowns.")
            Toggle(isOn: $noMmap) {
                HStack(spacing: 6) {
                    Text("No-MMap")
                    Text(noMmap ? "ON" : "OFF")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(noMmap ? .green : .secondary)
                }
            }
            .toggleStyle(.switch)
            .help("Disable memory-mapped file loading. Can improve speed on some systems. GGUF only.")
        }
    }

    private var mlxSection: some View {
        Section("MLX") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Max KV Size:")
                TextField("0 = unlimited", text: $mlxMaxKvSizeStr)
                    .frame(width: 120)
                    .help("Caps KV cache memory for MLX. 0 = use model default. Critical on 16GB Macs.")
            }
        }
    }

    private var chatTemplateSection: some View {
        Section("Chat Template") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Template Override:")
                HStack {
                    TextField("Leave empty for built-in template", text: $chatTemplatePath)
                        .help("Custom Jinja/JSON chat template for agentic harnesses (opencode, pi). Leave empty for built-in.")
                    Button("Browse…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        panel.allowedContentTypes = [
                            UTType(filenameExtension: "jinja") ?? .data,
                            UTType(filenameExtension: "json") ?? .data,
                            .data
                        ]
                        if panel.runModal() == .OK, let url = panel.url {
                            chatTemplatePath = url.path
                            manager.settings.chatTemplatePath = url.path
                        }
                    }
                }
            }
        }
    }

    private var backendsSection: some View {
        Section("Backends") {
            VStack(alignment: .leading, spacing: 4) {
                Text("llama-server")
                HStack {
                    TextField("", text: $llamaServerPath)
                        .help("Path to the llama-server binary for GGUF inference.")
                    Button("Browse…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            llamaServerPath = url.path
                            manager.settings.llamaServerPath = url.path
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("mlx_lm.server")
                HStack {
                    TextField("", text: $mlxServerPath)
                        .help("Path to the mlx_lm.server binary for MLX inference.")
                    Button("Browse…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            mlxServerPath = url.path
                            manager.settings.mlxServerPath = url.path
                        }
                    }
                }
            }
        }
    }

    private var saveSection: some View {
        Section {
            HStack {
                Button("Restore Defaults") {
                    let d = AppSettings()
                    modelsDir = d.modelsDir
                    defaultPort = "\(d.defaultPort)"
                    defaultCtxSize = manager.formatCtxDisplay(d.defaultCtxSize)
                    llamaServerPath = d.llamaServerPath
                    mlxServerPath = d.mlxServerPath
                    globalExtraArgs = d.globalExtraArgs
                    chatTemplatePath = d.chatTemplatePath
                    enableMtp = d.enableMtp
                    kvCacheTypeK = d.kvCacheTypeK
                    kvCacheTypeV = d.kvCacheTypeV
                    flashAttention = d.flashAttention
                    thinkingEnabled = d.thinkingEnabled
                    suppressReasoning = d.suppressReasoning
                    temperature = d.temperature
                    topP = d.topP
                    topK = d.topK
                    repeatPenalty = d.repeatPenalty
                    seedStr = d.seed == 0 ? "" : "\(d.seed)"
                    cpuThreadsStr = d.cpuThreads == 0 ? "" : "\(d.cpuThreads)"
                    batchSizeStr = "\(d.batchSize)"
                    mlock = d.mlock
                    noMmap = d.noMmap
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
                Spacer()
                Button("Save") {
                    manager.saveSettings()
                    withAnimation { savedFeedback = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { savedFeedback = false }
                    }
                }
                if savedFeedback {
                    Text("✓ Saved")
                        .foregroundColor(.green)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - Help tab

    private var helpPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Quick Start
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quick Start")
                        .font(.headline)
                    Text("1. Set your Models Directory in Global settings.\n2. Click the menu bar icon to see discovered models.\n3. Check models to load them — each runs on its own port.\n4. Use the CLI: \(Text("llama list").font(.system(.body, design: .monospaced))), \(Text("llama load <name>").font(.system(.body, design: .monospaced))), \(Text("llama status").font(.system(.body, design: .monospaced)))")
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Global Settings
                VStack(alignment: .leading, spacing: 8) {
                    Text("Global Settings")
                        .font(.headline)
                    helpRow("Models Directory", "Where LLM Switcher scans for .gguf files and MLX directories (containing .safetensors + config.json).")
                    helpRow("Default Port", "Starting port for model servers. Additional models increment from here (8080, 8081, ...).")
                    helpRow("Default Ctx Size", "Context window size in tokens. Larger = more context but more memory. Use 4k for 16GB Macs, 64k for 32GB+.")
                    helpRow("Global Extra Args", "Free-form arguments passed to every server launch. Parsed with quote handling.")
                    helpRow("MTP Enable", "Multi-Token Prediction. OFF by default — proven net loss on Apple Silicon Metal (11-92% slower). For experimentation only.")
                }

                Divider()

                // Advanced Settings
                VStack(alignment: .leading, spacing: 8) {
                    Text("Advanced Settings")
                        .font(.headline)
                    Text("All defaults below are based on community-researched best practices for macOS Apple Silicon. They are safe starting points — adjust only if you know what you're doing. Use Restore Defaults to reset everything.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)
                    helpRow("K/V Cache Type", "Quantization for KV cache memory — SEPARATE from model quantization. The model quant (Q4_K_M, Q8, etc.) is baked into the GGUF file. KV cache quant controls how the context window is stored in RAM during inference. Safe combinations: any model quant + any KV quant work together. q8_0 K + q4_0 V halves memory with minimal quality loss. f16 = full precision (use only if you have spare RAM).")
                    helpRow("Flash Attention", "Hardware-accelerated attention. Reduces memory and speeds up long context. ON by default — no downside on Apple Silicon.")
                    helpRow("Thinking Mode", "When ON, model generates reasoning tokens before responding. Better for coding, worse for latency. Qwen recommends ON for coding/tools, OFF for constrained Macs.")
                    helpRow("Suppress Reasoning", "Suppresses Gemma 4 reasoning_content that breaks OpenAI-compatible clients (opencode, pi, OpenClaw). ON by default.")
                    helpRow("MTP Enable", "Multi-Token Prediction. OFF by default — proven net loss on Apple Silicon Metal (11-92% slower). Only enable for experimentation.")
                    helpRow("Temperature", "Sampling temperature. 0.6 for coding, 0.8 for chat, 1.0 for research. Default 0.8 is the middle ground.")
                    helpRow("Top-P / Top-K", "Nucleus and top-K sampling. Top-p 0.95 + top-k 20 is the Qwen-recommended standard for all workloads.")
                    helpRow("Repeat Penalty", "Penalizes repeated tokens. 1.0 = no penalty (default), 1.1-1.5 = mild. Increase if the model loops.")
                    helpRow("Seed", "Random seed for reproducible outputs. Empty = random each run. Set a number for deterministic testing.")
                    helpRow("CPU Threads", "Threads for prompt processing. Empty = auto-detect all cores. Only limit on 8GB Macs to prevent CPU contention. GGUF only.")
                    helpRow("Batch Size", "Prompt processing batch size. Larger = faster prompt eval, more memory. Default 2048 is llama.cpp's standard. GGUF only.")
                    helpRow("Mlock", "Locks model in RAM to prevent swap. Only enable if you have spare RAM — it increases memory usage. Good for long-running sessions.")
                    helpRow("No-MMap", "Disables memory-mapped file loading. Can improve speed on NVMe. GGUF only. Note: if this toggle is ON and '--no-mmap' also appears in Global Extra Args, the duplicate is automatically stripped at load time to prevent passing the flag twice to llama-server.")
                    helpRow("Max KV Size", "Caps KV cache memory for MLX. 0 = unlimited (use model default). Set a number like 4096 on 16GB Macs to avoid OOM. MLX only.")
                }

                Divider()

                // Apple Silicon & GPU Layers
                VStack(alignment: .leading, spacing: 8) {
                    Text("Apple Silicon & GPU Layers")
                        .font(.headline)
                    Text("LLM Switcher automatically passes -ngl 99 (all GPU layers) to llama-server. On Apple Silicon, this does NOT mean offloading to a separate GPU VRAM pool — that's an NVIDIA/CUDA concept.\n\nOn Mac, the CPU and GPU share the same unified memory. The -ngl flag tells llama-server to use Metal's compute kernels (dequant + matmul) instead of the CPU path. This is 5-8x faster — without it, models fall back to CPU-only inference.\n\nThe flag name is historical from the CUDA era. On Mac it effectively means 'use Metal for compute' not 'offload to VRAM'. LLM Switcher handles this automatically — no setting needed.")
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Model Quantization Guide
                VStack(alignment: .leading, spacing: 8) {
                    Text("Model Quantization Guide")
                        .font(.headline)
                    Text("Q4_K_M, Q6_K, Q8 etc. are model weight quantization levels — baked into the GGUF file at conversion time. LLM Switcher's KV cache settings (q8_0/q4_0) are separate and control context window storage, not model weights. Any model quant works with any KV cache quant.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)
                    helpRow("8GB", "Qwen3.5-4B Q4_K_M — simple chat only, not for agent work")
                    helpRow("16GB", "Qwen3.5-9B Q4_K_M — practical floor for Hermes tool calling")
                    helpRow("16GB (tight)", "Same model, Q6_K — better tool reliability if RAM permits")
                    helpRow("24GB", "Qwen3.6-27B Q4_K_M — dense, stronger coding")
                    helpRow("32GB+", "Qwen3.6-35B-A3B MLX 4-bit — MoE sweet spot (~3B active/token)")
                    helpRow("48GB+", "Qwen3.6-27B Q6_K — the 'serious agent' quant (Q4 drifts on long tool traces)")
                    helpRow("64GB+", "Qwen3.6-27B Q8 — near-full precision")
                }

                Divider()

                // Recommended Sampling by Workload
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recommended Sampling by Workload")
                        .font(.headline)
                    Text("Based on Qwen community recommendations. Adjust Temperature to match your use case.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)
                    helpRow("Coding / tool loops", "Thinking ON, temp 0.6, top-p 0.95, top-k 20")
                    helpRow("Research / chat", "Thinking ON, temp 0.8-1.0, top-p 0.95, top-k 20")
                    helpRow("Summarization (latency matters)", "Thinking OFF, temp 0.7, top-p 0.8, top-k 20, repeat penalty 1.5")
                    helpRow("Precise structured output", "Thinking ON, temp 0.6, top-p 0.95, top-k 20")
                }

                Divider()

                // Default Values Reference
                VStack(alignment: .leading, spacing: 8) {
                    Text("Default Values Reference")
                        .font(.headline)
                    Text("These are the safe starting points LLM Switcher uses. They come from the r/hermesagent macOS megathread and llama.cpp community testing.\n\nUse Restore Defaults to reset everything to these values at any time.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)
                    helpRow("K Cache: q8_0", "Community default for Mac. Halves KV memory with minimal quality loss.")
                    helpRow("V Cache: q4_0", "More aggressive — quarters KV memory. Pair with q8_0 K for the standard Mac setup.")
                    helpRow("Flash Attention: ON", "No downside on Metal. Reduces memory and speeds up long context.")
                    helpRow("Thinking: ON", "Better for coding/tools. Turn OFF for faster responses on constrained Macs.")
                    helpRow("Suppress Reasoning: ON", "Required for Gemma 4 with OpenAI-compatible clients. Turn OFF if your client handles reasoning_content natively.")
                    helpRow("MTP: OFF", "Net loss on Metal — 11-92% slower across all tested configurations.")
                    helpRow("Temperature: 0.8", "Balanced default. 0.6 coding, 0.8 chat, 1.0 research.")
                    helpRow("Top-P: 0.95", "Qwen-recommended standard for all workloads.")
                    helpRow("Top-K: 20", "Qwen-recommended. Consistent across coding, chat, and research.")
                    helpRow("Repeat Penalty: 1.0", "No penalty. Increase to 1.1-1.5 if model repeats itself.")
                    helpRow("Batch Size: 2048", "llama.cpp default. 512 for 16GB Macs, 4096 for 32GB+.")
                    helpRow("Mlock: OFF", "Only enable with spare RAM to prevent swap death.")
                    helpRow("No-MMap: OFF", "NVMe benefit only. Leave OFF for SSDs.")
                    helpRow("Max KV Size: 0", "Unlimited. Set 4096-8192 on 16GB Macs for MLX.")
                }

                Divider()

                // CLI
                VStack(alignment: .leading, spacing: 8) {
                    Text("CLI Commands")
                        .font(.headline)
                    helpRow("llama list", "List all discovered models with load status.")
                    helpRow("llama load <name>", "Load a model by fuzzy name match.")
                    helpRow("llama unload <name…>|all", "Unload one or more models (space-separated), or all.")
                    helpRow("llama switch <name>", "Atomic switch: load new on a fresh port, verify it started, then unload the rest.")
                    helpRow("llama status", "Show running models with ports and PIDs.")
                    helpRow("llama ctx <size>", "Set per-model context size.")
                    helpRow("llama port <num>", "Set per-model port.")
                    helpRow("llama menubar", "Launch the menu bar app.")
                }

                Divider()

                // Menu bar dropdown actions
                VStack(alignment: .leading, spacing: 8) {
                    Text("Menu Bar Actions")
                        .font(.headline)
                    Text("Tick the checkbox next to any model to select it. Running models are auto-checked. The bulk action row adapts to your selection:")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)
                    helpRow("Load Selected (N)", "Loads the stopped models you've ticked. Each starts on its own free port.")
                    helpRow("Unload Selected (N)", "Stops the running models you've ticked. Appears when 2+ models are loaded — pick exactly which subset to stop, instead of all-or-one.")
                    helpRow("Clear", "Deselects everything (does not stop any model).")
                    helpRow("⏹ Unload All", "Stops every running model at once.")
                    helpRow("↻ Refresh", "Re-scans the models directory.")
                    helpRow("Right-click a model", "Load / Unload / Switch to (atomic) that single model.")
                }

                Divider()

                // Gemma 4 Specifics
                VStack(alignment: .leading, spacing: 8) {
                    Text("Gemma 4 Settings")
                        .font(.headline)
                    Text("Gemma 4 models (12B, 26B-A4B, 31B) require special handling. LLM Switcher applies all of these automatically — no manual configuration needed.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)
                    helpRow("Reasoning Suppression", "Gemma 4 emits a reasoning_content field in its output that crashes OpenAI-compatible clients (opencode, pi, OpenClaw). LLM Switcher passes --reasoning off --reasoning-format none automatically. Turn OFF in Settings only if your client handles reasoning_content natively.")
                    helpRow("mmproj Auto-Pairing", "Gemma 4 is a vision-capable model that needs a separate mmproj (multimodal projection) file for image processing. LLM Switcher finds and attaches it automatically using name-based matching, with fallback to any mmproj-*.gguf in the directory.")
                    helpRow("MTP Heads", "Some Gemma 4 QAT builds ship a separate mtp-*.gguf file. These are NOT standalone models — they're MTP encoder heads loaded automatically by llama-server from model metadata. LLM Switcher excludes them from the model list to prevent confusion.")
                    helpRow("Chat Template Bugs", "The standard Gemma 4 chat template has 4 bugs that break multi-turn tool calling: (1) broken argument formatting, (2) dropped reasoning after 3-4 turns, (3) thinking disabled by default, (4) null corruption. Use a custom .jinja template in Settings > Chat Template for agentic harnesses. Leave empty for regular chat.")
                    helpRow("QAT vs Standard", "QAT (Quantization-Aware Training) models like gemma-4-12B-it-qat-UD-Q4_K_XL.gguf have non-standard naming. The mmproj may be named mmproj-BF16.gguf instead of the standard pattern. LLM Switcher's fallback matching handles this.")
                    helpRow("Thinking Mode", "Add <think> at the start of the system prompt to enable thinking. Don't feed prior thought blocks back into history — they're stateless per turn.")
                }

                Divider()

                // mmproj & MTP
                VStack(alignment: .leading, spacing: 8) {
                    Text("Auto-Pairing & Exclusions")
                        .font(.headline)
                    Text("mmproj files are auto-paired: LLM Switcher strips quantization suffixes from the model name and finds matching mmproj-*.gguf. If name-based matching fails, it falls back to any mmproj file in the directory.\n\nmtp-*.gguf files are excluded from the model list — they're not standalone models. llama-server loads them automatically from model metadata when --mmproj is attached.")
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Per-Model Overrides
                VStack(alignment: .leading, spacing: 8) {
                    Text("Per-Model Overrides")
                        .font(.headline)
                    Text("The Per-Model tab lets you override global settings for individual models. This is useful when different models need different sampling parameters, cache settings, or extra arguments.\n\nHow it works:\n• Each model has an 'Override Global Settings' toggle\n• When OFF: the model inherits all global settings (shown as read-only gray text)\n• When ON: editable fields appear for all overridable settings\n• 'Reset to Global' clears all per-model overrides for that model\n• 'Reset to Default' (override ON) sets per-model values to factory defaults; (override OFF) purges any stored per-model values\n• Restore Defaults (global) does NOT affect per-model overrides\n\n⚠️ IMPORTANT: Per-model settings only take effect when a model is (re)loaded. If a model is already running, you must unload it and load it again for the new settings to apply. Changing settings while a model is running does NOT hot-reload — the running process keeps its original launch arguments until restarted.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)
                    helpRow("Port", "Override the port for this model. Each model runs on its own port.")
                    helpRow("Ctx Size", "Override context window size for this model. Use smaller values for constrained Macs.")
                    helpRow("Temperature", "Per-model temperature. e.g. 0.6 for coding models, 0.8 for chat models.")
                    helpRow("Top-P / Top-K", "Per-model sampling parameters. Override when a model needs different settings than the global default.")
                    helpRow("Repeat Penalty", "Per-model repeat penalty. Increase if a specific model loops or repeats.")
                    helpRow("K/V Cache Type", "Per-model KV cache quantization. Override for models that need different memory/speed tradeoffs.")
                    helpRow("Think", "Per-model thinking mode. Turn OFF for models where you want fast direct answers.")
                    helpRow("MTP", "Per-model MTP enable. Override to enable MTP for specific models while keeping it OFF globally.")
                    helpRow("Extra Args", "Per-model extra arguments. These are APPENDED to global extra args, not replaced. Use for model-specific flags.")
                }

                Divider()

                // Stale Model Cleanup
                VStack(alignment: .leading, spacing: 8) {
                    Text("Automatic Cleanup")
                        .font(.headline)
                    Text("When a model file is deleted or moved out of the models directory, LLM Switcher automatically removes all its per-model settings from UserDefaults on the next refresh. This prevents stale configuration from accumulating.\n\nPer-model settings are stored under model.<hash>.<key> in UserDefaults, where <hash> is the first 12 characters of the MD5 of the model's file path. This is stable across restarts.")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func helpRow(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - About tab

    private var aboutPane: some View {
        ScrollView {
            VStack(spacing: 16) {
                // App icon
                if let img = NSImage(named: "AppIcon") {
                    Image(nsImage: img)
                        .resizable()
                        .frame(width: 80, height: 80)
                } else {
                    Image(systemName: "cpu")
                        .font(.system(size: 56))
                        .foregroundColor(.accentColor)
                        .frame(width: 80, height: 80)
                }

                Text("LLM Switcher")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Version 1.1.0")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text("Manage local LLM models from your menu bar.\nGGUF and Apple MLX on macOS.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Divider()
                    .frame(width: 320)

                // Author
                VStack(spacing: 4) {
                    Text("Roland Chia")
                        .font(.headline)
                    if let url = URL(string: "mailto:z3r09er@gmail.com") {
                        Link("z3r09er@gmail.com", destination: url)
                            .font(.caption)
                    }
                }

                Divider()
                    .frame(width: 320)

                // References
                VStack(spacing: 6) {
                    Text("References")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    if let url = URL(string: "https://github.com/ggml-org/llama.cpp") {
                        Link("llama.cpp", destination: url)
                            .font(.caption)
                    }
                    if let url = URL(string: "https://github.com/ml-explore/mlx-examples") {
                        Link("MLX Examples", destination: url)
                            .font(.caption)
                    }
                    if let url = URL(string: "https://www.reddit.com/r/hermesagent/comments/1uc7rw5/mac_mlx_megathread_hermes_agent_on_apple_silicon/") {
                        Link("r/hermesagent macOS Megathread", destination: url)
                            .font(.caption)
                    }
                    if let url = URL(string: "https://github.com/ggml-org/llama.cpp/issues/23752") {
                        Link("MTP on Metal: Why It's Off by Default", destination: url)
                            .font(.caption)
                    }
                }

                Divider()
                    .frame(width: 320)

                // Data directory
                VStack(spacing: 4) {
                    Text("State Directory")
                        .font(.caption)
                        .fontWeight(.medium)
                    Text("~/.local/share/llama-menubar/")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text("UserDefaults: local.llama-menubar")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Spacer()
                    .frame(height: 8)

                Text("© 2026 Roland Chia. All rights reserved.")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Text("MIT License")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }

    /// "Per-Model" tab: each model shown as a DisclosureGroup card with
    /// a master "Override Global Settings" toggle. When overrides are OFF,
    /// shows a read-only summary of inherited global values (grayed).
    /// When ON, shows editable fields for all overridable settings.
    /// Each card also has a Load/Unload button and a "Reset to Global" button.
    private var modelsPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Per-Model Settings")
                    .font(.headline)
                Spacer()
            }
            // L-10 fix: removed the decorative "Save" button. Per-model
            // settings write to UserDefaults immediately on each field edit
            // (via the bindings' set: closures), so a Save button was a
            // no-op that only showed fake "✓ Saved" feedback. The note below
            // tells the user changes are auto-saved and when they take effect.
            Text("Override global settings per model · Auto-saved · Applies on next model (re)load")
                .font(.caption)
                .foregroundColor(.secondary)

            if manager.models.isEmpty {
                Text("No models found in \(manager.settings.modelsDir)")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(manager.models) { model in
                            perModelCard(for: model)
                        }
                    }
                }
            }
        }
    }

    /// One DisclosureGroup card per model. Shows:
    /// - Model name + backend icon + status + Load/Unload button (always)
    /// - "Override Global Settings" toggle
    /// - When OFF: read-only summary of inherited global values
    /// - When ON: editable fields for all overridable settings + Reset button
    private func perModelCard(for model: ModelEntry) -> some View {
        let state = manager.state(for: model)

        return DisclosureGroup {
            // Always show the override toggle + editable fields.
            // The fields are enabled/disabled based on override state.
            perModelOverrideFields(for: model)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.backend.sfSymbol)
                    .foregroundColor(model.backend == .mlx ? .purple : .blue)
                    .imageScale(.small)
                Text(model.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if state.isRunning {
                    Image(systemName: "circle.fill")
                        .foregroundColor(.green)
                        .imageScale(.small)
                    Text(":\(String(state.port))")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.secondary)
                        .imageScale(.small)
                }
                if state.isRunning {
                    Button("Unload") { manager.unloadModel(model) }
                        .controlSize(.small)
                } else if manager.switchingTo == model.id {
                    Text("Switching…").font(.caption).foregroundColor(.secondary)
                } else {
                    HStack(spacing: 4) {
                        Button("Load") { manager.loadModel(model) }
                            .controlSize(.small)
                        if manager.anyRunning {
                            Button("Switch") { manager.switchModel(model) }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Editable fields shown when overrides are ON. Includes all overridable
    /// settings plus a "Reset to Global" button.
    private func perModelOverrideFields(for model: ModelEntry) -> some View {

        // Read refreshTrigger so SwiftUI re-evaluates this view when it changes.
        // Without this, the if/else below won't update when the toggle or reset
        // buttons bump refreshTrigger (they write to UserDefaults, which SwiftUI
        // can't observe directly). Reading it here creates a dependency.
        let _ = manager.refreshTrigger

        let overrideOn = manager.perModelOverrideEnabled(for: model)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: Binding<Bool>(
                    get: { overrideOn },
                    set: { newVal in
                        manager.setPerModelOverride(newVal, for: model)
                        manager.refreshTrigger += 1
                    }
                )) {
                    Text("Override Global Settings")
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Spacer()

                if overrideOn {
                    Button("Reset to Global") {
                        manager.resetPerModel(for: model)
                        manager.refreshTrigger += 1
                    }
                    .controlSize(.small)
                    .foregroundColor(.red)
                }
            }

            if !overrideOn {
                // Read-only inherited GLOBAL values (not stale per-model saved values).
                // Use String(format:) to avoid comma separators.
                HStack(spacing: 16) {
                    Text("Port: \(String(format: "%d", manager.settings.defaultPort))").font(.caption2).foregroundColor(.secondary)
                    Text("Ctx: \(manager.formatCtxDisplay(manager.settings.defaultCtxSize))").font(.caption2).foregroundColor(.secondary)
                    Text("Temp: \(manager.settings.temperature)").font(.caption2).foregroundColor(.secondary)
                    Text("Top-P: \(manager.settings.topP)").font(.caption2).foregroundColor(.secondary)
                    Text("Top-K: \(manager.settings.topK)").font(.caption2).foregroundColor(.secondary)
                    Text("RP: \(manager.settings.repeatPenalty)").font(.caption2).foregroundColor(.secondary)
                }
                HStack(spacing: 16) {
                    Text("K: \(manager.settings.kvCacheTypeK)").font(.caption2).foregroundColor(.secondary)
                    Text("V: \(manager.settings.kvCacheTypeV)").font(.caption2).foregroundColor(.secondary)
                    Text("Think: \(manager.settings.thinkingEnabled ? "ON" : "OFF")").font(.caption2).foregroundColor(.secondary)
                    Text("MTP: \(manager.settings.enableMtp ? "ON" : "OFF")").font(.caption2).foregroundColor(.secondary)
                }
            } else {
                // Editable fields when override is ON.
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Port:").font(.caption).foregroundColor(.secondary)
                        TextField("", text: Binding<String>(
                            get: { String(format: "%d", manager.perModelPort(for: model)) },
                            set: { if let p = Int($0), p >= 0, p < 65536 { manager.setPerModelPort(p, for: model) } }
                        ))
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ctx:").font(.caption).foregroundColor(.secondary)
                        TextField("", text: Binding<String>(
                            get: { manager.formatCtxDisplay(manager.perModelCtxSize(for: model)) },
                            set: { if let c = manager.parseCtxInput($0) { manager.setPerModelCtxSize(c, for: model) } }
                        ))
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Temp:").font(.caption).foregroundColor(.secondary)
                        TextField("", text: Binding<String>(
                            get: { String(format: "%.2f", manager.perModelSetting("temperature", default: manager.settings.temperature, for: model) as Double) },
                            set: { if let v = Double($0) { manager.setPerModelSetting(v, for: model, key: "temperature") } }
                        ))
                        .frame(width: 50)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Top-P:").font(.caption).foregroundColor(.secondary)
                        TextField("", text: Binding<String>(
                            get: { String(format: "%.2f", manager.perModelSetting("topP", default: manager.settings.topP, for: model) as Double) },
                            set: { if let v = Double($0) { manager.setPerModelSetting(v, for: model, key: "topP") } }
                        ))
                        .frame(width: 50)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    }
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Top-K:").font(.caption).foregroundColor(.secondary)
                        TextField("", text: Binding<String>(
                            get: { String(format: "%d", manager.perModelSetting("topK", default: manager.settings.topK, for: model) as Int) },
                            set: { if let v = Int($0) { manager.setPerModelSetting(v, for: model, key: "topK") } }
                        ))
                        .frame(width: 50)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RP:").font(.caption).foregroundColor(.secondary)
                        TextField("", text: Binding<String>(
                            get: { String(format: "%.2f", manager.perModelSetting("repeatPenalty", default: manager.settings.repeatPenalty, for: model) as Double) },
                            set: { if let v = Double($0) { manager.setPerModelSetting(v, for: model, key: "repeatPenalty") } }
                        ))
                        .frame(width: 50)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("K Cache:").font(.caption).foregroundColor(.secondary)
                        Picker("", selection: Binding<String>(
                            get: { manager.perModelSetting("kvCacheTypeK", default: manager.settings.kvCacheTypeK, for: model) },
                            set: { manager.setPerModelSetting($0, for: model, key: "kvCacheTypeK") }
                        )) {
                            Text("f16").tag("f16")
                            Text("q8_0").tag("q8_0")
                            Text("q4_0").tag("q4_0")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 80)
                        .controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("V Cache:").font(.caption).foregroundColor(.secondary)
                        Picker("", selection: Binding<String>(
                            get: { manager.perModelSetting("kvCacheTypeV", default: manager.settings.kvCacheTypeV, for: model) },
                            set: { manager.setPerModelSetting($0, for: model, key: "kvCacheTypeV") }
                        )) {
                            Text("f16").tag("f16")
                            Text("q8_0").tag("q8_0")
                            Text("q4_0").tag("q4_0")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 80)
                        .controlSize(.small)
                    }
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Think:").font(.caption).foregroundColor(.secondary)
                        Toggle("", isOn: Binding<Bool>(
                            get: { manager.perModelSetting("thinkingEnabled", default: manager.settings.thinkingEnabled, for: model) },
                            set: { manager.setPerModelSetting($0, for: model, key: "thinkingEnabled") }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MTP:").font(.caption).foregroundColor(.secondary)
                        Toggle("", isOn: Binding<Bool>(
                            get: { manager.perModelSetting("enableMtp", default: manager.settings.enableMtp, for: model) },
                            set: { manager.setPerModelSetting($0, for: model, key: "enableMtp") }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Extra Args:").font(.caption).foregroundColor(.secondary)
                    TextField("", text: Binding<String>(
                        get: { manager.perModelSetting("extraArgs", default: manager.settings.globalExtraArgs, for: model) },
                        set: { manager.setPerModelSetting($0, for: model, key: "extraArgs") }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                }
            }

            // Reset button — always visible. Behavior depends on override
            // state to avoid leaking stale per-model keys into UserDefaults:
            //   • Override ON  → write the factory defaults as this model's
            //     per-model values (so the editable fields show defaults).
            //   • Override OFF → there's nothing to edit; clear ALL per-model
            //     keys so no stale values linger and the model cleanly
            //     inherits global settings on next load.
            HStack {
                Spacer()
                Button("Reset to Default") {
                    if manager.perModelOverrideEnabled(for: model) {
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
                    } else {
                        // Override OFF: purge any stale per-model keys.
                        manager.resetPerModel(for: model)
                    }
                    manager.refreshTrigger += 1
                }
                .controlSize(.small)
                .foregroundColor(.secondary)
            }
        }
        .padding(.leading, 4)
    }
}


