// =============================================================================
//  FootprintEstimator.swift — lm-switcher-mcp
//  GGUF header parse + MLX config.json → footprint & swap guard (§3.7).
//
//    footprint ≈ weights + kv_cache + overhead
//    kv_cache  = layers × kv_heads × head_dim × ctx × (bytes_K + bytes_V)
//    overhead  = 10% of weights + 512 MB compute buffer
//    headroom  = max(2 GB, 10% of total RAM)   // reserved for the OS
//
//  2026-09-15 audit hardening: every number below comes from a model
//  directory the operator downloaded — i.e. from outside this program.
//  They are validated and the arithmetic is made non-trapping before use:
//  a malformed or hostile config.json / GGUF header must degrade to the
//  `file_size_only` estimate (or to "no geometry"), never abort the MCP
//  process. Both binaries are built with `swiftc -O`, which keeps overflow
//  and conversion preconditions compiled in as aborting traps, so the only
//  safe place to stop a hostile number is before it reaches `*`, `Int(...)`
//  or `UInt64(...)`.
// =============================================================================

import Foundation

struct FootprintEstimate {
    let footprint: UInt64
    let weights: UInt64
    /// KV bytes for ctx=1 — lets callers solve max_ctx_that_fits.
    let kvBytesPerToken: Double
    let maxContextWindow: Int?
    let quality: String   // "header" | "file_size_only"
}

enum FootprintEstimator {

    static let headroom: UInt64 = max(2 << 30, ProcessInfo.processInfo.physicalMemory / 10)
    static let computeBuffer: UInt64 = 512 << 20

    // Sanity bounds for model-supplied geometry. Real models sit far below
    // these; anything outside is treated as "no geometry" — which routes the
    // estimate to the file_size_only path instead of trapping (2026-09-15
    // audit: a config.json with num_hidden_layers = -1 used to abort the
    // whole MCP process through UInt64(perToken * ctx)).
    private static let maxLayers = 8192
    private static let maxHeadsPerLayer = 65536
    private static let maxHeadDim = 65536
    private static let maxKvHeadTotal = 1 << 22          // 4M KV heads
    private static let maxContext = 1 << 24              // 16M tokens

    static func kvBytesPerElement(_ cacheType: String) -> Double {
        switch cacheType {
        case "q8_0": return 1.0625
        case "q4_0": return 0.5625
        default:     return 2.0     // f16
        }
    }

    static func estimate(model: DiscoveredModel, ctxSize: Int) -> FootprintEstimate {
        let weights = weightsBytes(model)
        var perToken = 0.0
        var maxCtx: Int? = nil
        var quality = "file_size_only"
        var effectiveCtx = max(0, ctxSize)

        if let geom = geometry(model) {
            maxCtx = geom.maxContext
            let bytesK: Double, bytesV: Double
            if model.backend == "GGUF" {
                // M5 fix (MCP_SPEC §3.7): per-model KV cache types WIN over
                // the global setting, mirroring the app/CLI launch precedence.
                // The previous code read only the global keys, so a model with
                // a per-model kvCacheTypeV=q8_0 was LAUNCHED with q8 but
                // ESTIMATED using the global q4 — under-counting footprint and
                // potentially letting a load through that actually swaps.
                // That defeats the entire purpose of the swap guard.
                let gK = (perModelValue("kvCacheTypeK", hash: model.hash) as? String)
                    ?? Prefs.string("kvCacheTypeK", default: "q8_0")
                let gV = (perModelValue("kvCacheTypeV", hash: model.hash) as? String)
                    ?? Prefs.string("kvCacheTypeV", default: "q4_0")
                bytesK = kvBytesPerElement(gK)
                bytesV = kvBytesPerElement(gV)
            } else {
                bytesK = 2.0; bytesV = 2.0   // MLX KV is f16
                let cap = Prefs.int("mlxMaxKvSize")
                if cap > 0 { effectiveCtx = min(effectiveCtx, cap) }
            }
            // Geometry is bounded (see the guards in mlxGeometry /
            // ggufGeometry), so this product is small — but compute it in
            // Double anyway: no Int multiply here can trap.
            let raw = Double(geom.kvHeadTotal) * Double(geom.headDim) * (bytesK + bytesV)
            if raw.isFinite, raw > 0 {
                perToken = raw
                quality = "header"
            }
        }

        // Only a finite, in-range KV estimate is used. Anything else
        // (implausible geometry, absurd ctx) degrades to the KV-free
        // footprint with an explicit `file_size_only` quality, which the
        // swap guard treats as "cannot bound this load" (fail-closed).
        var kv: UInt64 = 0
        if perToken > 0 {
            let raw = perToken * Double(effectiveCtx)
            if raw.isFinite, raw >= 0, raw < Double(UInt64.max) {
                kv = UInt64(raw)
            } else {
                perToken = 0
                maxCtx = nil
                quality = "file_size_only"
            }
        }

        let overhead = weights / 10 + computeBuffer
        return FootprintEstimate(footprint: weights + kv + overhead, weights: weights,
                                 kvBytesPerToken: perToken, maxContextWindow: maxCtx,
                                 quality: quality)
    }

