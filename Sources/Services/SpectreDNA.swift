import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

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
    /// Why there is no view, when there is none. Never a bare absence.
    let priorViewAbsenceReason: String?
    /// Why the header is empty, when it is.
    let headerAbsenceReason: String?
    /// Whether this artifact provably belongs to this model.
    let tokenizerDrift: Drift

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
        /// I4 / load-mutable values that are plain integers. Advisory only — a
        /// caller can override these at load time, so they are displayed as
        /// advisory and never trusted as fact.
        ///
        /// **Scalar only.** The compiler's load-mutable set also contains
        /// structured values (`rope_scaling` is a dict, and every RoPE-scaled
        /// model has one). Typing the whole block `[String: Int]` made
        /// `decodeIfPresent` throw for those models and — swallowed by `try?` —
        /// discarded the block entirely, including `max_position_embeddings`.
        /// The non-scalar keys are now named in `advisoryNonScalarKeys` instead
        /// of vanishing.
        let advisoryLoadMutable: [String: Int]?
        /// Load-mutable keys whose values are not plain integers, so a reader
        /// knows they exist rather than believing the artifact omitted them.
        let advisoryNonScalarKeys: [String]

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

            // Decode the block key-by-key so one structured value cannot cost the
            // scalar ones. `rope_scaling` is a dict on every RoPE-scaled model.
            if let raw = try? c.decodeIfPresent([String: AnyCodableScalar].self,
                                                forKey: .advisoryLoadMutable) {
                var ints: [String: Int] = [:]
                var others: [String] = []
                for (k, v) in raw {
                    if let i = v.intValue { ints[k] = i } else { others.append(k) }
                }
                advisoryLoadMutable = ints.isEmpty ? nil : ints
                advisoryNonScalarKeys = others.sorted()
            } else {
                advisoryLoadMutable = nil
                advisoryNonScalarKeys = []
            }
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
            advisoryLoadMutable = nil; advisoryNonScalarKeys = []
        }
    }

    /// Decodes any JSON value, exposing it as an `Int` only when it genuinely is
    /// one. Exists so a heterogeneous block can be read without one odd value
    /// throwing away the rest.
    struct AnyCodableScalar: Decodable, Sendable {
        let intValue: Int?

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            // Bool first: `Bool` decodes as an Int in some containers, and a
            // flag is not a measurement.
            if (try? c.decode(Bool.self)) != nil {
                intValue = nil
            } else if let i = try? c.decode(Int.self) {
                intValue = i
            } else {
                intValue = nil
            }
        }
    }

    // MARK: - Errors

    enum LoadError: LocalizedError, Equatable {
        case notPresent(URL)
        case unreadable(String)
        case schemaTooNew(artifact: String, reader: String)
        /// A different major version, not necessarily a newer one.
        case schemaIncompatible(artifact: String, reader: String)
        case truncated(field: String, expected: Int, found: Int)
        /// The manifest declares a field the artifact does not contain.
        case fieldMissing(field: String, declaredLength: Int)

        var errorDescription: String? {
            switch self {
            case .notPresent(let url):
                "No compiled Token DNA at \(url.path)"
            case .unreadable(let why):
                "Token DNA artifact is unreadable: \(why)"
            case .schemaTooNew(let artifact, let reader):
                "Artifact schema \(artifact) is newer than this build reads (\(reader))"
            case .schemaIncompatible(let artifact, let reader):
                "Artifact schema \(artifact) is a different major version than this build reads (\(reader))"
            case .truncated(let field, let expected, let found):
                "Field '\(field)' is truncated: manifest declares \(expected) entries, file holds \(found)"
            case .fieldMissing(let field, let declaredLength):
                "Artifact is incomplete: the manifest declares '\(field)' with \(declaredLength) "
                + "entries, but the file is absent. Refusing rather than reporting an empty field "
                + "as a real distribution."
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
        if manifest.dnaSchemaMajor != supportedSchemaMajor {
            // An older major is incompatible too, but calling it "newer" is a lie
            // that sends a reader looking for an app update that will not help.
            throw LoadError.schemaIncompatible(artifact: artifactVersion, reader: readerVersion)
        }
        if manifest.dnaSchemaMinor > supportedSchemaMinor {
            throw LoadError.schemaTooNew(artifact: artifactVersion, reader: readerVersion)
        }

        // A header that is present but unreadable is a real failure, not an
        // absence. Degrading silently to `.empty` would report every
        // architecture field as "this model declares nothing" — indistinguishable
        // from a package that genuinely declares nothing.
        var header = Header.empty
        var headerNote: String?
        let headerURL = dir.appending(path: "header.json")
        if FileManager.default.fileExists(atPath: headerURL.path) {
            do {
                header = try decoder.decode(Header.self, from: Data(contentsOf: headerURL))
            } catch {
                throw LoadError.unreadable("header.json — \(error.localizedDescription)")
            }
        } else {
            headerNote = "no header.json in the artifact"
        }

        // A vocabulary-free package compiles to a header-only artifact. That is a
        // valid outcome, not a failure — load it and let the UI say so.
        //
        // Lengths are validated against `manifest.fields[name].length`, the
        // per-field declaration, NOT against vocab_size. They are equal today,
        // but only the per-field value is what the writer actually promised, and
        // when vocab_size is nil a vocab_size check silently disables itself.
        func core(_ name: String, _ ext: String) throws -> Data? {
            let url = dir.appending(path: "core").appending(path: "\(name).\(ext)")
            let declared = manifest.fields[name]
            let exists = FileManager.default.fileExists(atPath: url.path)
            // Declared in the manifest but absent on disk: the artifact is
            // incomplete. Returning nil here produced an empty array, and an
            // empty array renders as a complete, plausible, all-zero
            // distribution — the exact failure SIGS-A §1.2/F7 documents.
            guard exists else {
                if declared != nil {
                    throw LoadError.fieldMissing(field: name,
                                                 declaredLength: declared?.length ?? 0)
                }
                return nil
            }
            return try Data(contentsOf: url)
        }

        func expected(_ name: String) -> Int { manifest.fields[name]?.length ?? -1 }

        let freqRank = try core("freq_rank", "u16")
            .map { try readU16($0, "freq_rank", expected("freq_rank")) } ?? []
        let classFlags = try core("class_flags", "u8")
            .map { try readU8($0, "class_flags", expected("class_flags")) } ?? []
        let surfaceBytes = try core("surface_bytes", "u8")
            .map { try readU8($0, "surface_bytes", expected("surface_bytes")) } ?? []
        let charLen = try core("char_len", "u8")
            .map { try readU8($0, "char_len", expected("char_len")) } ?? []
        let specialKind = try core("special_kind", "u8")
            .map { try readU8($0, "special_kind", expected("special_kind")) } ?? []

        // The policy view gets the same treatment: declared-and-missing is an
        // error, and a present file must match its declared length. A truncated
        // view previously loaded at whatever length it happened to be while the
        // panel reported it active — and any consumer indexing past the truncation
        // point would be out of range.
        var view: [Float]?
        var viewID: String?
        var viewNote: String?
        if let declaredView = manifest.views[policyID] {
            let viewURL = dir.appending(path: "views").appending(path: "\(policyID).f32")
            guard FileManager.default.fileExists(atPath: viewURL.path) else {
                throw LoadError.fieldMissing(field: "views/\(policyID)",
                                             declaredLength: declaredView.length)
            }
            let decoded = readF32(try Data(contentsOf: viewURL))
            guard decoded.count == declaredView.length else {
                throw LoadError.truncated(field: "views/\(policyID)",
                                          expected: declaredView.length,
                                          found: decoded.count)
            }
            view = decoded
            viewID = policyID
        } else {
            viewNote = manifest.views.isEmpty
                ? "no policy view was materialised by the compiler"
                : "policy '\(policyID)' not among materialised views: "
                  + manifest.views.keys.sorted().joined(separator: ", ")
        }

        return SpectreDNA(
            directory: dir, manifest: manifest, header: header,
            freqRank: freqRank, classFlags: classFlags, surfaceBytes: surfaceBytes,
            charLen: charLen, specialKind: specialKind,
            priorView: view, priorViewID: viewID, priorViewAbsenceReason: viewNote,
            headerAbsenceReason: headerNote,
            tokenizerDrift: driftCheck(modelDirectory: modelDirectory, manifest: manifest),
            artifactBytes: ModelManager.directorySize(dir))
    }

    // MARK: - Drift interlock

    /// Does this artifact actually belong to this model?
    ///
    /// The documented workflow is hand-copying a `.spectre-dna` directory next
    /// to a model, so pairing the wrong two is a likely accident rather than an
    /// exotic one — and without a check it loads silently and renders another
    /// model's genotype. The compiler records `tokenizer_fingerprint` as a plain
    /// SHA-256 of the tokenizer artifact it read, so the same hash is
    /// reproducible here with no shared code.
    enum Drift: Sendable, Equatable {
        case matches(String)
        case mismatch(recorded: String, found: String)
        /// Nothing to compare: a vocabulary-free or closed-form package records a
        /// sentinel rather than a hash, or no tokenizer file is present.
        case notCheckable(String)

        var isMismatch: Bool { if case .mismatch = self { return true }; return false }
    }

    /// SHA-256 of `data`, lowercase hex — the same digest the Python compiler
    /// records, so the two are directly comparable.
    ///
    /// CryptoKit on Apple platforms; a portable implementation elsewhere. The
    /// fallback exists so this file still type-checks and runs off-device, which
    /// is where its decode logic gets verified against real artifacts — using
    /// CryptoKit unconditionally would make the whole reader unverifiable
    /// outside Xcode. Both paths are checked against `hashlib.sha256` output.
    nonisolated static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return SHA256Portable.hex(data)
        #endif
    }

    /// Candidate tokenizer artifacts, in the order the compiler detects them.
    static let tokenizerFiles = ["tokenizer.json", "tokenizer.model", "spiece.model",
                                 "spm.model", "sentencepiece.bpe.model", "vocab.json",
                                 "vocab.txt"]

    private nonisolated static func driftCheck(modelDirectory: URL,
                                               manifest: Manifest) -> Drift {
        guard let recorded = manifest.tokenizerFingerprint, !recorded.isEmpty else {
            return .notCheckable("the artifact records no tokenizer fingerprint")
        }
        // Closed-form and vocabulary-free packages record a sentinel, not a hash.
        guard recorded.count == 64, recorded.allSatisfy(\.isHexDigit) else {
            return .notCheckable("fingerprint is a sentinel, not a file hash: \(recorded)")
        }
        var seen: [String] = []
        for name in tokenizerFiles {
            let f = modelDirectory.appending(path: name)
            guard let data = try? Data(contentsOf: f) else { continue }
            if sha256Hex(data) == recorded { return .matches(name) }
            seen.append(name)
        }
        if seen.isEmpty {
            return .notCheckable("no tokenizer artifact beside the model to compare against")
        }
        return .mismatch(recorded: recorded, found: seen.joined(separator: ", "))
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

    /// Nil for an id this artifact does not cover — an absence, not a `false`.
    /// Returning `false` for an out-of-range id is a sentinel, and a caller
    /// cannot tell it apart from a token that genuinely lacks the flag.
    func flag(_ flag: ClassFlag, at id: Int) -> Bool? {
        guard id >= 0, id < classFlags.count else { return nil }
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
