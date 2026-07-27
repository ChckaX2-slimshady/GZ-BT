# BUILD_SESSION_2.md — Persistence & Session Model

**Repo:** ChckaX2-slimshady/GZ-BT
**Inherits:** Session 1, merged to `main` at `d3cc119`
**Branch:** `session-2-persistence`
**Tag on merge:** `v0.2.0-phoenix-s2`
**Spec version:** 2.0 — revised against ARCHITECTURE.md 1.0, DECISIONS.md, FEATURE_SCOPE.md v1.0

---

## 0. Read first

CLAUDE.md's session protocol governs. Verify inherited state before trusting
any document:

```bash
git log --oneline -5          # expect d3cc119 at or near HEAD
git status                    # expect clean
xcodegen generate && git status --short   # see §1.A before interpreting
xcodebuild -scheme GZ-BT -destination 'platform=macOS' \
  -skipPackagePluginValidation build
xcodebuild test -scheme GZ-BT-Tests -destination 'platform=macOS' \
  -skipPackagePluginValidation
```

A broken inherited state is a finding, not an obstacle. Report it; do not
work around it.

---

## 1. Blockers — require TyPod adjudication before code

Per CLAUDE.md role boundaries, these are direction, not implementation. Do
not resolve them by inference. If TyPod has not answered when this session
starts, log them in `QUESTIONS.md` and begin with §2 gate items, which
depend on neither.

### 1.A — Canon conflict: is `GZ-BT.xcodeproj` committed or ignored?

> **ARCHITECTURE.md, "Build / run":** `xcodegen generate` → `GZ-BT.xcodeproj`
> *(git-ignored)*
>
> **DECISIONS.md #9 (ratified TyPod 2026-07-25):** the generated
> `GZ-BT.xcodeproj` **is committed**, and is regenerated and re-committed at
> each checkpoint, so a fresh clone builds with zero external tooling.

Mutually exclusive, and both auto-load. Likely resolution: DECISIONS #9 is
later and carries an explicit ratification stamp, so the ARCHITECTURE line
is stale — but TyPod adjudicates.

The answer determines the shape of gate item G2. Once settled, **fix the
losing document in the same commit** so the conflict cannot recur.

### 1.B — Storage engine: touches a ratified decision

> **DECISIONS.md #8:** No third-party packages beyond the MLX substrate +
> its transitive deps.
>
> **CLAUDE.md Gotcha #1:** Changing the dependency tier is an architectural
> decision, never a convenience.

Persistence needs a storage layer. Three routes, all with real costs:

| Option | New packages | Cost | Case for |
|---|---|---|---|
| **(a) System SQLite3** + thin internal wrapper | none | ~250–400 LOC of boilerplate; hand-rolled migration runner | Honors #8 untouched. Full SQL control. CLI-inspectable. Matches the sovereignty ethos — no one else's abstraction over your own data. |
| **(b) GRDB.swift** | one direct | Breaks #8. Requires explicit ratification. | Explicit migrations, FTS5 ready for S6, type-safe queries, materially less code. |
| **(c) SwiftData** | none (system framework) | Opaque store — breaks the CLI exit criteria in §6. Apple abstraction owning local data. | Zero packages, native to iOS 26 / macOS 26. |

**Recommended default: (a).** The only option that touches no ratified
decision. The boilerplate is real but bounded and written once. GRDB's case
gets materially stronger at S6, when FTS5 and knowledge-graph queries
arrive — at which point it can be ratified against evidence rather than
anticipation. Choosing (a) now does not foreclose (b); the wrapper is the
migration boundary.

**(c) is not recommended** regardless: §6 requires asserting row contents
from the `sqlite3` CLI, and SwiftData's store is not a schema you own.

Everything below is engine-agnostic across (a) and (b). If (c) is chosen,
§6 needs rewriting and this spec should be reissued.

---

## 2. Gate items

Pre-existing debts — cheap now, expensive after six features land on them.
Per CLAUDE.md Gotcha #7 (one task per session), **G2 is a separate task**:
either its own short session or explicitly ratified as bundled. G1 and G3
are verification, measured in minutes.

