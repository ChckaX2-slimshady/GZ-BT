# CLAUDE.md — Standing Orders for This Codebase
Drop this file at the root of every repo (and optionally merge into `~/.claude/CLAUDE.md`).
These rules exist because each one was violated at least once. They are not hypothetical.

## Role boundaries

- **TyPod** owns architecture and direction. All fork-in-the-road decisions are his.
- **You (Claude Code)** own implementation within ratified decisions.
- **The chat session / SSOT document** adjudicates factual conflicts only. If a factual
  question can be settled by evidence (run the code, read the file, check the commit),
  settle it with evidence. If it's a matter of direction or taste, stop and ask.

## Gotchas — documented failure modes, with receipts

1. **No silent substrate swaps.** llama.cpp was once dropped for a Python `mlx_lm`
   substrate without a decision being made. Changing the inference substrate, language,
   framework, or dependency tier is an *architectural decision*, never a convenience.
   If the ratified substrate is hard to work with, say so and stop — do not route around it.

2. **No posture inversion.** Spectre is a seam *inside* a host engine (engine-neutral
   contract, per-engine bindings). It once drifted into a standalone server. If your
   implementation is growing an HTTP server, a CLI entrypoint, or a process boundary
   that the spec doesn't call for, you are drifting. Halt and flag.

3. **No invented APIs.** A previous port fabricated MLX Swift types that don't exist.
   Before referencing any symbol from MLX Swift, llama.cpp bindings, or any external
   package: verify it exists in the actual package source or docs *in this session*.
   Plausible-from-training is not verified.

4. **Swift concurrency correctness.** `actor` + `ObservableObject` on the same type is
   invalid and has shipped before. Respect access control — no loosening `private`/
   `internal` to make something compile. If isolation is fighting you, the design needs
   a decision, not a workaround.

5. **No fake green.** Never stub a return value to make a test pass, never claim a build
   succeeded without running it, never mark a task complete that partially failed.
   A red result honestly reported is a good result.

6. **Ambiguity protocol.** When intent is unclear, append a numbered question to
   `QUESTIONS.md` (create it if absent) with context and your best-guess options, then
   continue with unambiguous work. Never block silently; never resolve ambiguity by
   inferring what TyPod "probably meant."

7. **Scope discipline.** One task per session. Diff-sized changes. If you notice adjacent
   problems, list them at the end of your report — do not fix them opportunistically.
   "While I was in there" is how canonical codebases fragment.

8. **Report format.** End every session with: what changed (file list), what was verified
   (commands actually run + real output), what's red, and open questions. In that order.

9. **Never re-derive the portfolio.** A canonical map lineage already exists:
   Brobot Stack Map v0.1 (June 3) → v0.6 (June 4) → the June 20 cluster map with
   per-project status and next-actions. Consolidation work *amends the canon* —
   producing a fresh competing map is itself the documented failure loop.

## Ratified target — PHOENIX EDITION (2026-07-19)

- **Vessel:** GZ-BT Phoenix — a fresh, clean-room Swift/SwiftUI codebase for iOS + macOS
  in the new `GZ-BT` repo. **FEATURE_SCOPE.md in this repo root is the scope of record**
  and outranks any session's opinion, including this one's.
- **Predecessor:** Brobot is archived (`brobot-archive` + external zip) — reference-only.
  Grep it for wiring knowledge (llama.cpp / MLX integration); never resurrect it wholesale.
- **Surfaces:** per FEATURE_SCOPE, plus **RSAI** and **OSINTINEL** as stub tabs, and the
  **Spectre tab** (metrics + benchmarks) behind a **global toggle, default OFF** — Spectre
  incorporates at will and never blocks the app.
- **HATS** is the persona system (Souls concept, renamed). No TavernAI card import/export.
- **Ratified out:** Novel Writer · Tavern cards · AI Keyboard.
- **Stone #1** substrate arrives via an MCP server entry over Tailscale, post-v1.

## State (updated each session — keep to one block)

- **Session 1** — shell, DesignSystem, MLX chat vertical slice, Seam-1. Merged `d3cc119`,
  tagged `v0.1.0-phoenix-s1`.
