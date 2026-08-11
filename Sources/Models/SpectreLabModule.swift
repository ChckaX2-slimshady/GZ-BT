import Foundation

/// The experimental module registry — GZ-BT's mirror of `spectre/lab/modules.py`.
///
/// Three rules govern every entry, and they are the point of the type:
///
///  1. `status` describes **implementation**, never benefit. A module is `.built`
///     when the code exists and runs; that says nothing about whether it helps.
///  2. `efficacy` is a separate axis and is `.unmeasured` or `.mechanicsOnly` for
///     every module here, because no efficacy verdict has run on real weights.
///  3. `answers` names the canonical open question the module exists to settle.
///     Those questions are not this file's invention — they are the four research
///     priorities in the Spectre design contract, which closes "no mechanism
///     should become canonical before these questions are answered."
///
/// A control **must not** be offered for a mechanism that is not built. The
/// resolver refuses such a request and returns the reason, which the panel shows
/// instead of a switch that silently does nothing.
struct SpectreLabModule: Identifiable, Sendable, Equatable {

    /// Implementation state. Never a claim about benefit.
    enum Status: String, Sendable, CaseIterable {
        case built, partial, hook, unavailable

        var label: String {
            switch self {
            case .built: "Built"
            case .partial: "Partial"
            case .hook: "Hook"
            case .unavailable: "Unavailable"
            }
        }

        /// Can a user actually turn this on and have something happen?
        var isAvailable: Bool { self == .built || self == .partial }
    }

    /// Whether a verdict has run. `unmeasured` and `mechanicsOnly` are **not**
    /// claims of improvement.
    enum Efficacy: String, Sendable {
        case unmeasured
        case mechanicsOnly
        case measuredPositive
        case measuredNeutral
        case measuredNegative

        var label: String {
            switch self {
            case .unmeasured: "unmeasured"
            case .mechanicsOnly: "mechanics only"
            case .measuredPositive: "measured: positive"
            case .measuredNeutral: "measured: neutral"
            case .measuredNegative: "measured: negative"
            }
        }
    }

    /// The four research priorities from the Spectre design contract §9.
    enum OpenQuestion: String, Sendable, CaseIterable, Identifiable {
        case signalQuality, transfer, integration, throughput

        var id: String { rawValue }

        var title: String {
            switch self {
            case .signalQuality: "Signal quality"
            case .transfer: "Transfer"
            case .integration: "Integration"
            case .throughput: "Throughput"
            }
        }

        var question: String {
            switch self {
            case .signalQuality:
                "Does multi-source evidence outperform residual norm alone?"
            case .transfer:
                "Do residual-space clusters survive projection into Q/K space?"
            case .integration:
                "Does accumulated graph evidence outperform raw importance downstream?"
            case .throughput:
                "Can any routing mechanism show measurable tok/s gain without unacceptable quality loss?"
            }
        }

        /// The harness that settles it.
        var gate: String {
            switch self {
            case .signalQuality: "T-signal"
            case .transfer: "T-transfer"
            case .integration: "T-H"
            case .throughput: "tok/s harness (step zero, not built)"
            }
        }
    }

    enum Category: String, Sendable, CaseIterable {
        case substrate, signal, topology, compute, memory, recall, prediction

        var label: String { rawValue.uppercased() }
    }

    let id: String
    let name: String
    let category: Category
    let status: Status
    let efficacy: Efficacy
    let summary: String
    /// Where the code is, or why there is none.
    let implementation: String
    /// Other module ids that must be on.
    let requires: Set<String>
    let defaultEnabled: Bool
    /// Canonical questions this bears on. Empty means infrastructure.
    let answers: Set<OpenQuestion>
    /// Why it answers none, when `answers` is empty.
    let infrastructureNote: String

    var isAvailable: Bool { status.isAvailable }

    init(id: String, name: String, category: Category, status: Status,
         efficacy: Efficacy, summary: String, implementation: String,
         requires: Set<String> = [], defaultEnabled: Bool = false,
         answers: Set<OpenQuestion> = [], infrastructureNote: String = "") {
        self.id = id
        self.name = name
        self.category = category
        self.status = status
        self.efficacy = efficacy
        self.summary = summary
        self.implementation = implementation
        self.requires = requires
        self.defaultEnabled = defaultEnabled
        self.answers = answers
        self.infrastructureNote = infrastructureNote
    }
}

/// The registry itself. Every status below reflects what is actually in the
/// Spectre repository — not what the roadmap intends.
enum SpectreLabRegistry {

