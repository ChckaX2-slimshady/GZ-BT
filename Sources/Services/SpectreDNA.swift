import Foundation

/// Reader for the compiled Token DNA artifact that Spectre's Python compiler
/// writes beside a model.
///
/// The artifact is **raw little-endian arrays plus JSON** — chosen over `.npy`
/// precisely so these bytes are readable from Swift with no Python in the loop.
/// There is no bridge and no process boundary here, which is what keeps this the
/// right side of CLAUDE.md gotcha #2.
///
///     <model-dir>/.spectre-dna/
///       manifest.json      written LAST — presence means complete
///       header.json        model / tokenizer / architecture scalars
///       core/<field>.<dt>  one raw array per compiled field
///       views/<id>.f32     materialised policy views
///       validation.json    the compiler's gate report
///
/// `manifest.json`-written-last is the same completeness convention the model
/// store already uses for `.gzbt-model.json`; this reuses the rule rather than
/// inventing a second one.
///
/// Layer: **Services**. Loading is `nonisolated` and runs off the main actor —
/// the same posture `ModelManager.discover` takes, and for the same reason: a
/// 150k-entry vocabulary is not something to decode on the main thread.
struct SpectreDNA: Sendable {

    /// Schema this build understands. A newer artifact is refused rather than
    /// half-read: fields are versioned, and guessing at an unknown one is how a
    /// consumer silently reads garbage.
    static let supportedSchemaMajor = 1
    static let supportedSchemaMinor = 0

    static let directoryName = ".spectre-dna"

    let directory: URL
    let manifest: Manifest
    let header: Header

    /// Core arrays, six bytes per token id in total.
    let freqRank: [UInt16]
    let classFlags: [UInt8]
    let surfaceBytes: [UInt8]
    let charLen: [UInt8]
    let specialKind: [UInt8]

    /// The materialised policy view, when one was requested and present.
    let priorView: [Float]?
    let priorViewID: String?

    /// Total bytes on disk for the whole artifact.
    let artifactBytes: Int64

    // MARK: - Manifest

    struct Manifest: Decodable, Sendable {
        let dnaSchemaMajor: Int
        let dnaSchemaMinor: Int
        let compilerVersion: String
        let contentHash: String
        /// **Nil is meaningful**: a vocabulary-free package (CANINE) compiles to a
        /// header-only artifact. Nil is not zero and must not be rendered as zero.
        let vocabSize: Int?
        let fields: [String: FieldSpec]
        /// Field name → why it is absent. Never a sentinel value.
        let fieldsNull: [String: String]
        let views: [String: ViewSpec]
        let tokenizerFingerprint: String?
        let stagesRun: [String]?

        enum CodingKeys: String, CodingKey {
            case dnaSchemaMajor = "dna_schema_major"
            case dnaSchemaMinor = "dna_schema_minor"
            case compilerVersion = "compiler_version"
            case contentHash = "content_hash"
            case vocabSize = "vocab_size"
            case fields
            case fieldsNull = "fields_null"
            case views
            case tokenizerFingerprint = "tokenizer_fingerprint"
            case stagesRun = "stages_run"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            dnaSchemaMajor = try c.decode(Int.self, forKey: .dnaSchemaMajor)
            dnaSchemaMinor = try c.decode(Int.self, forKey: .dnaSchemaMinor)
            compilerVersion = try c.decode(String.self, forKey: .compilerVersion)
            contentHash = try c.decode(String.self, forKey: .contentHash)
            vocabSize = try c.decodeIfPresent(Int.self, forKey: .vocabSize)
            fields = try c.decodeIfPresent([String: FieldSpec].self, forKey: .fields) ?? [:]
            fieldsNull = try c.decodeIfPresent([String: String].self, forKey: .fieldsNull) ?? [:]
            views = try c.decodeIfPresent([String: ViewSpec].self, forKey: .views) ?? [:]
            tokenizerFingerprint = try c.decodeIfPresent(String.self, forKey: .tokenizerFingerprint)
            stagesRun = try c.decodeIfPresent([String].self, forKey: .stagesRun)
        }
    }

    struct FieldSpec: Decodable, Sendable {
        let dtype: String
        let length: Int
        let tier: String
    }

    struct ViewSpec: Decodable, Sendable {
        let dtype: String
        let length: Int
        let policyVersion: String?

        enum CodingKeys: String, CodingKey {
            case dtype, length
            case policyVersion = "policy_version"
        }
    }

    // MARK: - Header

