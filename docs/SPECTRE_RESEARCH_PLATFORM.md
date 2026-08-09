# Spectre Research Platform — GZ-BT integration spec

**Status:** specification. **No Swift was written for this document.**
**Audience:** the GZ-BT session that implements it, with Xcode.
**Companion:** `Spectre` repo — `docs/Phoenix_Refactor.md` (SIGS-B), `spectre/lab/`.

---

## 0 · Why this is a spec and not an implementation

This document was produced in a Linux container with **no Swift toolchain**
(`swift`, `swiftc`, `xcodebuild` all absent). Writing a SwiftUI research
dashboard here would mean shipping code that was never compiled, never run, and
that references SwiftUI/MLX symbols nobody verified — three separate violations
of this repository's standing orders (CLAUDE.md gotchas #3 and #5).

It is also the wrong order. The Surgery Spec's own Gotcha 9 says *Python-first,
then Swift; don't do first-pass surgery in Xcode, the iteration tax will bury
you.* The measurement instrument has therefore been **built and tested in
Python** (`spectre/lab/`, 30/30 self-test checks). This document specifies the
read layer over it.

**What already exists in Spectre** (built, tested, in PR):

| Piece | Where |
|---|---|
| Compiled Token DNA artifact | `spectre/compiler/` → `<model>/.spectre-dna/` |
| Kernel services over it | `spectre/kernel/` — no MLX, no tokenizer deps |
| Experimental module registry with honest status | `spectre/lab/modules.py` |
| Benchmark harness + run log | `spectre/lab/bench.py`, `records.py` |
| **The dashboard contract** | `spectre.lab.dashboard_state(model_dir)` |

---

## 1 · The integration boundary — and the good news

GZ-BT is Swift; Spectre is Python. There is no bridge, and **this spec does not
propose building one.** It does not need to:

> **The compiled Token DNA artifact is a language-neutral file.**
> Raw little-endian arrays plus JSON, deliberately chosen over `.npy` so it is
> `mmap`-able from C++ and Swift without a Python reader.

So the split is:

```
┌───────────────────────────────────────────────────────────┐
│ Spectre (Python, offline)                                 │
│   compile_model(model_dir) → <model>/.spectre-dna/        │
│   run on a Mac once per model, or shipped with the model  │
└───────────────────────┬───────────────────────────────────┘
                        │  a directory of files
┌───────────────────────▼───────────────────────────────────┐
│ GZ-BT (Swift, on device)                                  │
│   reads manifest.json + header.json + core/*.u8|u16       │
│   displays it · toggles modules · records benchmarks      │
└───────────────────────────────────────────────────────────┘
```

**GZ-BT never calls Python.** It reads a directory that sits beside the weights,
exactly like `.gzbt-model.json` already does.

### 1.1 Artifact layout GZ-BT must read

```
<model_dir>/.spectre-dna/
  manifest.json      ← written LAST; presence means complete (same rule as .gzbt-model.json)
  header.json        ← model/architecture scalars
  core/freq_rank.u16      little-endian uint16, length = manifest.fields.freq_rank.length
  core/class_flags.u8     8 packed predicates (bit layout in Phoenix_Refactor.md §5.4)
  core/surface_bytes.u8
  core/char_len.u8
  core/special_kind.u8    0 content · 1 bos · 2 eos · 3 pad · 4 unk · 5 control
                          6 reserved · 7 modality · 8 unreachable_pad_row
  core/lex_class.u8       policy resource (not part of the 6-byte core)
  views/legacy_v1.f32     one float32 per token id — the materialised prior
```

**Six bytes per token id** for the mandatory core. Qwen3 (V = 151,936) →
911,616 B. Against a 4.6 GB checkpoint that is 0.019%.

A Swift reader is `Data(contentsOf:)` + `withUnsafeBytes` + a length check
against the manifest. No parsing, no dependency.

---

## 2 · Current GZ-BT Spectre surface (read from the code, `5938d0e`)

| File | Lines | What it does today |
|---|---|---|
| `Sources/Services/AppSettings.swift` | 19 | **One** `Bool`: `spectreEnabled`, `UserDefaults`-persisted, default OFF |
| `Sources/ViewModels/SpectreViewModel.swift` | 67 | Formats `TelemetryHub` readouts. Holds no engine reference, does no analysis |
| `Sources/Views/Spectre/SpectreView.swift` | 229 | The live dashboard |
| `Sources/Services/TelemetryHub.swift` | 173 | The single Seam-1 consumer; fans out to Chat + Spectre |