- **Session 2** — persistence & session model. Chat survives restart on system SQLite3;
  every assistant message carries a persisted `message_telemetry` row. Gate items done:
  **G1** iPhone deploy (225 ms TTFT, 76.3 tok/s on an iPhone 15 Pro Max), **G2** CI drift
  guard, **G3** S1 tagged. Tag `v0.2.0-phoenix-s2`.
- **Session 2.5** — Spectre view as seam falsification test. `TelemetryHub` (Services) is the
  single Seam-1 consumer and fans out to Chat + Spectre; the live dashboard renders with
  **no new `TelemetryEvent` case** — `Sources/Inference/` byte-identical to the S2 tag.
  Seam-1 has now survived both halves of its falsification test (DECISIONS #23, #28).
  Tag `v0.2.5-phoenix-s2.5`.
- **S3 recon** — read-only; `Sources/` byte-identical to the S2.5 tag, `S3_RECON.md` the only
  addition. Ground truth for the downloader: the substrate calls **`HubApi`
  (swift-transformers), not swift-huggingface directly**, and only `HubApi` verifies SHA256 —
  swift-huggingface's `computeFileHash` has no callers. **`useBackgroundSession: true` aborts
  the process** (uncatchable `NSGenericException`, SIGABRT — verified by running it, not by
  reading it); foreground works. `HubApi` materialises two levels below what
  `ModelManager.scan()` sees, and its `progressHandler` is not `@Sendable` so it will not
  compile from `@MainActor` code under strict concurrency. Seam-1 holds up for a remote engine;
  `InferenceEngine.load` and `GenerationSummary` do not. **All 14 decisions ratified by TyPod
  2026-07-31 — see `BUILD_SESSION_3.md` §1**, which carries 8 into S3 and defers the rest with
  destinations (S3.25 · S3.5 · S3.75). Tag `v0.2.6-phoenix-s3-recon`.
- **Session 3** — model download & management. A fresh device can now get a model without a
  developer attached (the hole DECISIONS #26 opened deliberately). `ModelDownloader`
  (`@MainActor` façade) + `ModelDownloadEngine` (actor owning `HubApi`) — the
  `ConversationStore`/`ConversationDatabase` pair, not `TelemetryHub`, because the problem is
  passing a non-`Sendable` handler *into* a non-isolated API. Preflight is metadata-only, so
  free-space and collision refusals happen before any byte moves. Manifest `.gzbt-model.json`
  written last; presence = complete. **`Sources/Inference/` byte-identical to the S2.5 tag**
  through an entire new subsystem. **All 13 exit criteria met**, including E10: tyFone fetched
  `Llama-3.2-1B-Instruct-4bit` itself (117.1 ms TTFT, 32.2 tok/s) with no developer attached —
  the DECISIONS #26 hole is closed. Tag `v0.3.0-phoenix-s3`.
- **Open threads:** **resume is per-file, not per-byte** (DECISIONS #45) — completed files are
  reused across an interruption (968 MB retained, 6.5 s retry) but a partially-transferred file
  restarts from zero (114 MB discarded, 77 s retry), so on foreground-only iOS backgrounding
  during the 473 MB weight file loses that file · **one model costs ~1.4 GB across three
  locations** (store + retained HF cache + CFNetwork temp staging, DECISIONS #47), and the model
  store is **in iOS backup** — store policy and TyPod's call, QUESTIONS **Q6** (narrowed: the
  temp third of that 1.4 GB is `tmp/`, which is not backed up) · **the free-space preflight
  budgets 2× but the real peak is 3×** (DECISIONS #51), so a download can pass preflight and
  still exhaust the volume — one-line fix, deliberately not made in S3 because it changes which
  downloads are accepted and would need E5 + E1 re-run ·
  background download is **not available as shipped**, but §4.6 is now answered **YES**
  (DECISIONS #44): `HubApi` resolves URLs and hashes without downloading, so a background
  transfer later is a scoped ~200-line item, not an open question · `getFileMetadata` ignores
  `revision` when listing files, a trap if a session ever pins one, QUESTIONS **Q5** · GRDB
  re-evaluated at S6 when FTS5 lands (DECISIONS #21) · Spectre internals (benchmarks, history)
  still unscoped; ARCHITECTURE.md's macOS perf row now carries its honest caveat but the real
  reconciliation is S3.75's first output · S3.25 (Seam-1 amendment) and S3.5 (one remote
  provider) are unstarted.
