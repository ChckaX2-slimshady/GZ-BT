import XCTest
@testable import GZBT

/// Proves the Spectre lab's **execution path** actually consumes a compiled Token
/// DNA artifact — not that the reader works in isolation.
///
/// The distinction matters. `SpectreDNA.load` was verified separately against a
/// real artifact from the Python compiler, value-for-value. What that did *not*
/// prove is that the app ever reaches it: `AppEnvironment` → `SpectreLabViewModel`
/// → `SpectreDNA.load` → the rows a panel renders. This suite drives that chain
/// end to end against a byte-level fixture, so a regression that disconnects the
/// wiring fails here rather than on a phone.
///
/// The fixture is written as **raw little-endian bytes**, deliberately not by
/// calling the reader's own helpers — a test that encodes with the same code it
/// decodes with proves only self-consistency.
final class SpectreLabIntegrationTests: XCTestCase {

    // MARK: - Fixture

    /// A four-token artifact. Small enough to assert every value by hand.
    private struct Fixture {
        static let vocabSize = 4
        static let freqRank: [UInt16] = [0, 1, 2, 65535]
        static let classFlags: [UInt8] = [66, 0, 1, 128]
        static let surfaceBytes: [UInt8] = [1, 3, 2, 5]
        static let charLen: [UInt8] = [1, 3, 2, 5]
        /// Last id is eos (SPECIAL_KIND 2), the rest are content (0).
        static let specialKind: [UInt8] = [0, 0, 0, 2]
        static let view: [Float] = [0.25, 0.5, 0.75, 1.0]
        static let contentHash = String(repeating: "ab", count: 32)
    }

    private var workDirectory: URL!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appending(path: "spectre-lab-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
    }

    /// Build a model directory that `ModelManager` will accept, optionally with a
    /// compiled artifact beside it.
    @discardableResult
    private func makeModel(named name: String,
                           withArtifact: Bool,
                           schemaMinor: Int = 0) throws -> URL {
        let fm = FileManager.default
        let modelDir = workDirectory.appending(path: name, directoryHint: .isDirectory)
        try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)

        // `ModelManager.isUsableModelDirectory` requires all three.
        try Data("""
        {"model_type":"qwen3","max_position_embeddings":4096,"vocab_size":4}
        """.utf8).write(to: modelDir.appending(path: "config.json"))
        try Data("{}".utf8).write(to: modelDir.appending(path: "tokenizer.json"))
        try Data([0x00]).write(to: modelDir.appending(path: "model.safetensors"))

        guard withArtifact else { return modelDir }

        let dna = modelDir.appending(path: ".spectre-dna", directoryHint: .isDirectory)
        let core = dna.appending(path: "core", directoryHint: .isDirectory)
        let views = dna.appending(path: "views", directoryHint: .isDirectory)
        try fm.createDirectory(at: core, withIntermediateDirectories: true)
        try fm.createDirectory(at: views, withIntermediateDirectories: true)

        // Raw little-endian, written by hand.
        var freqRankBytes = Data()
        for value in Fixture.freqRank {
            freqRankBytes.append(UInt8(value & 0xFF))
            freqRankBytes.append(UInt8((value >> 8) & 0xFF))
        }
        try freqRankBytes.write(to: core.appending(path: "freq_rank.u16"))
        try Data(Fixture.classFlags).write(to: core.appending(path: "class_flags.u8"))
        try Data(Fixture.surfaceBytes).write(to: core.appending(path: "surface_bytes.u8"))
        try Data(Fixture.charLen).write(to: core.appending(path: "char_len.u8"))
        try Data(Fixture.specialKind).write(to: core.appending(path: "special_kind.u8"))

        var viewBytes = Data()
        for value in Fixture.view {
            let bits = value.bitPattern
            for shift in stride(from: 0, through: 24, by: 8) {
                viewBytes.append(UInt8((bits >> UInt32(shift)) & 0xFF))
            }
        }
        try viewBytes.write(to: views.appending(path: "legacy_v1.f32"))