`TelemetryHub` **already emits every runtime number the benchmark section needs**
— TTFT, tok/s, prompt/generated tokens, finish reason, context used/capacity,
throughput series. DECISIONS #28 established the dashboard renders with **no new
`TelemetryEvent` case**. That property must be preserved: this spec adds **no**
Seam-1 amendment.

---

## 3 · Control architecture

### 3.1 `AppSettings` gains a nested module set

`spectreEnabled` stays exactly as it is — the primary switch, default OFF,
`FEATURE_SCOPE` Tier 3's "Spectre incorporates at will and never blocks the app".

Add beneath it, and **only reachable when it is on**:

```swift
/// Independently switchable experimental mechanisms. Mirrors
/// spectre/lab/modules.py; the ids are the contract between the two repos.
struct SpectreModules: Codable, Equatable {
    var tokenDNA = true
    var compiledLexicalPrior = true
    var exactFrequencyRank = false      // rank_v1 — behavioural change, off
    var ghostdagTopology = false
    var adaptiveK = false
    var attentionRouting = false        // PARTIAL
    var kvEviction = false
    var kvCompression = false
    var recall = false
    // hook_only / unavailable — the switch exists, disabled, and says why
    var kvClustering = false            // hook_only
    var speculativeDecoding = false     // unavailable
    var computeThroughput = false       // unavailable
}
```

### 3.2 Status is rendered, never hidden

Each row carries a state badge sourced from the module registry:

| Badge | Meaning | Control |
|---|---|---|
| **Built** | code exists and executes | switch enabled |
| **Partial** | exists, incomplete for its stated purpose | switch enabled, badge visible |
| **Hook** | architectural hook only; mechanism unbuilt | **switch disabled**, reason shown |
| **Unavailable** | not built | **switch disabled**, reason shown |

And a second, separate badge for **efficacy**: `unmeasured` / `mechanics only`.
Every module in the Spectre repository is currently one of those two.

> **Normative.** A control MUST NOT be presented as enabled for a mechanism that
> is not built. The user asked for hooks and honest labels, not for switches
> that do nothing. `spectre/lab/modules.py::ModuleRegistry.resolve()` already
> refuses such a request with a reason string — surface that string.

### 3.3 Dependencies

`compiledLexicalPrior` requires `tokenDNA`; `adaptiveK` requires
`ghostdagTopology`; `kvCompression` and `recall` require `kvEviction`. Turning a
dependent on turns its dependency on, and says so. The Python registry already
computes this closure; the Swift side mirrors the same table.

---

## 4 · Dashboard panels

Every field below maps to a key in `spectre.lab.dashboard_state()`. Where GZ-BT
reads the artifact directly, the JSON path is given.

### 4.1 Model Information
| Display | Source |
|---|---|
| loaded model | `ModelManager.activeModelID` (exists) |
| architecture | `header.json` → `model_type`, `architectures` |
| tokenizer family | `header.json` → `tokenizer_kind`, `tokenizer_algorithm` |
| vocabulary size | `manifest.json` → `vocab_size` (**may be `null`** — vocabulary-free packages) |
| quantization format | `header.json` → `quant_method`, `quant_bits` |
| context length | `header.json` → `advisory_load_mutable.max_position_embeddings` — **label it advisory**: SIGS-A classifies it I4, load-mutable |
| Token DNA availability | `.spectre-dna/manifest.json` present? |

### 4.2 Token DNA / SIGS
| Display | Source |
|---|---|
| artifact exists | manifest presence |
| compilation status | `validation.json` → `ok`, `gates` |
| artifact size | sum of file sizes |
| compilation time | `compile_log.json` |
| tokens classified | `manifest.vocab_size` |
| active metadata fields | `manifest.fields` keys |
| **null fields + reason** | `manifest.fields_null` — **show the reason**, three-state contract |
| loaded policy view | `manifest.views` |
| cache status | `compile_log.json` |

### 4.3 Runtime benchmarking — baseline vs Spectre

