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
- **Open threads:** model provisioning on a fresh device (QUESTIONS Q3) · GRDB re-evaluated
  at S6 when FTS5 lands (DECISIONS #21) · **S2.5** Spectre view — mostly pre-answered, since
  §4.4's predicted seam gaps were falsified (DECISIONS #23).