        try Data("""
        {"model_type":"qwen3","tokenizer_kind":"tokenizers-json","tokenizer_algorithm":"bpe",
         "core_bytes_per_token":6,"num_layers":28,"num_heads":16,"num_kv_heads":8,
         "hidden_size":1024,"attention_kind":"gqa","quantized":true,"quant_method":"mlx",
         "quant_bits":4,"advisory_load_mutable":{"max_position_embeddings":4096,
          "rope_scaling":{"factor":32.0,"rope_type":"llama3"}}}
        """.utf8).write(to: dna.appending(path: "header.json"))

        // manifest.json LAST — its presence is the completeness contract.
        try Data("""
        {"dna_schema_major":1,"dna_schema_minor":\(schemaMinor),"compiler_version":"1.0.0",
         "content_hash":"\(Fixture.contentHash)","vocab_size":\(Fixture.vocabSize),
         "fields":{"freq_rank":{"dtype":"u16","length":4,"tier":"core"},
                   "class_flags":{"dtype":"u8","length":4,"tier":"core"},
                   "surface_bytes":{"dtype":"u8","length":4,"tier":"core"},
                   "char_len":{"dtype":"u8","length":4,"tier":"core"},
                   "special_kind":{"dtype":"u8","length":4,"tier":"core"}},
         "fields_null":{"emb_row_norm":"not requested","untrained":"not requested"},
         "views":{"legacy_v1":{"dtype":"f32","length":4,"policy_version":"1.0.0"}},
         "tokenizer_fingerprint":"deadbeef"}
        """.utf8).write(to: dna.appending(path: "manifest.json"))