    /// Largest ctx whose footprint fits in `available − headroom`, from the
    /// same equation (§3.7). nil when even ctx=0 doesn't fit or geometry is
    /// unknown.
    static func maxCtxThatFits(_ est: FootprintEstimate, available: UInt64) -> Int? {
        guard est.kvBytesPerToken > 0 else { return nil }
        let fixed = est.weights + est.weights / 10 + computeBuffer + headroom
        guard available > fixed else { return nil }
        let maxCtx = Double(available - fixed) / est.kvBytesPerToken
        guard maxCtx.isFinite, maxCtx > 0, maxCtx < Double(Int.max) else { return nil }
        return Int(maxCtx)
    }

    private static func weightsBytes(_ model: DiscoveredModel) -> UInt64 {
        let fm = FileManager.default
        if model.backend == "GGUF" || model.backend == "DS4" {
            return ((try? fm.attributesOfItem(atPath: model.path))?[.size] as? UInt64) ?? 0
        }
        // MLX: Σ safetensors sizes (MoE file size ≈ fully mapped — conservative).
        guard let files = try? fm.contentsOfDirectory(atPath: model.path) else { return 0 }
        return files.filter { $0.hasSuffix(".safetensors") }.reduce(0 as UInt64) { sum, f in
            sum + (((try? fm.attributesOfItem(atPath: model.path + "/" + f))?[.size] as? UInt64) ?? 0)
        }
    }

    // MARK: - Geometry

    /// kvHeadTotal = Σ over layers of that layer's KV head count. Scalar
    /// head_count_kv ⇒ layers × kv_heads; some models (gemma-4) store a
    /// per-layer ARRAY instead, which we sum directly.
    struct Geometry { let kvHeadTotal: Int; let headDim: Int; let maxContext: Int? }

    /// UInt64 → Int with an upper bound. Returns nil for zero, above-limit,
    /// or non-representable values — i.e. for anything a real model cannot
    /// have. Never traps.
    private static func boundedInt(_ v: UInt64, max limit: UInt64) -> Int? {
        guard v > 0, v <= limit, let i = Int(exactly: v) else { return nil }
        return i
    }

    private static func geometry(_ model: DiscoveredModel) -> Geometry? {
        if model.backend == "GGUF" || model.backend == "DS4" {
            return ggufGeometry(model.path)
        }
        return mlxGeometry(model.path)
    }

