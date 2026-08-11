import Foundation
import Observation

/// Presentation state for the Spectre research lab — the instrument panel over
/// the compiled Token DNA artifact and the experimental module registry.
///
/// This is a **read layer**. It loads an artifact the Spectre compiler produced
/// and reports what is in it; it compiles nothing, and it runs no mechanism. The
/// module switches record intent and resolve dependencies — what actually drives
/// the engine is a later decision, and the panel says so rather than implying
/// otherwise.
///
/// Layer: **ViewModels**. Holds no visual tokens. The artifact load runs off the
/// main actor via `Task.detached`, the same posture `ModelManager.scan()` takes,
/// because decoding a 150k-entry vocabulary on the main thread would hitch the UI.
@MainActor
@Observable
final class SpectreLabViewModel {

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(SpectreDNA)
        case absent(URL)
        case failed(String)

        static func == (lhs: LoadState, rhs: LoadState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading): true
            case (.loaded(let a), .loaded(let b)): a.manifest.contentHash == b.manifest.contentHash
            case (.absent(let a), .absent(let b)): a == b
            case (.failed(let a), .failed(let b)): a == b
            default: false
            }
        }
    }

    private let models: ModelManager
    private let settings: AppSettings

    private(set) var state: LoadState = .idle
    /// Wall-clock of the load that produced `state`, for the panel's freshness line.
    private(set) var loadedAt: Date?
    private(set) var loadMilliseconds: Double?

    init(models: ModelManager, settings: AppSettings) {
        self.models = models
        self.settings = settings
    }

    // MARK: - Active model

    var activeModel: DiscoveredModel? { models.activeModel }
    var activeModelName: String { models.activeModel?.name ?? "—" }

    var dna: SpectreDNA? {
        if case .loaded(let dna) = state { return dna }
        return nil
    }

    var isPresent: Bool { dna != nil }

    /// Why there is no artifact, phrased for the panel. Nil when one is loaded.
    var absenceReason: String? {
        switch state {
        case .loaded: nil
        case .idle: "Not loaded yet."
        case .loading: "Loading…"
        case .absent:
            "No compiled Token DNA beside this model. Compile it with "
            + "tools/spectre_compile.py on a machine with the Spectre repo, then "
            + "copy the .spectre-dna directory into the model folder."
        case .failed(let why): why
        }
    }

    // MARK: - Loading

    /// Which model the current `state` describes, so a repeat appearance does not
    /// re-read the artifact.
    private var loadedModelID: String?

    /// Load the artifact for the active model, unless it is already loaded.
    ///
    /// `force` re-reads regardless — for a deliberate refresh after compiling an
    /// artifact while the app is running.
    func load(force: Bool = false) async {
        guard let model = models.activeModel else {
            state = .idle
            loadedModelID = nil
            return
        }
        // The panel's `.task` fires on every appearance, including each flip of
        // the Live/Lab picker. Re-decoding 128k entries element-by-element every
        // time defeats the reason this view model is long-lived at all.
        if !force, loadedModelID == model.id, case .loaded = state { return }

        let url = model.url
        state = .loading
        loadedModelID = model.id
        let started = Date()

        let outcome = await Task.detached(priority: .userInitiated) { () -> LoadOutcome in
            do {
                return .ok(try SpectreDNA.load(modelDirectory: url))
            } catch let error as SpectreDNA.LoadError {
                if case .notPresent(let dir) = error { return .absent(dir) }
                return .failed(error.errorDescription ?? "\(error)")
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value

        loadMilliseconds = Date().timeIntervalSince(started) * 1000
        loadedAt = Date()

        switch outcome {
        case .ok(let dna): state = .loaded(dna)
        case .absent(let dir): state = .absent(dir)
        case .failed(let why): state = .failed(why)
        }
    }

    /// What a detached load produced.
    ///
    /// A dedicated `Sendable` type rather than `Result<SpectreDNA, any Error>`:
    /// `any Error` is not `Sendable`, so a `Result` carrying one cannot cross the
    /// task boundary under strict concurrency. The error is reduced to its message
    /// on the far side, where it is still the concrete error.
    private enum LoadOutcome: Sendable {
        case ok(SpectreDNA)
        case absent(URL)
        case failed(String)
    }

    // MARK: - Model information panel

    struct Row: Identifiable, Equatable {
        let id = UUID()
        let label: String
        let value: String
        /// Shown under the value when the number needs a caveat.
        let caveat: String?

        init(_ label: String, _ value: String, caveat: String? = nil) {
            self.label = label
            self.value = value
            self.caveat = caveat
        }
    }

    var modelRows: [Row] {
        let header = dna?.header
        let config = activeModel
        return [
            Row("model", config?.name ?? "—"),
            Row("architecture", header?.modelType ?? config?.architecture ?? "—"),
            Row("tokenizer", tokenizerDescription),
            Row("vocabulary", vocabularyDescription),
            Row("quantisation", quantisationDescription),
            Row("layers / hidden",
                pair(header?.numLayers, header?.hiddenSize)),
            Row("heads (q / kv)",
                pair(header?.numHeads, header?.numKVHeads)),
            Row("attention", header?.attentionKind ?? "—"),
            Row("context",
                contextDescription,
                caveat: "advisory — load-mutable, a caller can override it"),
            Row("on disk", config.map { ByteFormat.string($0.sizeBytes) } ?? "—"),
        ]
    }

    private func pair(_ a: Int?, _ b: Int?) -> String {
        guard let a, let b else { return "—" }
        return "\(a) / \(b)"
    }

    private var tokenizerDescription: String {
        guard let header = dna?.header else { return "—" }
        let kind = header.tokenizerKind ?? "—"
        guard let algorithm = header.tokenizerAlgorithm else { return kind }
        return "\(kind) · \(algorithm)"
    }

    private var vocabularyDescription: String {
        // Nil is meaningful: a vocabulary-free package has no size, which is not
        // the same as a size of zero.
        guard let manifest = dna?.manifest else {
            return activeModel.map { _ in "—" } ?? "—"
        }
        guard let size = manifest.vocabSize else { return "none (vocabulary-free package)" }
        return size.formatted(.number)
    }

    private var quantisationDescription: String {
        guard let header = dna?.header else { return activeModel?.quantization ?? "—" }
        if header.quantized == true {
            let method = header.quantMethod ?? "quantized"
            if let bits = header.quantBits { return "\(method) · \(bits)-bit" }
            return method
        }
        return activeModel?.quantization ?? "none"
    }

    private var contextDescription: String {
        if let advisory = dna?.header.advisoryLoadMutable,
           let value = advisory["max_position_embeddings"] ?? advisory["n_positions"] {
            return value.formatted(.number)
        }
        return activeModel?.contextLength?.formatted(.number) ?? "—"
    }

    // MARK: - Token DNA panel

    var dnaRows: [Row] {
        guard let dna else { return [] }
        let manifest = dna.manifest
        return [
            Row("schema", "\(manifest.dnaSchemaMajor).\(manifest.dnaSchemaMinor)"),
            Row("compiler", manifest.compilerVersion),
            Row("content hash", String(manifest.contentHash.prefix(16))),
            Row("core", "\(dna.header.coreBytesPerToken ?? 6) bytes / token"),
            Row("tokens classified", dna.tokensClassified.formatted(.number)),
            Row("artifact size", ByteFormat.string(dna.artifactBytes)),
            Row("policy view", dna.priorViewID ?? "none",
                caveat: dna.priorViewID == nil ? dna.priorViewAbsenceReason : nil),
            Row("artifact matches model", driftLabel, caveat: driftCaveat),
            Row("load time", loadMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—"),
        ]
    }

    /// Fields the compiler emitted, with their declared shape.
    var emittedFields: [Row] {
        guard let dna else { return [] }
        return dna.manifest.fields
            .sorted { $0.key < $1.key }
            .map { name, spec in
                Row(name, "\(spec.dtype) · \(spec.length.formatted(.number)) · \(spec.tier)")
            }
    }

    /// Fields that are **absent with a recorded reason**. This is the three-state
    /// contract made visible: present / null-with-reason / not-requested. A
    /// consumer that read null as 0.0 is the failure this forecloses.
    var nullFields: [Row] {
        guard let dna else { return [] }
        return dna.manifest.fieldsNull
            .sorted { $0.key < $1.key }
            .map { Row($0.key, $0.value) }
    }

    /// Whether the loaded artifact provably belongs to the active model.
    ///
    /// Surfaced because the documented workflow is hand-copying a `.spectre-dna`
    /// directory, so pairing the wrong two is an ordinary accident. Without this
    /// row a mismatched artifact renders as a healthy panel describing a
    /// different model.
    var driftLabel: String {
        switch dna?.tokenizerDrift {
        case .matches: "yes"
        case .mismatch: "NO — WRONG MODEL"
        case .notCheckable: "unverified"
        case nil: "—"
        }
    }

    var driftCaveat: String? {
        switch dna?.tokenizerDrift {
        case .matches(let file): "tokenizer fingerprint matches \(file)"
        case .mismatch(let recorded, let found):
            "this artifact was compiled from a different tokenizer (recorded "
            + "\(recorded.prefix(12))…, found \(found)). The values below describe "
            + "another model."
        case .notCheckable(let why): why
        case nil: nil
        }
    }

    /// True when the panel is showing another model's genotype.
    var isDrifted: Bool { dna?.tokenizerDrift.isMismatch ?? false }

    /// Non-empty buckets only — a zero bar carries no information.
    var flagDistribution: [SpectreDNA.Bucket] {
        (dna?.flagCounts() ?? []).filter { $0.count > 0 }
    }

    var specialKindDistribution: [SpectreDNA.Bucket] {
        dna?.specialKindCounts() ?? []
    }

    /// Denominator for the distribution bars.
    var tokensClassified: Int { dna?.tokensClassified ?? 0 }

    // MARK: - Modules

    var requestedModules: Set<String> { settings.spectreModules }

    var resolution: SpectreLabRegistry.Resolution {
        guard settings.spectreEnabled else {
            return .init(effective: [], notes: ["Spectre is off: all modules disabled"])
        }
        return SpectreLabRegistry.resolve(settings.spectreModules)
    }

    func isEffective(_ id: String) -> Bool { resolution.effective.contains(id) }

    func isRequested(_ id: String) -> Bool { settings.spectreModules.contains(id) }

    func setRequested(_ id: String, _ on: Bool) {
        guard let module = SpectreLabRegistry.module(id), module.isAvailable else { return }
        var next = settings.spectreModules
        if on { next.insert(id) } else { next.remove(id) }
        settings.spectreModules = next
    }

    /// Whether a module's switch can be operated at all.
    func isOperable(_ module: SpectreLabModule) -> Bool {
        settings.spectreEnabled && module.isAvailable
    }

    // MARK: - Research questions

    struct QuestionState: Identifiable {
        let question: SpectreLabModule.OpenQuestion
        let instruments: [SpectreLabModule]
        let anyBuilt: Bool
        var id: String { question.rawValue }
    }

    /// The honest research readout: which of canon's four questions this build can
    /// even ask. Two of them currently have no built instrument, and the panel
    /// shows that rather than hiding it behind a list of switches.
    var questionStates: [QuestionState] {
        SpectreLabModule.OpenQuestion.allCases.map { question in
            let found = SpectreLabRegistry.instruments(for: question)
            return QuestionState(question: question,
                                 instruments: found.modules,
                                 anyBuilt: found.anyBuilt)
        }
    }

    /// Standing disclaimers. These are not decoration — they are the difference
    /// between an instrument and a marketing panel.
    let disclaimers: [String] = [
        "Module status describes implementation, never benefit.",
        "No efficacy verdict has run on real weights: every module reads "
        + "'unmeasured' or 'mechanics only'.",
        "A smaller KV cache is not a throughput claim.",
        "Only Token DNA is read on device. No Spectre mechanism runs inside the "
        + "Swift engine yet, so the other switches record intent and drive nothing.",
    ]
}