| # | Item | Done when |
|---|------|-----------|
| G1 | **iPhone device deploy** | App installed on a real iPhone 15 Pro Max, MLX inference runs, TTFT and tok/s captured and recorded in ARCHITECTURE.md. Free provisioning (7-day) suffices. |
| G2 | **CI drift guard** | GitHub Actions: `xcodegen generate` → drift check per §1.A → macOS build → iOS-simulator build → `GZ-BT-Tests`. Green on `main`. |
| G3 | **Tag S1** | `v0.1.0-phoenix-s1` on `d3cc119`, pushed. |

**G1 rationale.** DECISIONS.md is honest that MLX cannot run in the iOS
Simulator and that inference "would run on a real iPhone." *Would* is an
unverified claim by this project's own standard. Device numbers will differ
from the M1 Air's ~68 tok/s / ~0.23 s TTFT, and they constrain model
selection for every later session — most sharply S7, where FEATURE_SCOPE
already ratifies sequential local council rounds on 8 GB.

**G2 rationale.** `project.yml` is authoritative and (pending §1.A) the
`.xcodeproj` is committed. Those desync silently. This is the cheapest real
verification loop in the repo, and the mechanism that keeps §1.A from
recurring.

---

## 3. Goal

Chat survives app restart. Every assistant message carries persisted
telemetry.

The second clause is not optional. Spectre will want telemetry history, and
retrofitting it after real conversations exist means migrating live data. It
costs nothing now.

---

## 4. Scope

### 4.1 Layer placement — dictated by ARCHITECTURE.md, not chosen

The layer table forbids ViewModels scanning the filesystem, and Services
already owns `ModelManager` and `AppSettings`. Therefore:

- **`Services/ConversationStore`** — owns the database. Sole filesystem
  toucher for chat data, mirroring `ModelManager`'s role for models.
- **`AppEnvironment`** builds it and injects via `@Environment`, exactly as
  it already does for `AppSettings`, `ModelManager`, the engine, and
  `ChatViewModel`.
- **`ChatViewModel`** talks to the store. It never sees SQL.
- **`Models/`** gains persistence record types if the domain types
  (`ChatMessage`) don't map cleanly. Prefer separate record types over
  contorting the domain model.

**Hard rule:** the store must not appear anywhere in `Inference/`. See §5.

### 4.2 Schema

Structure is the spec; names should match repo conventions where they
conflict.

```sql
CREATE TABLE conversations (
  id          TEXT PRIMARY KEY,      -- UUID string
  title       TEXT NOT NULL,
  created_at  REAL NOT NULL,         -- unix epoch seconds
  updated_at  REAL NOT NULL,
  model_id    TEXT,                  -- last model used
  persona_id  TEXT,                  -- forward slot for HATS (S4)
  archived    INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE messages (
  id              TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL
                  REFERENCES conversations(id) ON DELETE CASCADE,
  role            TEXT NOT NULL,     -- user|assistant|system|tool
  content         TEXT NOT NULL,
  created_at      REAL NOT NULL,
  sequence        INTEGER NOT NULL,  -- monotonic within conversation
  status          TEXT NOT NULL      -- complete|streaming|failed|cancelled
);

CREATE TABLE message_telemetry (
  message_id       TEXT PRIMARY KEY
                   REFERENCES messages(id) ON DELETE CASCADE,
  model_id         TEXT NOT NULL,
  engine           TEXT NOT NULL,    -- mlx|llamacpp|remote:<provider>
  ttft_ms          REAL,             -- from .firstToken(ttft:)
  tokens_per_sec   REAL,             -- from .throughput
  context_used     INTEGER,          -- from .context(used:)
  context_capacity INTEGER,          -- from .context(capacity:)
  prompt_tokens    INTEGER,          -- SEE §4.4 — expected NULL
  tokens_out       INTEGER,          -- SEE §4.4 — expected NULL
  finish_reason    TEXT,             -- SEE §4.4 — expected NULL
  schema_version   INTEGER NOT NULL,
  extra            TEXT              -- JSON, engine-specific fields
);

CREATE INDEX idx_messages_conv_seq
  ON messages(conversation_id, sequence);
CREATE INDEX idx_conversations_updated
  ON conversations(updated_at DESC);
```

`schema_version` + `extra` is a **database-layer** envelope so later
telemetry fields land without a schema migration. It is not, and must not be
presented as, part of the Seam-1 contract — Seam-1 is an enum with fixed
cases. Do not remove the envelope as redundant; it is the whole point.

Enable `PRAGMA foreign_keys = ON` explicitly and assert it — off by default
in raw SQLite3.