        return modelDir
    }

    /// A view model wired the way `AppEnvironment` wires it, over an injected store.
    @MainActor
    private func makeViewModel() async throws -> (SpectreLabViewModel, ModelManager, AppSettings) {
        let models = ModelManager(root: workDirectory)
        await models.scan()
        let settings = AppSettings()
        return (SpectreLabViewModel(models: models, settings: settings), models, settings)
    }

    // MARK: - The execution path

    @MainActor
    func testExecutionPathConsumesCompiledArtifact() async throws {
        try makeModel(named: "qwen3-test", withArtifact: true)
        let (vm, models, _) = try await makeViewModel()

        XCTAssertEqual(models.models.count, 1, "fixture model was not discovered")
        models.activeModelID = models.models[0].id

        await vm.load()

        // The reader ran and the view model is holding its output.
        guard let dna = vm.dna else {
            return XCTFail("execution path did not reach a loaded artifact: \(vm.state)")
        }
        XCTAssertTrue(vm.isPresent)
        XCTAssertNil(vm.absenceReason)

        // Values decoded from the hand-written bytes.
        XCTAssertEqual(dna.manifest.vocabSize, Fixture.vocabSize)
        XCTAssertEqual(dna.manifest.contentHash, Fixture.contentHash)
        XCTAssertEqual(dna.freqRank, Fixture.freqRank, "u16 little-endian decode is wrong")
        XCTAssertEqual(dna.classFlags, Fixture.classFlags)
        XCTAssertEqual(dna.surfaceBytes, Fixture.surfaceBytes)
        XCTAssertEqual(dna.charLen, Fixture.charLen)
        XCTAssertEqual(dna.specialKind, Fixture.specialKind)
        XCTAssertEqual(dna.priorView, Fixture.view, "f32 little-endian decode is wrong")
        XCTAssertEqual(dna.priorViewID, "legacy_v1")
        XCTAssertEqual(dna.tokensClassified, 4)
        XCTAssertTrue(dna.hasCore)

        // Bit and enum decoding, against the frozen schema-v1 layout.
        XCTAssertEqual(dna.flag(.isPunctOnly, at: 0), true, "bit 1 of 66 should be set")
        XCTAssertEqual(dna.flag(.isNonAlnum, at: 0), true, "bit 6 of 66 should be set")
        XCTAssertEqual(dna.flag(.isDigitRun, at: 0), false, "bit 0 of 66 should be clear")
        XCTAssertEqual(dna.flag(.isEmoji, at: 3), true, "bit 7 of 128 should be set")
        XCTAssertEqual(dna.specialKind(at: 3), .eos)
        XCTAssertEqual(dna.specialKind(at: 0), .content)

        // Out-of-range access is refused rather than trapping.
        // nil, not false: an id the artifact does not cover is an absence, and a
        // caller must be able to tell it from a token that lacks the flag.
        XCTAssertNil(dna.flag(.isEmoji, at: 99))
        XCTAssertNil(dna.specialKind(at: 99))

        // And the panel's rows actually carry it.
        let dnaValues = vm.dnaRows.map(\.value)
        XCTAssertTrue(dnaValues.contains("1.0"), "schema row missing: \(dnaValues)")
        XCTAssertTrue(dnaValues.contains("6 bytes / token"), "core row missing: \(dnaValues)")
        XCTAssertTrue(dnaValues.contains("legacy_v1"), "policy view row missing: \(dnaValues)")

        let modelValues = vm.modelRows.map(\.value)
        XCTAssertTrue(modelValues.contains("qwen3"), "architecture row missing: \(modelValues)")
        XCTAssertTrue(modelValues.contains("tokenizers-json · bpe"),
                      "tokenizer row missing: \(modelValues)")
        XCTAssertTrue(modelValues.contains("mlx · 4-bit"), "quantisation row missing: \(modelValues)")

        // The three-state contract survives to the UI: absent fields carry reasons.
        XCTAssertEqual(vm.nullFields.count, 2)
        XCTAssertTrue(vm.nullFields.allSatisfy { !$0.value.isEmpty },
                      "a null field reached the panel without a reason")

        // Distributions are computed from the real arrays.
        let flagLabels = vm.flagDistribution.map(\.label)
        XCTAssertTrue(flagLabels.contains("emoji"), "expected the emoji bit: \(flagLabels)")
        XCTAssertEqual(vm.specialKindDistribution.first(where: { $0.label == "eos" })?.count, 1)
        XCTAssertFalse(vm.specialKindDistribution.contains { $0.label == "content" },
                       "content would swamp the chart and is excluded by contract")
    }

    // MARK: - Refusing rather than fabricating
    //
    // Each of these pins a defect where the reader produced a complete,
    // plausible, wrong answer instead of an error. That failure mode has a name
    // in this project: SIGS-A §1.2/F7, where reading a packed embedding tensor
    // yielded "a complete, plausible, entirely meaningless geometry report".

    @MainActor
    func testMissingCoreArrayIsRefusedNotRenderedAsZeros() async throws {
        let dir = try makeModel(named: "gappy", withArtifact: true)
        // The manifest still declares class_flags; delete only the file.
        try FileManager.default.removeItem(
            at: dir.appending(path: ".spectre-dna/core/class_flags.u8"))

        let (vm, models, _) = try await makeViewModel()
        models.activeModelID = models.models[0].id
        await vm.load()

        XCTAssertFalse(vm.isPresent, "an incomplete artifact must not load")
        guard case .failed(let why) = vm.state else {
            return XCTFail("expected .failed, got \(vm.state)")
        }
        XCTAssertTrue(why.contains("class_flags"), "the missing field should be named: \(why)")
        // The specific regression: an all-zero distribution reported as real.
        XCTAssertTrue(vm.flagDistribution.isEmpty,
                      "a fabricated distribution reached the panel")
    }

    @MainActor
    func testTruncatedPolicyViewIsRefused() async throws {
        let dir = try makeModel(named: "cutoff", withArtifact: true)
        let viewURL = dir.appending(path: ".spectre-dna/views/legacy_v1.f32")
        let full = try Data(contentsOf: viewURL)
        try full.prefix(full.count / 2).write(to: viewURL)   // 2 of 4 floats

        let (vm, models, _) = try await makeViewModel()
        models.activeModelID = models.models[0].id
        await vm.load()

        guard case .failed(let why) = vm.state else {
            return XCTFail("a half-length view loaded; expected .failed, got \(vm.state)")
        }
        XCTAssertTrue(why.contains("2") && why.contains("4"),
                      "both declared and found lengths should appear: \(why)")
    }

    @MainActor
    func testStructuredAdvisoryValuesDoNotDiscardTheScalarOnes() async throws {
        // The fixture carries `rope_scaling` (a dict) beside
        // `max_position_embeddings` (an Int) — the shape every RoPE-scaled model
        // actually produces. Typing the block [String: Int] threw on the dict
        // and, swallowed by try?, discarded the whole block including the scalar.
        try makeModel(named: "roped", withArtifact: true)
        let (vm, models, _) = try await makeViewModel()
        models.activeModelID = models.models[0].id
        await vm.load()

        let advisory = try XCTUnwrap(vm.dna?.header.advisoryLoadMutable)
        XCTAssertEqual(advisory["max_position_embeddings"], 4096,
                       "the scalar was discarded by a sibling structured value")
        XCTAssertEqual(vm.dna?.header.advisoryNonScalarKeys, ["rope_scaling"],
                       "a structured key vanished without being named")
    }

    @MainActor
    func testUnverifiableArtifactPairingSaysSo() async throws {
        // Hand-copying a .spectre-dna directory is the documented workflow, so
        // pairing the wrong two is an ordinary accident. Unflagged, the panel
        // renders another model's genotype as this model's. The fixture records
        // "deadbeef" — a sentinel, not a hash — so the honest verdict is
        // "unverified", never "matches".
        try makeModel(named: "unpaired", withArtifact: true)
        let (vm, models, _) = try await makeViewModel()
        models.activeModelID = models.models[0].id
        await vm.load()

        XCTAssertFalse(vm.isDrifted)
        XCTAssertEqual(vm.driftLabel, "unverified")
        XCTAssertNotNil(vm.driftCaveat, "an unverifiable pairing must say so")
    }

    @MainActor
    func testRepeatLoadKeepsTheArtifact() async throws {
        try makeModel(named: "cached", withArtifact: true)
        let (vm, models, _) = try await makeViewModel()
        models.activeModelID = models.models[0].id

        await vm.load()
        let firstHash = vm.dna?.manifest.contentHash
        await vm.load()   // the panel's .task fires again on every appearance
        XCTAssertEqual(vm.dna?.manifest.contentHash, firstHash)
        XCTAssertTrue(vm.isPresent, "the repeat load dropped the artifact")
    }

    // MARK: - Refusals

    @MainActor
    func testAbsentArtifactIsReportedNotFabricated() async throws {
        try makeModel(named: "no-dna", withArtifact: false)
        let (vm, models, _) = try await makeViewModel()
        models.activeModelID = models.models[0].id

        await vm.load()

        XCTAssertFalse(vm.isPresent)
        XCTAssertNil(vm.dna)
        XCTAssertNotNil(vm.absenceReason)
        if case .absent = vm.state {} else { XCTFail("expected .absent, got \(vm.state)") }
        // The model panel still renders from config.json alone.
        XCTAssertTrue(vm.modelRows.map(\.value).contains("qwen3"))
        // And nothing invented a vocabulary.
        XCTAssertTrue(vm.dnaRows.isEmpty)
    }

    @MainActor
    func testNewerSchemaIsRefusedRatherThanPartiallyRead() async throws {
        try makeModel(named: "future", withArtifact: true, schemaMinor: 99)
        let (vm, models, _) = try await makeViewModel()
        models.activeModelID = models.models[0].id

        await vm.load()

        XCTAssertFalse(vm.isPresent, "a newer schema must not load")
        guard case .failed(let why) = vm.state else {
            return XCTFail("expected .failed, got \(vm.state)")
        }
        XCTAssertTrue(why.contains("1.99"), "the artifact version should be named: \(why)")
        XCTAssertTrue(why.contains("1.\(SpectreDNA.supportedSchemaMinor)"),
                      "the reader version should be named: \(why)")
    }

    /// The minor the current compiler emits must load — not merely some minor
    /// the reader once supported. Compiler 1.1.0 writes schema 1.1 because it
    /// changed what `surface_bytes` and `char_len` hold for special tokens. A
    /// reader still pinned to 1.0 refuses every artifact the toolchain now
    /// produces, and the panel reports a version quarrel instead of a model.
    /// Older minors keep loading: every other test in this file uses 1.0.
    @MainActor
    func testCurrentCompilerSchemaMinorLoads() async throws {
        try makeModel(named: "current", withArtifact: true,
                      schemaMinor: SpectreDNA.supportedSchemaMinor)
        let (vm, models, _) = try await makeViewModel()
        models.activeModelID = models.models[0].id

        await vm.load()

        XCTAssertTrue(vm.isPresent,
                      "schema 1.\(SpectreDNA.supportedSchemaMinor) must load: \(vm.state)")
        XCTAssertEqual(vm.dna?.manifest.dnaSchemaMinor, SpectreDNA.supportedSchemaMinor)
    }

    // MARK: - Control architecture

    @MainActor
    func testUnbuiltModulesCannotBeEnabled() async throws {
        let (vm, _, settings) = try await makeViewModel()
        let originalEnabled = settings.spectreEnabled
        let originalModules = settings.spectreModules
        defer {
            settings.spectreEnabled = originalEnabled
            settings.spectreModules = originalModules
        }

        settings.spectreEnabled = true

        // A hook-only mechanism must not become effective, and the request itself
        // must be refused at the setter — not silently accepted and dropped later.
        vm.setRequested("kv_clustering", true)
        XCTAssertFalse(vm.isRequested("kv_clustering"),
                       "an unbuilt module was recorded as requested")
        XCTAssertFalse(vm.isEffective("kv_clustering"))

        vm.setRequested("speculative_decoding", true)
        XCTAssertFalse(vm.isEffective("speculative_decoding"))

        // A built module works, and pulls its dependency with it, with a note.
        settings.spectreModules = []
        vm.setRequested("compiled_lexical_prior", true)
        let resolution = vm.resolution
        XCTAssertTrue(resolution.effective.contains("compiled_lexical_prior"))
        XCTAssertTrue(resolution.effective.contains("token_dna"),
                      "dependency closure did not run: \(resolution.effective)")
        XCTAssertTrue(resolution.notes.contains { $0.contains("required by") },
                      "implied enablement was not reported: \(resolution.notes)")
    }

    @MainActor
    func testSpectreOffDisablesEveryModule() async throws {
        let (vm, _, settings) = try await makeViewModel()
        let originalEnabled = settings.spectreEnabled
        let originalModules = settings.spectreModules
        defer {
            settings.spectreEnabled = originalEnabled
            settings.spectreModules = originalModules
        }

        settings.spectreEnabled = false
        settings.spectreModules = ["token_dna", "compiled_lexical_prior"]

        XCTAssertTrue(vm.resolution.effective.isEmpty,
                      "the primary switch did not gate the module set")
        XCTAssertTrue(vm.resolution.notes.contains { $0.contains("Spectre is off") })
    }

    /// The honesty contract, asserted rather than asserted-in-prose.
    @MainActor
    func testNoModuleClaimsMeasuredEfficacy() throws {
        let claiming = SpectreLabRegistry.all.filter {
            switch $0.efficacy {
            case .measuredPositive, .measuredNeutral, .measuredNegative: true
            case .unmeasured, .mechanicsOnly: false
            }
        }
        XCTAssertTrue(claiming.isEmpty,
                      "no efficacy verdict has run; these claim one: \(claiming.map(\.id))")
    }

    @MainActor
    func testThroughputQuestionHasNoBuiltInstrument() throws {
        // Canon calls the tok/s harness step zero and it is not built. Nothing may
        // present itself as able to settle throughput — the mirror of the rule the
        // Python self-test enforces.
        let (modules, anyBuilt) = SpectreLabRegistry.instruments(for: .throughput)
        XCTAssertFalse(modules.isEmpty, "the question should still be registered")
        XCTAssertFalse(anyBuilt,
                       "a built module claims to settle throughput: "
                       + modules.filter { $0.status == .built }.map(\.id).description)

        let (_, transferBuilt) = SpectreLabRegistry.instruments(for: .transfer)
        XCTAssertFalse(transferBuilt, "transfer has no built instrument either")

        // The two that DO have instruments, so this test fails if the registry is
        // gutted rather than merely honest.
        XCTAssertTrue(SpectreLabRegistry.instruments(for: .signalQuality).anyBuilt)
        XCTAssertTrue(SpectreLabRegistry.instruments(for: .integration).anyBuilt)
    }
}