    static let all: [SpectreLabModule] = [
        SpectreLabModule(
            id: "token_dna",
            name: "Token DNA / SIGS",
            category: .substrate,
            status: .built,
            efficacy: .unmeasured,
            summary: "Compile the model package's static informational surface into a "
                   + "6-byte-per-token artifact, loaded once and indexed thereafter.",
            implementation: "spectre/compiler + spectre/kernel; 19/19 acceptance tests. "
                          + "Read here by SpectreDNA.",
            defaultEnabled: true,
            infrastructureNote: "Substrate, not a hypothesis. It makes the four questions "
                              + "cheap to ask and answers none of them."),

        SpectreLabModule(
            id: "compiled_lexical_prior",
            name: "Compiled lexical priors",
            category: .signal,
            status: .built,
            efficacy: .unmeasured,
            summary: "Read the static per-token prior from a materialised policy view "
                   + "instead of decoding the token and re-running predicates at runtime.",
            implementation: "spectre/kernel/policy.py legacy_v1. Byte-exact against the "
                          + "legacy oracle over six tokenizer families.",
            requires: ["token_dna"],
            defaultEnabled: true,
            answers: [.signalQuality]),

        SpectreLabModule(
            id: "exact_frequency_rank",
            name: "Exact frequency-rank prior",
            category: .signal,
            status: .built,
            efficacy: .unmeasured,
            summary: "Use the compiled exact rank instead of the legacy 2·id/n term, which "
                   + "saturates the upper half of the vocabulary onto one value.",
            implementation: "spectre/kernel/policy.py rank_v1. Registered, NOT default: "
                          + "switching it is a calibration study, not a refactor.",
            requires: ["token_dna"],
            answers: [.signalQuality]),

        SpectreLabModule(
            id: "ghostdag_topology",
            name: "GHOSTDAG / token topology",
            category: .topology,
            status: .built,
            efficacy: .mechanicsOnly,
            summary: "Backward cosine-affinity DAG over the residual window; "
                   + "blue / anticone / orphan classification with adaptive k.",
            implementation: "spectre/graph.py. Unit-tested on tiny synthetic models. "
                          + "No real-weights verdict. Not wired into the Swift engine.",
            answers: [.integration]),

        SpectreLabModule(
            id: "adaptive_k",
            name: "Adaptive-k graph guardrail",
            category: .topology,
            status: .built,
            efficacy: .mechanicsOnly,
            summary: "Solve k from the observed graph so tiers stay selective. A graph "
                   + "QUALITY guardrail, not the semantic definition of the graph.",
            implementation: "spectre/graph.py solve_k_for_blue. Not wired into the Swift engine.",
            requires: ["ghostdag_topology"],
            answers: [.integration]),

        SpectreLabModule(
            id: "attention_routing",
            name: "Attention routing (logit bias)",
            category: .compute,
            status: .partial,
            efficacy: .unmeasured,
            summary: "Bias attention logits by class pre-softmax. Normalisation-immune "
                   + "by construction, unlike residual scaling.",
            implementation: "spectre/steering.py patches the attention mask. It INFLUENCES "
                          + "the distribution of compute; it does not yet REDUCE compute, "
                          + "and no tok/s effect has been measured.",
            requires: ["ghostdag_topology"],
            answers: [.throughput]),

        SpectreLabModule(
            id: "kv_clustering",
            name: "KV clustering / query routing",
            category: .compute,
            status: .hook,
            efficacy: .unmeasured,
            summary: "Select a sparse support set of keys per query rather than attending densely.",
            implementation: "NOT BUILT. The hook is the existing mask patch, which can already "
                          + "mask keys; no clustering or per-query selection exists.",
            requires: ["ghostdag_topology"],
            answers: [.transfer, .throughput]),

        SpectreLabModule(
            id: "kv_eviction",
            name: "KV cache organisation / eviction",
            category: .memory,
            status: .built,
            efficacy: .mechanicsOnly,
            summary: "Class- or importance-driven eviction from the live KV cache, with "
                   + "positional and special-token protection.",
            implementation: "spectre/kv_cache.py. Bit-identical to stock cache when nothing "
                          + "is dropped. Not wired into the Swift engine.",
            answers: [.signalQuality, .integration]),

        SpectreLabModule(
            id: "kv_compression",
            name: "KV warm-tier compression",
            category: .memory,
            status: .built,
            efficacy: .mechanicsOnly,
            summary: "Walsh-Hadamard rotation + scalar quantisation of evicted residuals "
                   + "into a warm tier.",
            implementation: "spectre/turboquant.py. Roundtrip cosine measured on synthetic "
                          + "residuals only. Not wired into the Swift engine.",
            requires: ["kv_eviction"],
            infrastructureNote: "Belongs to the memory objective, which the source of truth "
                              + "keeps separate from the quality objective. Its question is "
                              + "roundtrip fidelity at a compression ratio, not one of the four."),

        SpectreLabModule(
            id: "recall",
            name: "Recall (warm → live splice)",
            category: .recall,
            status: .built,
            efficacy: .mechanicsOnly,
            summary: "Bring an evicted token back into the live cache when it becomes "
                   + "important again.",
            implementation: "spectre/kv_cache.py recall(). Not wired into the Swift engine.",
            requires: ["kv_eviction"],
            infrastructureNote: "Memory objective, as above. Whether importance should drive "
                              + "it is asked through kv_eviction."),

        SpectreLabModule(
            id: "speculative_decoding",
            name: "Predictive / speculative tokens",
            category: .prediction,
            status: .unavailable,
            efficacy: .unmeasured,
            summary: "A cheap drafter proposes tokens the model verifies in parallel; "
                   + "importance could inform drafting.",
            implementation: "NOT BUILT. No drafter, no verification loop, no control path "
                          + "beyond this registration.",
            answers: [.throughput]),

        SpectreLabModule(
            id: "compute_throughput",
            name: "Importance-gated compute",
            category: .compute,
            status: .unavailable,
            efficacy: .unmeasured,
            summary: "Spend or save FLOPs by importance. The designed objective of the "
                   + "project's compute consumer.",
            implementation: "NOT BUILT. Nothing yet spends or saves FLOPs based on "
                          + "importance, and no tok/s effect has ever been measured. "
                          + "A smaller cache is not a throughput claim.",
            answers: [.throughput]),
    ]