    /// Architecture and tokenizer scalars. Every field is optional because the
    /// compiler emits what a package actually declares and nulls the rest with a
    /// recorded reason — a vision-language config and a GPT-2 config do not carry
    /// the same keys, and pretending otherwise is how a reader invents data.
    struct Header: Decodable, Sendable {
        let modelType: String?
        let tokenizerKind: String?
        let tokenizerAlgorithm: String?
        let tokenizerFingerprint: String?
        let tokenizerVocabSize: Int?
        let vocabSize: Int?
        let coreBytesPerToken: Int?
        let numLayers: Int?
        let numHeads: Int?
        let numKVHeads: Int?
        let hiddenSize: Int?
        let headDim: Int?
        let attentionKind: String?
        let quantized: Bool?
        let quantMethod: String?
        let quantBits: Int?
        let dequantRequired: Bool?
        let readoutLayerDefault: Int?
        let padRows: Int?
        let whitespaceMarker: String?
        /// I4 / load-mutable values. Advisory only — a caller can override these at
        /// load time, so they are displayed as advisory and never trusted as fact.
        let advisoryLoadMutable: [String: Int]?

        enum CodingKeys: String, CodingKey {
            case modelType = "model_type"
            case tokenizerKind = "tokenizer_kind"
            case tokenizerAlgorithm = "tokenizer_algorithm"
            case tokenizerFingerprint = "tokenizer_fingerprint"
            case tokenizerVocabSize = "tokenizer_vocab_size"
            case vocabSize = "vocab_size"
            case coreBytesPerToken = "core_bytes_per_token"
            case numLayers = "num_layers"
            case numHeads = "num_heads"
            case numKVHeads = "num_kv_heads"
            case hiddenSize = "hidden_size"
            case headDim = "head_dim"
            case attentionKind = "attention_kind"
            case quantized
            case quantMethod = "quant_method"
            case quantBits = "quant_bits"
            case dequantRequired = "dequant_required"
            case readoutLayerDefault = "readout_layer_default"
            case padRows = "pad_rows"
            case whitespaceMarker = "whitespace_marker"
            case advisoryLoadMutable = "advisory_load_mutable"
        }

        /// Field-by-field tolerant. The synthesised initialiser throws on the first
        /// unexpected value type and takes every other field down with it; a header
        /// is a bag of independent scalars, so one surprise should cost one field.
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func str(_ k: CodingKeys) -> String? { try? c.decodeIfPresent(String.self, forKey: k) }
            func int(_ k: CodingKeys) -> Int? { try? c.decodeIfPresent(Int.self, forKey: k) }
            func bool(_ k: CodingKeys) -> Bool? { try? c.decodeIfPresent(Bool.self, forKey: k) }

            modelType = str(.modelType)
            tokenizerKind = str(.tokenizerKind)
            tokenizerAlgorithm = str(.tokenizerAlgorithm)
            tokenizerFingerprint = str(.tokenizerFingerprint)
            tokenizerVocabSize = int(.tokenizerVocabSize)
            vocabSize = int(.vocabSize)
            coreBytesPerToken = int(.coreBytesPerToken)
            numLayers = int(.numLayers)
            numHeads = int(.numHeads)
            numKVHeads = int(.numKVHeads)
            hiddenSize = int(.hiddenSize)
            headDim = int(.headDim)
            attentionKind = str(.attentionKind)
            quantized = bool(.quantized)
            quantMethod = str(.quantMethod)
            quantBits = int(.quantBits)
            dequantRequired = bool(.dequantRequired)
            readoutLayerDefault = int(.readoutLayerDefault)
            padRows = int(.padRows)
            whitespaceMarker = str(.whitespaceMarker)
            advisoryLoadMutable = try? c.decodeIfPresent([String: Int].self,
                                                         forKey: .advisoryLoadMutable)
        }

        /// The all-absent header, used when no `header.json` is present.
        static let empty = Header()