| Measure | Source | Note |
|---|---|---|
| TTFT | `TelemetryHub.ttft` | exists |
| tokens/sec | `TelemetryHub.tokensPerSecond` | exists |
| generated tokens | `TelemetryHub.generatedTokens` | exists |
| inference latency | derive from the above | |
| context used/capacity | `TelemetryHub.contextUsed/Capacity` | exists |
| memory usage | `os_proc_available_memory` / `task_info` | new |
| KV cache usage | **not currently exposed** — see §6 | |
| tokenizer calls avoided | Spectre-side; static per model | |
| preprocessing time | compile time from `compile_log.json` | |

**The A/B is the product.** One run with `spectreEnabled = false`, one with the
chosen module set, same prompt, same model, same seed.

---

## 5 · Benchmark record

Mirror `spectre/lab/records.py::BenchmarkRun` so records from both repos are
comparable. Persist in the existing SQLite store as a new table — the
`ConversationDatabase` actor pattern already exists and this must not put SQL
above it.

Mandatory fields: `run_id`, `timestamp`, `schema_version`, `model_dir`,
`model_type`, `tokenizer_fingerprint`, `quantization`, `spectre_enabled`,
`enabled_modules[]`, measurements, `app_version`, `dna_content_hash`.

> **Two runs are comparable only when `model_dir` **and**
> `tokenizer_fingerprint` match.** `records.py::compare()` refuses otherwise and
> returns a reason. Reproduce that refusal in the UI rather than rendering a
> misleading delta. Note the fingerprint is computed from the **model
> directory**, not from the DNA header — otherwise a baseline run (no DNA) and a
> Spectre run of the same model would be judged incomparable, which is exactly
> the comparison the laboratory exists to make. That was a real bug, found and
> fixed by the Python self-test.

---

## 6 · Known gaps — stated, not designed around

1. **KV cache usage is not exposed on Seam-1.** `SpectreController.nbytes()`
   exists in Python; the Swift `MLXInferenceEngine` reports no cache size.
   Surfacing it is a **Seam-1 amendment and therefore TyPod's call** (DECISIONS
   #27). Until then the panel shows "—", not a guess.
2. **No Spectre mechanism runs inside the Swift engine.** GZ-BT's MLX path has
   no eviction, no steering, no graph. So the module switches beyond
   `tokenDNA`/`compiledLexicalPrior` have **nothing to drive on device yet** —
   they are controls for a mechanism that lives in the Python engine.
   The honest first milestone is §7 Stage 1–3: display and measure the DNA half,
   which *is* real on device because the artifact is just a file.
3. **Compilation happens off-device.** `compile_model` needs `tokenizers`
   (Python). The artifact ships with the model or is built on a Mac. GZ-BT
   **reads**; it does not compile. A future on-device compiler is a separate
   decision, not assumed here.
4. **No efficacy verdict exists for any module.** Not one. The dashboard must
   not imply otherwise.

---

## 7 · Staged plan

| Stage | Deliverable | Exit criterion |
|---|---|---|
| **1** | `SpectreDNA.swift` — read manifest/header/core, length-checked | Unit test: read a real artifact, assert `vocab_size`, 6 B/token, a known `special_kind` |
| **2** | Model Information + Token DNA panels in `SpectreView` | Artifact fields render; absent artifact renders "not compiled", not an error |
| **3** | `SpectreModules` in `AppSettings` + the submenu with status badges | Unbuilt mechanisms render disabled with a reason; dependency closure works |
| **4** | Benchmark record table + A/B runner | Two runs on one model produce a comparable delta; mismatched models refuse |
| **5** | Memory + KV instrumentation | Blocked on §6.1 — a Seam-1 amendment decision |

Stages 1–4 need **no** Seam-1 change and **no** Python on device.

---

## 8 · What this spec deliberately does not do

- **No Seam-1 amendment.** DECISIONS #28 proved the dashboard renders from the
  five existing cases; that property is preserved.
- **No new inference mechanism.** No routing, clustering, compression or
  speculative decoding is added to GZ-BT.
- **No Python bridge, no HTTP server, no process boundary.** That would be the
  posture inversion CLAUDE.md gotcha #2 forbids.
- **No claim that Spectre improves anything.** The instrument exists to find
  out.