### 4.3 Telemetry accumulation — Seam-1 is an enum, not a struct

Per ARCHITECTURE.md, `InferenceEngine.telemetry` is
`AsyncStream<TelemetryEvent>` with cases `.lifecycle`, `.firstToken(ttft:)`,
`.throughput`, `.context(used:capacity:)`, `.completed`.

Persisting one row therefore means **accumulating a stream**, not mapping a
value. Implement a small accumulator that collects events for the in-flight
message and materializes one `message_telemetry` row on `.completed`.

Session 1's only consumer is `ChatMetricsBar`. Read it first — it already
does live accumulation for display, and the store should mirror its
event handling rather than invent a second interpretation of the same
stream.

Two consumers on one `AsyncStream` will contend. Resolve deliberately —
either a broadcast wrapper or a single accumulator both the metrics bar and
the store read from. **Do not** change `InferenceEngine` to vend a second
stream; that is a seam amendment and it is TyPod's call.

### 4.4 Predicted falsification findings — record, do not fix

Reading Seam-1's cases against §4.2, three columns look unfillable:

- **`prompt_tokens`** — `.context(used:capacity:)` documents *used =
  prompt + generated*. No split is emitted.
- **`tokens_out`** — not present as a case; derivable from `.throughput` ×
  elapsed only approximately.
- **`finish_reason`** — no case carries it. `.completed` vs failure
  distinguishes success from error but not *why* generation stopped.

If confirmed: leave the columns, write NULL, record the gap in DECISIONS.md
as a **seam-amendment candidate for TyPod**. Do not amend Seam-1 in this
session.

This is the S2.5 falsification test arriving early and for free. A confirmed
gap is a successful outcome, not a defect.

### 4.5 Streaming write policy

Both obvious implementations are wrong, so this is specified.

1. User sends → insert user message row, `status='complete'`.
2. Insert assistant row, `content=''`, `status='streaming'`.
3. Stream tokens into an **in-memory** buffer. Do **not** write per token.
4. On completion → one transaction: `UPDATE` final content and
   `status='complete'`, `INSERT` the accumulated `message_telemetry` row.
5. On error or cancel → `status='failed'` / `'cancelled'`, content set to
   whatever was buffered.
6. **On launch**, sweep: any row still `status='streaming'` is a crash
   artifact. Mark `'failed'`.

Step 6 is what makes crash recovery real rather than theoretical.

### 4.6 Database location

`~/Library/Application Support/GZ-BT/gzbt.sqlite` on macOS — **beside
`Models/`**, per DECISIONS #18 — and the sandbox equivalent on iOS. Resolve
via `FileManager.default.url(for: .applicationSupportDirectory, …)`. Create
the directory if absent. Log the resolved absolute path at launch at debug
level; §6 requires running `sqlite3` against it.

Note DECISIONS #19: macOS is non-sandboxed for dev, confirmed by the absence
of an entitlements file in the project. If that changes, this path changes.

### 4.7 UI

Minimum to prove persistence. Not a redesign.

- Conversation list: title, relative timestamp, message count. Tap to open.
- New conversation. Delete conversation, with confirm.
- Chat view loads history on open and appends live.
- Auto-title from the first ~6 words of the first user message. No LLM call
  for titling this session.

All visual values from DesignSystem tokens. No hardcoded colors, spacing, or
radii — the layer table forbids it and Session 1 established the ramp.

---

## 5. Architectural guardrail

**Persistence must not enter `Inference/`.**

The engine emits on Seam-1. `ConversationStore` consumes and persists. The
engine gains no knowledge of storage, tables, or conversations. If a change
requires importing a storage type into an `Inference/` file, the design is
wrong — stop and report.

Seam-1 is engine-neutral by contract. A persistence dependency inside it
silently voids that, and voids the reason Spectre can subscribe later.

---

## 6. Exit criteria

Each requires **pasted evidence** — real terminal output, not prose. Per
CLAUDE.md Gotcha #5, a red result honestly reported is a good result.