        private init() {
            modelType = nil; tokenizerKind = nil; tokenizerAlgorithm = nil
            tokenizerFingerprint = nil; tokenizerVocabSize = nil; vocabSize = nil
            coreBytesPerToken = nil; numLayers = nil; numHeads = nil; numKVHeads = nil
            hiddenSize = nil; headDim = nil; attentionKind = nil; quantized = nil
            quantMethod = nil; quantBits = nil; dequantRequired = nil
            readoutLayerDefault = nil; padRows = nil; whitespaceMarker = nil
            advisoryLoadMutable = nil
        }
    }

    // MARK: - Errors

    enum LoadError: LocalizedError, Equatable {
        case notPresent(URL)
        case unreadable(String)
        case schemaTooNew(artifact: String, reader: String)
        case truncated(field: String, expected: Int, found: Int)

        var errorDescription: String? {
            switch self {
            case .notPresent(let url):
                "No compiled Token DNA at \(url.path)"
            case .unreadable(let why):
                "Token DNA artifact is unreadable: \(why)"
            case .schemaTooNew(let artifact, let reader):
                "Artifact schema \(artifact) is newer than this build reads (\(reader))"
            case .truncated(let field, let expected, let found):
                "Field '\(field)' is truncated: manifest declares \(expected) entries, file holds \(found)"
            }
        }
    }

    // MARK: - Loading

    static func directory(for modelDirectory: URL) -> URL {
        modelDirectory.appending(path: directoryName, directoryHint: .isDirectory)
    }

    /// Is a *complete* artifact present? Presence of `manifest.json` is the
    /// contract — it is written last.
    nonisolated static func isPresent(in modelDirectory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory(for: modelDirectory).appending(path: "manifest.json").path)
    }

    /// Load the artifact. `nonisolated` on purpose: call it from a detached task.
    nonisolated static func load(modelDirectory: URL,
                                 policyID: String = "legacy_v1") throws -> SpectreDNA {
        let dir = directory(for: modelDirectory)
        let manifestURL = dir.appending(path: "manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw LoadError.notPresent(dir)
        }

        let decoder = JSONDecoder()
        let manifest: Manifest
        do {
            manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw LoadError.unreadable("manifest.json — \(error.localizedDescription)")
        }

        // Refuse a newer schema, naming both versions. Reading an unknown layout
        // and hoping is the failure this check exists to prevent.
        let artifactVersion = "\(manifest.dnaSchemaMajor).\(manifest.dnaSchemaMinor)"
        let readerVersion = "\(supportedSchemaMajor).\(supportedSchemaMinor)"
        if manifest.dnaSchemaMajor != supportedSchemaMajor
            || manifest.dnaSchemaMinor > supportedSchemaMinor {
            throw LoadError.schemaTooNew(artifact: artifactVersion, reader: readerVersion)
        }

        var header = Header.empty
        let headerURL = dir.appending(path: "header.json")
        if let data = try? Data(contentsOf: headerURL),
           let decoded = try? decoder.decode(Header.self, from: data) {
            header = decoded
        }

        // A vocabulary-free package compiles to a header-only artifact. That is a
        // valid outcome, not a failure — load it and let the UI say so.
        let count = manifest.vocabSize ?? 0

        func core(_ name: String, _ ext: String) throws -> Data? {
            let url = dir.appending(path: "core").appending(path: "\(name).\(ext)")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url)
        }

        let freqRank = try core("freq_rank", "u16").map { try readU16($0, "freq_rank", count) } ?? []
        let classFlags = try core("class_flags", "u8").map { try readU8($0, "class_flags", count) } ?? []
        let surfaceBytes = try core("surface_bytes", "u8").map { try readU8($0, "surface_bytes", count) } ?? []
        let charLen = try core("char_len", "u8").map { try readU8($0, "char_len", count) } ?? []
        let specialKind = try core("special_kind", "u8").map { try readU8($0, "special_kind", count) } ?? []

        var view: [Float]?
        var viewID: String?
        let viewURL = dir.appending(path: "views").appending(path: "\(policyID).f32")
        if manifest.views[policyID] != nil,
           let data = try? Data(contentsOf: viewURL) {
            view = readF32(data)
            viewID = policyID
        }

        return SpectreDNA(
            directory: dir, manifest: manifest, header: header,
            freqRank: freqRank, classFlags: classFlags, surfaceBytes: surfaceBytes,
            charLen: charLen, specialKind: specialKind,
            priorView: view, priorViewID: viewID,
            artifactBytes: ModelManager.directorySize(dir))
    }

    // MARK: - Raw array decoding
    //
    // The arrays are little-endian on disk. Apple platforms are little-endian too,
    // so these conversions are no-ops in practice — they are written explicitly
    // anyway so the format stays correct if that ever stops being true.

    private nonisolated static func readU8(_ data: Data, _ field: String, _ expected: Int) throws -> [UInt8] {
        if expected > 0 && data.count != expected {
            throw LoadError.truncated(field: field, expected: expected, found: data.count)
        }
        return [UInt8](data)
    }

    private nonisolated static func readU16(_ data: Data, _ field: String, _ expected: Int) throws -> [UInt16] {
        let count = data.count / MemoryLayout<UInt16>.size
        if expected > 0 && count != expected {
            throw LoadError.truncated(field: field, expected: expected, found: count)
        }
        var out = [UInt16](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                out[i] = UInt16(littleEndian: raw.loadUnaligned(
                    fromByteOffset: i * MemoryLayout<UInt16>.size, as: UInt16.self))
            }
        }
        return out
    }

    private nonisolated static func readF32(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<UInt32>.size
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let bits = UInt32(littleEndian: raw.loadUnaligned(
                    fromByteOffset: i * MemoryLayout<UInt32>.size, as: UInt32.self))
                out[i] = Float(bitPattern: bits)
            }
        }
        return out
    }

    // MARK: - Accessors

    /// Token count actually classified, distinct from a declared vocabulary size.
    var tokensClassified: Int { freqRank.count }

    var hasCore: Bool { !freqRank.isEmpty }

    /// `class_flags` bit layout — NORMATIVE, frozen at schema v1. A bit's meaning
    /// may never change; a new bit is allocated instead.
    enum ClassFlag: Int, CaseIterable, Sendable {
        case isDigitRun = 0
        case isPunctOnly = 1
        case isWhitespaceOnly = 2
        case isNewlineBearing = 3
        case isByteFragment = 4
        case isWordInitial = 5
        case isNonAlnum = 6
        case isEmoji = 7

        var label: String {
            switch self {
            case .isDigitRun: "digit run"
            case .isPunctOnly: "punctuation only"
            case .isWhitespaceOnly: "whitespace only"
            case .isNewlineBearing: "newline bearing"
            case .isByteFragment: "byte fragment"
            case .isWordInitial: "word initial"
            case .isNonAlnum: "non-alphanumeric"
            case .isEmoji: "emoji"
            }
        }
    }

    /// `special_kind` enum — NORMATIVE, frozen at schema v1.
    enum SpecialKind: UInt8, Sendable {
        case content = 0, bos = 1, eos = 2, pad = 3, unk = 4
        case control = 5, reserved = 6, modality = 7, unreachablePadRow = 8

        var label: String {
            switch self {
            case .content: "content"
            case .bos: "bos"
            case .eos: "eos"
            case .pad: "pad"
            case .unk: "unk"
            case .control: "control"
            case .reserved: "reserved"
            case .modality: "modality"
            case .unreachablePadRow: "unreachable pad row"
            }
        }
    }

    func flag(_ flag: ClassFlag, at id: Int) -> Bool {
        guard id >= 0, id < classFlags.count else { return false }
        return classFlags[id] & (1 << UInt8(flag.rawValue)) != 0
    }

    func specialKind(at id: Int) -> SpecialKind? {
        guard id >= 0, id < specialKind.count else { return nil }
        return SpecialKind(rawValue: specialKind[id])
    }

    /// One bucket of a distribution readout.
    ///
    /// A named type rather than a tuple because SwiftUI's `ForEach(_:id:)` needs a
    /// key path, and Swift key paths cannot address tuple elements.
    struct Bucket: Identifiable, Sendable, Equatable {
        let id: String
        let label: String
        let count: Int
    }

    /// How many ids carry each flag — the Token DNA panel's distribution readout.
    func flagCounts() -> [Bucket] {
        var counts = [Int](repeating: 0, count: ClassFlag.allCases.count)
        for byte in classFlags {
            for flag in ClassFlag.allCases where byte & (1 << UInt8(flag.rawValue)) != 0 {
                counts[flag.rawValue] += 1
            }
        }
        return ClassFlag.allCases.map {
            Bucket(id: "flag-\($0.rawValue)", label: $0.label, count: counts[$0.rawValue])
        }
    }

    /// How many ids fall in each special-kind bucket, largest first.
    func specialKindCounts() -> [Bucket] {
        var counts: [UInt8: Int] = [:]
        for raw in specialKind { counts[raw, default: 0] += 1 }
        return counts
            .compactMap { raw, n -> Bucket? in
                guard let kind = SpecialKind(rawValue: raw) else { return nil }
                // `content` is every ordinary token; showing it would flatten the rest.
                guard kind != .content else { return nil }
                return Bucket(id: "kind-\(raw)", label: kind.label, count: n)
            }
            .sorted { $0.count > $1.count }
    }
}