    /// MLX config.json (§3.7). Every field is validated before use; a
    /// value outside model-realism bounds makes the whole geometry nil.
    private static func mlxGeometry(_ dir: String) -> Geometry? {
        guard let data = FileManager.default.contents(atPath: dir + "/config.json"),
              let cfg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let layers = cfg["num_hidden_layers"] as? Int,
              layers >= 1, layers <= maxLayers else { return nil }
        let heads = cfg["num_attention_heads"] as? Int ?? 0
        guard heads >= 0, heads <= maxHeadsPerLayer else { return nil }
        let kvHeads = cfg["num_key_value_heads"] as? Int ?? heads
        guard kvHeads >= 1, kvHeads <= maxHeadsPerLayer else { return nil }
        var headDim = cfg["head_dim"] as? Int ?? 0
        if headDim == 0, let hidden = cfg["hidden_size"] as? Int, heads > 0,
           hidden > 0, hidden <= maxHeadDim * maxHeadsPerLayer {
            headDim = hidden / heads
        }
        guard headDim >= 1, headDim <= maxHeadDim else { return nil }
        let (kvTotal, overflow) = layers.multipliedReportingOverflow(by: kvHeads)
        guard !overflow, kvTotal >= 1, kvTotal <= maxKvHeadTotal else { return nil }
        let maxCtx = (cfg["max_position_embeddings"] as? Int).flatMap {
            $0 >= 1 && $0 <= maxContext ? $0 : nil
        }
        return Geometry(kvHeadTotal: kvTotal, headDim: headDim, maxContext: maxCtx)
    }

    /// GGUF v2/v3 header-only parse (§3.7): magic, versions, then walk the
    /// metadata KVs for architecture geometry. Never reads tensor data.
    /// Any structural surprise throws → caller falls back to file size only.
    /// Values are bounds-checked before narrowing so a hostile header cannot
    /// trap `Int(...)` or an integer multiply (2026-09-15 audit).
    private static func ggufGeometry(_ path: String) -> Geometry? {
        guard let r = try? GgufReader(path: path) else { return nil }
        do {
            guard try r.u32() == 0x46554747 else { return nil }          // "GGUF" LE
            let version = try r.u32()
            guard version == 2 || version == 3 else { return nil }
            _ = try r.u64()                                              // tensor_count
            let kvCount = try r.u64()

            var meta: [String: UInt64] = [:]
            var arch = ""
            var kvHeadArraySum: UInt64? = nil
            for _ in 0..<min(kvCount, 4096) {
                let key = try r.string()
                let type = try r.u32()
                if key == "general.architecture", type == 8 {
                    arch = try r.stringValue()
                } else if type == 9, key.hasSuffix(".attention.head_count_kv") {
                    // gemma-4 and friends: per-layer KV head counts.
                    kvHeadArraySum = try r.intArraySum()
                } else if type >= 4 && type <= 5 || type >= 10 && type <= 11 || type <= 3 {
                    meta[key] = try r.intValue(type: type)
                } else {
                    try r.skipValue(type: type)
                }
                // Early exit once we have everything we need.
                if !arch.isEmpty,
                   meta["\(arch).block_count"] != nil,
                   meta["\(arch).attention.head_count_kv"] != nil || kvHeadArraySum != nil,
                   meta["\(arch).context_length"] != nil,
                   meta["\(arch).attention.key_length"] != nil
                    || meta["\(arch).embedding_length"] != nil { break }
            }
            guard !arch.isEmpty,
                  let layers = boundedInt(meta["\(arch).block_count"] ?? 0, max: UInt64(maxLayers))
            else { return nil }
            let kvHeadTotal: Int
            if let sum = kvHeadArraySum, sum > 0 {
                guard let total = boundedInt(sum, max: UInt64(maxKvHeadTotal)) else { return nil }
                kvHeadTotal = total
            } else if let kvHeads = boundedInt(meta["\(arch).attention.head_count_kv"] ?? 0,
                                               max: UInt64(maxHeadsPerLayer)) {
                let (total, overflow) = layers.multipliedReportingOverflow(by: kvHeads)
                guard !overflow, total <= maxKvHeadTotal else { return nil }
                kvHeadTotal = total
            } else {
                return nil
            }
            var headDim = boundedInt(meta["\(arch).attention.key_length"] ?? 0,
                                     max: UInt64(maxHeadDim)) ?? 0
            if headDim == 0,
               let emb = meta["\(arch).embedding_length"], emb > 0,
               let heads = boundedInt(meta["\(arch).attention.head_count"] ?? 0,
                                      max: UInt64(maxHeadsPerLayer)),
               heads > 0 {
                headDim = boundedInt(emb / UInt64(heads), max: UInt64(maxHeadDim)) ?? 0
            }
            guard headDim > 0 else { return nil }
            return Geometry(kvHeadTotal: kvHeadTotal, headDim: headDim,
                            maxContext: meta["\(arch).context_length"].flatMap {
                                boundedInt($0, max: UInt64(maxContext))
                            })
        } catch {
            return nil
        }
    }
}