| # | Criterion | Evidence |
|---|---|---|
| E1 | Restart survival | Send a message, get a reply, force-quit, relaunch. Conversation and both messages render in correct order. |
| E2 | Rows exist | `sqlite3 <path> "SELECT COUNT(*) FROM messages;"` matches the UI. |
| E3 | Telemetry populated | `sqlite3 <path> "SELECT ttft_ms, tokens_per_sec, context_used, context_capacity FROM message_telemetry;"` — all four non-null per assistant message. |
| E4 | §4.4 resolved | The three suspect columns are either populated or confirmed NULL with the gap recorded in DECISIONS.md. Either outcome passes; silence fails. |
| E5 | Crash recovery | Kill mid-stream, relaunch. Message shows failed, no phantom empty bubble. `SELECT COUNT(*) FROM messages WHERE status='streaming';` returns 0. |
| E6 | Migration idempotent | Launch twice on a populated DB. No error, no duplicate schema. |
| E7 | Cascade | Delete a conversation. Orphan count in `messages` and `message_telemetry` is 0. |
| E8 | Unit tests | New tests for the store and the telemetry accumulator. `xcodebuild test -scheme GZ-BT-Tests -destination 'platform=macOS' -skipPackagePluginValidation` green. |
| E9 | Both platforms | macOS build + run. iOS build + run **on device**, per G1. |
| E10 | Seam intact | Storage symbols absent from `Sources/Inference/`. Grep output pasted. |
| E11 | No drift | Per §1.A resolution. |

---

## 7. Non-goals

Adding any of these fails the session.

- FTS / search. Deferred to S6 — migrations are cheap and explicit either
  way, so pre-building buys nothing.
- Export / import. Conversation branching. Editing past messages.
- iCloud or any sync. Explicitly deferred in DECISIONS.
- Any Spectre internals. Telemetry is *persisted*, not *analyzed*.
- Any Seam-1 amendment. §4.4 findings are recorded, not acted on.
- Promoting any placeholder tab.
- Theme picker. Explicitly out of scope in DECISIONS.
- Multi-model-per-conversation switching.

---

## 8. Gotchas

- **XcodeGen + SPM** — dependencies go in `project.yml`, never through the
  Xcode UI. UI-added dependencies vanish on next `xcodegen generate`.
- **`PRAGMA foreign_keys = ON`** — off by default in raw SQLite3. GRDB
  enables it; verify either way, because E7 depends on it.
- **One store owner, built in `AppEnvironment`** — never in SwiftUI
  `@State`, which gets recreated and yields multiple connections.
- **Actor isolation** — the telemetry stream is consumed off the main actor;
  ViewModels are `@MainActor @Observable`. DB writes must not block token
  streaming. Getting this wrong shows as a stuttering stream, not a crash.
  Per CLAUDE.md Gotcha #4, do not loosen access control to make isolation
  compile.
- **`AsyncStream` has one consumer** — see §4.3. `ChatMetricsBar` holds it.
- **REAL timestamps, not TEXT** — cheap range queries, locale-proof.
- **`sequence`, not `created_at`, for ordering** — two messages can share a
  sub-millisecond timestamp.
- **Simulator ≠ device for E9** — MLX has no Metal GPU in the simulator.
  Recorded fact in DECISIONS, not a bug to fix.
- **No invented APIs** (Gotcha #3) — verify any storage symbol against the
  actual package or system headers in-session.

---

## 9. Definition of done

Merged to `main`, fast-forward, tagged `v0.2.0-phoenix-s2`.

Report per CLAUDE.md Gotcha #8, in order: what changed (file list) · what was
verified (commands actually run + real output) · what's red · open questions.

Docs updated in the same merge:

- **ARCHITECTURE.md** — persistence layer, store placement, device telemetry
  from G1, and the §1.A correction if ARCHITECTURE is the losing document.
- **DECISIONS.md** — storage engine ratification from §1.B, streaming write
  policy, §4.4 seam-amendment candidates, §1.A adjudication.
- **CLAUDE.md** — state line under "Ratified target"; open-threads list.
- **QUESTIONS.md** — anything unresolved, numbered, with best-guess options.

A partial S2 that merges beats a complete S2 that doesn't. Cut UI polish
first. Never cut exit criteria.

---

## 10. Next

**S2.5 — Spectre view as seam falsification test.** Half session. Live
dashboard bound to `InferenceEngine.telemetry`, zero Spectre internals. Exit
criterion: the dashboard renders live without adding a case to
`TelemetryEvent`. If a case must be added, that is the finding — it goes to
TyPod as an amendment, not into the code.

§4.4 will likely have pre-answered much of this. If S2 confirms all three
gaps, S2.5 may collapse into a seam-amendment decision plus a small view,
and the ladder shortens.
