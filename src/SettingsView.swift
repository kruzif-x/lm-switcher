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
            .onChange(of: modelsDir)      { _, v in manager.settings.modelsDir = v; manager.refreshModels(); manager.startWatching() }
            .onChange(of: defaultPort)    { _, v in if let p = Int(v), p > 0, p < 65536 { manager.settings.defaultPort = p } }
            .onChange(of: defaultCtxSize) { _, v in if let c = manager.parseCtxInput(v) { manager.settings.defaultCtxSize = c } }
            .onChange(of: globalExtraArgs){ _, v in manager.settings.globalExtraArgs = v }
            .onChange(of: enableMtp)      { _, v in manager.settings.enableMtp = v }
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

    // Local @State mirrors of manager.settings
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
                toggleRow(label: "Mlock", hint: "Lock model in RAM to prevent swap", isOn: $mlock)
                Divider().padding(.leading, 14)
                toggleRow(label: "No-mmap", hint: "Disable memory-mapped file loading — GGUF only", isOn: $noMmap)

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


    // MARK: - Per-Model tab

    private var modelsPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Per-Model Settings").font(.headline)
                Spacer()
            }
            Text("Override global settings per model · Auto-saved · Applies on next model (re)load")
                .font(.caption).foregroundStyle(.secondary)

            if manager.models.isEmpty {
                Text("No models found in \(manager.settings.modelsDir)")
                    .foregroundStyle(.secondary).padding()
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
        .padding()
    }

    private func perModelCard(for model: ModelEntry) -> some View {
        let state = manager.state(for: model)
        return DisclosureGroup {
            perModelOverrideFields(for: model)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.backend.sfSymbol)
                    .foregroundStyle(model.backend == .mlx ? Color.purple : Color.blue)
                    .imageScale(.small)
                Text(model.name).lineLimit(1).truncationMode(.middle)
                Spacer()
                if state.isRunning {
                    Image(systemName: "circle.fill").foregroundStyle(Color.green).imageScale(.small)
                    Text(":\(String(state.port))").font(.caption.monospaced()).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "circle").foregroundStyle(.secondary).imageScale(.small)
                }
                if state.isRunning {
                    Button("Unload") { manager.unloadModel(model) }.controlSize(.small)
                } else if manager.switchingTo == model.id {
                    Text("Switching…").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 4) {
                        Button("Load") { manager.loadModel(model) }.controlSize(.small)
                        if manager.anyRunning {
                            Button("Switch") { manager.switchModel(model) }.controlSize(.small)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func perModelOverrideFields(for model: ModelEntry) -> some View {
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
                )) { Text("Override Global Settings") }
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

            if !overrideOn {
                HStack(spacing: 16) {
                    Text("Port: \(String(format: "%d", manager.settings.defaultPort))").font(.caption2).foregroundStyle(.secondary)
                    Text("Ctx: \(manager.formatCtxDisplay(manager.settings.defaultCtxSize))").font(.caption2).foregroundStyle(.secondary)
                    Text("Temp: \(manager.settings.temperature)").font(.caption2).foregroundStyle(.secondary)
                    Text("Top-P: \(manager.settings.topP)").font(.caption2).foregroundStyle(.secondary)
                    Text("Top-K: \(manager.settings.topK)").font(.caption2).foregroundStyle(.secondary)
                    Text("RP: \(manager.settings.repeatPenalty)").font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    Text("K: \(manager.settings.kvCacheTypeK)").font(.caption2).foregroundStyle(.secondary)
                    Text("V: \(manager.settings.kvCacheTypeV)").font(.caption2).foregroundStyle(.secondary)
                    Text("Think: \(manager.settings.thinkingEnabled ? "ON" : "OFF")").font(.caption2).foregroundStyle(.secondary)
                    Text("MTP: \(manager.settings.enableMtp ? "ON" : "OFF")").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Port:").font(.caption).foregroundStyle(.secondary)
                        TextField("", text: Binding<String>(
                            get: { String(format: "%d", manager.perModelPort(for: model)) },
                            set: { if let p = Int($0), p >= 0, p < 65536 { manager.setPerModelPort(p, for: model) } }
                        )).frame(width: 70).textFieldStyle(.roundedBorder).controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ctx:").font(.caption).foregroundStyle(.secondary)
                        TextField("", text: Binding<String>(
                            get: { manager.formatCtxDisplay(manager.perModelCtxSize(for: model)) },
                            set: { if let c = manager.parseCtxInput($0) { manager.setPerModelCtxSize(c, for: model) } }
                        )).frame(width: 70).textFieldStyle(.roundedBorder).controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Temp:").font(.caption).foregroundStyle(.secondary)
                        TextField("", text: Binding<String>(
                            get: { String(format: "%.2f", manager.perModelSetting("temperature", default: manager.settings.temperature, for: model) as Double) },
                            set: { if let v = Double($0) { manager.setPerModelSetting(v, for: model, key: "temperature") } }
                        )).frame(width: 50).textFieldStyle(.roundedBorder).controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Top-P:").font(.caption).foregroundStyle(.secondary)
                        TextField("", text: Binding<String>(
                            get: { String(format: "%.2f", manager.perModelSetting("topP", default: manager.settings.topP, for: model) as Double) },
                            set: { if let v = Double($0) { manager.setPerModelSetting(v, for: model, key: "topP") } }
                        )).frame(width: 50).textFieldStyle(.roundedBorder).controlSize(.small)
                    }
                }
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Top-K:").font(.caption).foregroundStyle(.secondary)
                        TextField("", text: Binding<String>(
                            get: { String(format: "%d", manager.perModelSetting("topK", default: manager.settings.topK, for: model) as Int) },
                            set: { if let v = Int($0) { manager.setPerModelSetting(v, for: model, key: "topK") } }
                        )).frame(width: 50).textFieldStyle(.roundedBorder).controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RP:").font(.caption).foregroundStyle(.secondary)
                        TextField("", text: Binding<String>(
                            get: { String(format: "%.2f", manager.perModelSetting("repeatPenalty", default: manager.settings.repeatPenalty, for: model) as Double) },
                            set: { if let v = Double($0) { manager.setPerModelSetting(v, for: model, key: "repeatPenalty") } }
                        )).frame(width: 50).textFieldStyle(.roundedBorder).controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("K Cache:").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: Binding<String>(
                            get: { manager.perModelSetting("kvCacheTypeK", default: manager.settings.kvCacheTypeK, for: model) },
                            set: { manager.setPerModelSetting($0, for: model, key: "kvCacheTypeK") }
                        )) {
                            Text("f16").tag("f16"); Text("q8_0").tag("q8_0"); Text("q4_0").tag("q4_0")
                        }.pickerStyle(.menu).frame(width: 80).controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("V Cache:").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: Binding<String>(
                            get: { manager.perModelSetting("kvCacheTypeV", default: manager.settings.kvCacheTypeV, for: model) },
                            set: { manager.setPerModelSetting($0, for: model, key: "kvCacheTypeV") }
                        )) {
                            Text("f16").tag("f16"); Text("q8_0").tag("q8_0"); Text("q4_0").tag("q4_0")
                        }.pickerStyle(.menu).frame(width: 80).controlSize(.small)
                    }
                }
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Think:").font(.caption).foregroundStyle(.secondary)
                        Toggle("", isOn: Binding<Bool>(
                            get: { manager.perModelSetting("thinkingEnabled", default: manager.settings.thinkingEnabled, for: model) },
                            set: { manager.setPerModelSetting($0, for: model, key: "thinkingEnabled") }
                        )).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MTP:").font(.caption).foregroundStyle(.secondary)
                        Toggle("", isOn: Binding<Bool>(
                            get: { manager.perModelSetting("enableMtp", default: manager.settings.enableMtp, for: model) },
                            set: { manager.setPerModelSetting($0, for: model, key: "enableMtp") }
                        )).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Extra Args:").font(.caption).foregroundStyle(.secondary)
                    TextField("", text: Binding<String>(
                        get: { manager.perModelSetting("extraArgs", default: manager.settings.globalExtraArgs, for: model) },
                        set: { manager.setPerModelSetting($0, for: model, key: "extraArgs") }
                    )).textFieldStyle(.roundedBorder).controlSize(.small)
                }
            }

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
                        manager.resetPerModel(for: model)
                    }
                    manager.refreshTrigger += 1
                }
                .controlSize(.small).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 4)
    }


    // MARK: - Help tab

    private var helpPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Table of contents
                    tocSection(proxy: proxy)

                    // Sections
                    helpSection(number: "1", title: "Quick start", id: "s1", proxy: proxy) {
                        helpEntry("Set your models directory",
                                  "Go to Global → Models directory. Point it at the folder containing your .gguf files and MLX model folders (folders with .safetensors + config.json).")
                        helpEntry("Load a model",
                                  "Click any model row in the menu bar dropdown. Each model starts its own server on a separate port.")
                        helpEntry("Use the CLI",
                                  "llama list · llama load <name> · llama switch <name> · llama status")
                    }

                    helpSection(number: "2", title: "Menu bar actions", id: "s2", proxy: proxy) {
                        helpEntry("Click a stopped model", "Loads it directly on the next available port.")
                        helpEntry("Right-click any model", "Load / Unload / Switch to — single-model actions without bulk selection.")
                        helpEntry("Unload selected", "Appears when 2+ models are running. The running models show checkboxes — uncheck any you want to keep, then click Unload selected.")
                        helpEntry("Unload all ⏹", "Stops every running model at once.")
                        helpEntry("Refresh ↻", "Re-scans the models directory for new or removed files.")
                    }

                    helpSection(number: "3", title: "Global settings", id: "s3", proxy: proxy) {
                        helpEntry("Models directory", "Scanned for .gguf files and MLX model folders.")
                        helpEntry("Default port", "Starting port for model servers. Additional models increment — 8080, 8081, 8082…")
                        helpEntry("Default ctx size", "Context window in tokens. Accepts k-suffix (4k, 8k) or plain integers. Use 4k for 16 GB Macs, 64k for 32 GB+.")
                        helpEntry("Global extra args", "Free-form arguments passed to every server launch. Parsed with quote handling.")
                        helpEntry("MTP", "Multi-Token Prediction. ON by default — auto-detected per model. Only applies to models with built-in MTP or a companion mtp-*.gguf head.")
                        helpEntry("Chat template override", "Custom .jinja or .json template for agentic harnesses (opencode, pi). Leave empty for the model's built-in template.")
                    }

                    helpSection(number: "4", title: "Advanced settings", id: "s4", proxy: proxy) {
                        helpEntry("K / V cache type", "KV cache quantization — separate from model weight quantization. q8_0 K + q4_0 V halves memory with minimal quality loss. f16 = full precision (spare RAM only).")
                        helpEntry("Flash attention", "Hardware-accelerated attention via Metal. No downside on Apple Silicon — leave ON.")
                        helpEntry("Thinking mode", "Model generates reasoning tokens before responding. Better for coding and tool loops. Qwen recommends ON for coding, OFF for speed-constrained Macs.")
                        helpEntry("Suppress reasoning content", "Suppresses Gemma 4's reasoning_content field that crashes OpenAI-compatible clients (opencode, pi, OpenClaw). Leave ON unless your client handles it natively.")
                        helpEntry("Temperature", "0.6 for coding, 0.8 for chat, 1.0 for research.")
                        helpEntry("Top-P / Top-K", "Qwen-recommended defaults: top-p 0.95, top-k 20 for all workloads.")
                        helpEntry("Repeat penalty", "1.0 = off. Increase to 1.1–1.5 if the model repeats itself.")
                        helpEntry("CPU threads", "Empty = auto-detect all cores. Limit on 8 GB Macs to reduce contention. GGUF only.")
                        helpEntry("Batch size", "Prompt processing batch. Default 2048 is the llama.cpp standard. GGUF only.")
                        helpEntry("Mlock", "Locks model in RAM to prevent swap. Only enable with spare RAM.")
                        helpEntry("No-MMap", "Disables memory-mapped file loading. Can improve speed on NVMe. GGUF only.")
                        helpEntry("Max KV size (MLX)", "Caps KV cache for MLX. 0 = unlimited. Set 4096–8192 on 16 GB Macs to avoid OOM.")
                    }

                    helpSection(number: "5", title: "Per-model overrides", id: "s5", proxy: proxy) {
                        helpEntry("Override global settings", "When OFF, the model inherits all global settings shown in gray. When ON, each field becomes editable for that model only.")
                        helpEntry("When do changes apply?", "Per-model settings take effect on the next load. If the model is already running, unload it and reload it.")
                        helpEntry("Reset to global", "Clears all per-model overrides — the model inherits global settings again on next load.")
                        helpEntry("Extra args (per-model)", "Appended to global extra args, not replaced. Use for model-specific flags.")
                    }

                    helpSection(number: "6", title: "CLI commands", id: "s6", proxy: proxy) {
                        helpEntry("llama list", "List all discovered models with load status.")
                        helpEntry("llama load <name>", "Load a model by fuzzy name match.")
                        helpEntry("llama unload <name…> | all", "Unload one or more named models, or all at once.")
                        helpEntry("llama switch <name>", "Atomic switch: load new model, verify it started, then unload everything else.")
                        helpEntry("llama status", "Show running models with ports and PIDs.")
                        helpEntry("llama ctx <size>", "Set per-model context size override.")
                        helpEntry("llama port <num>", "Set per-model port override.")
                        helpEntry("llama menubar", "Launch the menu bar app.")
                    }

                    helpSection(number: "7", title: "Vision models (Gemma 4 / Qwen2-VL)", id: "s7", proxy: proxy) {
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

                        helpEntry("mtp-*.gguf exclusion", "MTP encoder heads are excluded from the model list — they are not standalone models. llama-server loads them from model metadata automatically when present in the same folder.")
                        helpEntry("Reasoning suppression (Gemma 4)", "Applied automatically via --reasoning off --reasoning-format none. Turn OFF in Settings only if your client handles reasoning_content natively.")
                        helpEntry("Chat template bugs (Gemma 4)", "The standard Gemma 4 template has 4 bugs that break multi-turn tool calling. Use a custom .jinja template via Settings → Backends → Chat template override for agentic harnesses.")
                    }

                    helpSection(number: "8", title: "Quantization guide", id: "s8", proxy: proxy) {
                        helpEntry("Model quant vs KV cache quant", "Model quantization (Q4_K_M, Q8, etc.) is baked into the .gguf file. KV cache quant (the settings here) controls how the context window is stored in RAM during inference. They're independent — any combination works.")
                        helpEntry("8 GB",  "Qwen3.5-4B Q4_K_M — simple chat only, not for agent work.")
                        helpEntry("16 GB", "Qwen3.5-9B Q4_K_M — practical floor for Hermes tool calling.")
                        helpEntry("24 GB", "Qwen3.6-27B Q4_K_M — dense, stronger coding.")
                        helpEntry("32 GB+", "Qwen3.6-35B-A3B MLX 4-bit — MoE sweet spot (~3B active per token).")
                        helpEntry("48 GB+", "Qwen3.6-27B Q6_K — the 'serious agent' quant. Q4 drifts on long tool traces.")
                        helpEntry("64 GB+", "Qwen3.6-27B Q8 — near-full precision.")
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
                ("1", "s1", "Quick start"),
                ("2", "s2", "Menu bar actions"),
                ("3", "s3", "Global settings"),
                ("4", "s4", "Advanced settings"),
                ("5", "s5", "Per-model overrides"),
                ("6", "s6", "CLI commands"),
                ("7", "s7", "Vision models"),
                ("8", "s8", "Quantization guide"),
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

    private func helpEntry(_ key: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key)
                .font(.system(.body, design: .monospaced).weight(.medium))
                .font(.system(size: 12))
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
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
                    Text("Version 1.1.0")
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