// MARK: - Buffered little-endian GGUF reader

final class GgufReader {
    private let fh: FileHandle
    enum Err: Error { case eof, corrupt }

    init(path: String) throws {
        guard let fh = FileHandle(forReadingAtPath: path) else { throw Err.eof }
        self.fh = fh
    }
    deinit { try? fh.close() }

    private func bytes(_ n: Int) throws -> Data {
        guard n >= 0, n < 64 << 20 else { throw Err.corrupt }   // sanity cap
        guard let d = try fh.read(upToCount: n), d.count == n else { throw Err.eof }
        return d
    }
    func u32() throws -> UInt32 { try bytes(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
    func u64() throws -> UInt64 { try bytes(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) } }

    func string() throws -> String {
        let len = try u64()
        guard len < 1 << 20 else { throw Err.corrupt }
        return String(data: try bytes(Int(len)), encoding: .utf8) ?? ""
    }
    func stringValue() throws -> String { try string() }

    /// Numeric KV value widened to UInt64 (signed values ≥ 0 in practice).
    func intValue(type: UInt32) throws -> UInt64 {
        switch type {
        case 0, 1: return UInt64(try bytes(1)[0])
        case 2, 3: return UInt64(try bytes(2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })
        case 4, 5: return UInt64(try u32())
        case 10, 11: return try u64()
        default: throw Err.corrupt
        }
    }

    /// Sum a numeric array value (per-layer head counts, etc.). The element
    /// COUNT is capped above; the element VALUES are model-supplied, so the
    /// accumulation is overflow-checked — an overflowing sum is a corrupt
    /// header (throw), not a process abort (2026-09-15 audit).
    func intArraySum() throws -> UInt64 {
        let elemType = try u32()
        let count = try u64()
        guard count < 1 << 16 else { throw Err.corrupt }
        var sum: UInt64 = 0
        for _ in 0..<count {
            let (next, overflow) = sum.addingReportingOverflow(try intValue(type: elemType))
            guard !overflow else { throw Err.corrupt }
            sum = next
        }
        return sum
    }

    /// Skip a value of any GGUF type (arrays element-wise for strings).
    func skipValue(type: UInt32) throws {
        switch type {
        case 0, 1, 7: _ = try bytes(1)
        case 2, 3: _ = try bytes(2)
        case 4, 5, 6: _ = try bytes(4)
        case 10, 11, 12: _ = try bytes(8)
        case 8: _ = try string()
        case 9:
            let elemType = try u32()
            let count = try u64()
            guard count < 32 << 20 else { throw Err.corrupt }
            if elemType == 8 {
                for _ in 0..<count { _ = try string() }
            } else {
                let sizes: [UInt32: Int] = [0: 1, 1: 1, 7: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 10: 8, 11: 8, 12: 8]
                guard let s = sizes[elemType] else { throw Err.corrupt }
                try fh.seek(toOffset: fh.offsetInFile + UInt64(s) * count)
            }
        default: throw Err.corrupt
        }
    }
}