    static func module(_ id: String) -> SpectreLabModule? {
        all.first { $0.id == id }
    }

    static var defaults: Set<String> {
        Set(all.filter(\.defaultEnabled).map(\.id))
    }

    /// A display group. A named type rather than a tuple: SwiftUI's `ForEach(_:id:)`
    /// needs a key path, and Swift key paths cannot address tuple elements.
    struct Group: Identifiable, Sendable {
        let category: SpectreLabModule.Category
        let modules: [SpectreLabModule]
        var id: String { category.rawValue }
    }

    /// Modules grouped for display, category order stable.
    static var byCategory: [Group] {
        SpectreLabModule.Category.allCases.compactMap { category in
            let members = all.filter { $0.category == category }
            return members.isEmpty ? nil : Group(category: category, modules: members)
        }
    }

    /// Which modules bear on a question, and whether any of them is actually built.
    static func instruments(for question: SpectreLabModule.OpenQuestion)
        -> (modules: [SpectreLabModule], anyBuilt: Bool) {
        let members = all.filter { $0.answers.contains(question) }
        return (members, members.contains { $0.status == .built })
    }

    /// The outcome of asking for a set of modules: what actually runs, and why
    /// anything was added or refused. Nothing is dropped silently.
    struct Resolution: Sendable, Equatable {
        var effective: Set<String>
        var notes: [String]
    }

    /// Close `requested` over dependencies and drop what cannot run.
    ///
    /// Mirrors `ModuleRegistry.resolve()` on the Python side, including its
    /// contract that every removal and every implied addition is reported.
    static func resolve(_ requested: Set<String>) -> Resolution {
        var want = requested
        var notes: [String] = []

        for id in requested.sorted() where module(id) == nil {
            want.remove(id)
            notes.append("\(id): unknown module, ignored")
        }

        // Refuse anything that is not actually built.
        for id in want.sorted() {
            guard let m = module(id) else { continue }
            if !m.isAvailable {
                want.remove(id)
                notes.append("\(id): \(m.status.rawValue) — cannot be enabled")
            }
        }

        // Dependency resolution, in two monotone phases.
        //
        // The single interleaved loop this replaces did not terminate. With A
        // requiring B, B available, and B requiring an unavailable C, it added B
        // as A's dependency, removed A because C is unavailable, then re-added B
        // because A still required it — forever, appending a note each pass. No
        // current registry reaches that shape, but `resolution` is a @MainActor
        // computed property the view body evaluates on every render, so the first
        // two-level dependency added would freeze the UI rather than merely
        // return the wrong answer.
        //
        // Splitting it fixes the oscillation by construction: phase 1 only ever
        // removes, phase 2 only ever adds, so each is bounded by the module count.

        // Phase 1 — drop anything that transitively needs something unbuilt.
        var changed = true
        while changed {
            changed = false
            for id in want.sorted() {
                guard let m = module(id) else { continue }
                for dep in m.requires.sorted() {
                    guard let depModule = module(dep) else { continue }
                    // Unbuilt, or already dropped in an earlier pass for the
                    // same reason — either way this module cannot run.
                    if !depModule.isAvailable {
                        want.remove(id)
                        notes.append("\(id): disabled — requires \(dep), which is "
                                     + depModule.status.rawValue)
                        changed = true
                        break
                    }
                }
                if changed { break }
            }
        }

        // Phase 2 — pull in the dependencies of what survived. Every dependency
        // reachable from here is available, so this only grows and terminates.
        changed = true
        while changed {
            changed = false
            for id in want.sorted() {
                guard let m = module(id) else { continue }
                for dep in m.requires.sorted() where !want.contains(dep) {
                    want.insert(dep)
                    notes.append("\(dep): enabled — required by \(id)")
                    changed = true
                    break
                }
                if changed { break }
            }
        }

        return Resolution(effective: want, notes: notes)
    }
}
