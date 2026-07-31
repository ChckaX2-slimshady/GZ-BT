# BUILD_SESSION_3.md — Model Download & Management

**Repo:** ChckaX2-slimshady/GZ-BT
**Inherits:** S2.5, merged and tagged `v0.2.5-phoenix-s2.5` at `d5be989`
**Recon:** `S3_RECON.md`, merged at `37d73ca`. **Read it before this file.**
**Branch:** `session-3-models`
**Tag on merge:** `v0.3.0-phoenix-s3`

---

## 0. Read first

CLAUDE.md's session protocol governs. `S3_RECON.md` is a verified factual
record — trust its file:line references, but re-verify any API symbol you
call, per Gotcha #3.

```bash
git log --oneline -5
git status
xcodegen generate && git diff --exit-code GZ-BT.xcodeproj
xcodebuild -scheme GZ-BT -destination 'platform=macOS' \
  -skipPackagePluginValidation build
xcodebuild test -scheme GZ-BT-Tests -destination 'platform=macOS' \
  -skipPackagePluginValidation
```

Expect 26 tests green. Anything red is a finding — report, don't route around.

---

## 1. Decisions — ratified, do not relitigate

From `S3_RECON.md`'s 14. Ratified by TyPod 2026-07-31. Record each in
DECISIONS.md as a numbered entry during this session.

| Recon # | Ratified |
|---|---|
| 1 | **`HubApi`** (swift-transformers). Not `HubClient` — its `computeFileHash` is dead code and the substrate already calls HubApi. Two HF paths in one app is a silent substrate divergence (Gotcha #1). |
| 2 | **Declare `swift-transformers` in `project.yml`** at the existing resolved pin (1.2.1). This does not violate DECISIONS #8 — it is an MLX transitive dep already in the graph; declaring makes a true thing explicit. Do **not** introduce a competing version constraint; `Package.resolved` must not change. |
| 3 | **Foreground-only.** `useBackgroundSession: true` aborts the process (recon §3.1a). See §4.6 for the one grep that decides whether background is cheap later. |
| 4 | **Download to HubApi's cache, move into the store on completion.** Not `downloadBase` retargeting, not discovery changes. |
| 5 | **Directory name = last path component of the repo id.** Verified free: the existing store dir and the only `model_id` in `message_telemetry` are both `Ternary-Bonsai-1.7B-mlx-2bit`, and `prism-ml/Ternary-Bonsai-1.7B-mlx-2bit` reduces to exactly that. **No migration needed.** Plus a manifest — see §4.3. |
| 6 | **Keep the cache.** Falls out of #4: a same-volume move is a rename, so the ~946 MB peak does not occur and resume stays available. Cross-volume (external SSD) is a real copy and does pay the doubling — record, don't solve. |
| 7 | **Manifest presence = complete.** Falls out of #4 and #5. Partial downloads never enter the store. |
| 14 | **The `TelemetryHub` pattern** — non-isolated consumer, republishes to `@MainActor`. S2.5 already solved this shape; reuse it, don't invent a second one. |

**Deferred, with destination:**

| Recon # | Goes to | Why |
|---|---|---|
| 8, 9 (credentials, Keychain) | **S3.5** | Recon §3.1a proved public repos download auth-free. S3 ships public-only; Keychain arrives when API keys actually need it. |
| 10, 11 (`GenerationSummary` optionality, load-path shape) | **S3.25** — its own half-session | A Seam-1 amendment plus a provider implementation is two things. One thing per session is why every session so far merged green. |
| 12 (benchmark harness) | **S3.75** | Must run across *engines*, not just models, to test Spectre's model-agnosticism claim. Needs S3.25 + S3.5 to exist first. |
| 13 (perf numbers) | **This session, minimally** — see §4.8 | One honest line. The real reconciliation is S3.75's first output. |

---

## 2. Goal

A fresh device can get a model without a developer attached.

Today `devicectl device copy to` is the only path. Q3 ratified "fetch, never
bundle," which means that hole is one this project opened deliberately and
now closes.

---

## 3. Scope boundary

**In:** download by repo id · progress · cancel · resume · verify · move
into store · manifest · collision handling · delete · disk accounting ·
pre-flight free-space check.

**Out — do not build, do not stub:**

- GGUF / llama.cpp. That is a second engine binding and its own session.
- Vision, audio, Whisper, TTS models.
- HuggingFace **search or browse UI**. S3 ships repo-id entry plus the
  small starter list in §4.7. Search is a follow-on.
- iCloud model sync. Import from Files.
- Remote API providers. Keychain. Any credential storage.
- Background download.
- Benchmark harness, Spectre internals of any kind.
- Any change to `Sources/Inference/`. See §5.

---

## 4. Work

### 4.1 `project.yml` — declare the dependency

Add `swift-transformers` as an explicit package at the currently resolved
revision. Regenerate, and confirm `Package.resolved` is **byte-identical**
afterward. If it changes, the declaration introduced a competing constraint
— back it out and report.

### 4.2 `Services/ModelDownloader`

New Services type. Owns `HubApi`, the download lifecycle, and the move into
the store. Services layer per ARCHITECTURE — ViewModels never touch it
directly except through `ModelsViewModel`.

Responsibilities:

1. Resolve repo id → expected file set and total byte size (HEAD preflight,
   recon §2.2).
2. Free-space check *before* starting — recon §3.2 verified the iOS vs
   macOS API difference. Refuse with a clear, specific message if
   insufficient. Include headroom; do not fill the volume.
3. Download via `HubApi.snapshot(from:revision:matching:progressHandler:)`,
   `useBackgroundSession: false`.
4. On success: verify, then move the materialized directory into
   `Application Support/GZ-BT/Models/<lastPathComponent>/`.
5. Write the manifest **last** (§4.3).
6. Trigger a `ModelManager` rescan.

**Progress crossing isolation (recon #14).** `progressHandler` is
`@escaping (Progress) -> Void`, not `@Sendable`, and `Progress` is not
`Sendable`. Under `SWIFT_STRICT_CONCURRENCY: complete` this cannot be passed
from `@MainActor` code. Use the `TelemetryHub` shape: the downloader is
non-isolated, owns the handler, and republishes a `Sendable` progress value
to `@MainActor` observers.

**Cancellation.** A 473 MB download must be cancellable. Verify HubApi's
cancellation semantics in-session — do not assume `Task` cancellation
propagates cleanly through it. If it does not cancel cleanly, that is a
finding: record it, and cancel at the highest level that does work.

### 4.3 The manifest

Written into the store directory **after** the move and verification
succeed, never before. Presence is the completeness signal (#7).

Minimum contents:

```json
{
  "schema_version": 1,
  "repo_id": "prism-ml/Ternary-Bonsai-1.7B-mlx-2bit",
  "revision": "<commit sha HubApi resolved>",
  "downloaded_at": 1753900000.0,
  "files": [{ "path": "config.json", "sha256": "…", "bytes": 2939 }],
  "total_bytes": 496000000
}
```

`repo_id` is the load-bearing field — it is what makes collisions (§4.4)
detectable and what preserves org attribution that the directory name drops.

**The existing hand-copied model has no manifest.** Do not retroactively
fabricate one — you cannot know its provenance. Discovery must treat
*manifest absent* as "legacy, assume complete" and *manifest present but
incomplete* as broken. Record this asymmetry in DECISIONS.md.

### 4.4 Collision policy

`org/name` → `name` drops the org. `alpha/Llama-3-8B` and `beta/Llama-3-8B`
both reduce to `Llama-3-8B`.

Rules:

- Target directory absent → proceed.
- Present **with** a manifest whose `repo_id` matches → same model. Offer
  re-download/replace, or skip. Do not silently overwrite.
- Present **with** a manifest whose `repo_id` differs → genuine collision.
  Refuse with both repo ids named. Do not auto-rename; a silent rename
  breaks `activeModelID` and `message_telemetry.model_id`.
- Present **without** a manifest (the legacy case) → treat as an unknown
  occupant. Refuse and say so.

### 4.5 Model management

- **Delete.** Remove the store directory. Confirm dialog naming the model
  and reclaimed bytes.
  **Do not delete telemetry rows.** `message_telemetry.model_id` is a plain
  string with no foreign key. History outlives the model deliberately —
  Spectre's comparative work depends on it. State this in DECISIONS.md so a
  later session doesn't "fix" it into a cascade.
- **Disk accounting.** Per-model size and store total in the Models tab.
- **`ModelManager.isScanning`** (recon's adjacent finding, `ModelManager.swift:15,44–45`)
  is currently unobservable because `scan()` is synchronous on the main
  actor. In scope — S3 is already in this file, and scanning after a
  download needs to be async anyway. Not opportunism (Gotcha #7); it is a
  forced consequence.

### 4.6 One grep before accepting foreground-only as permanent

`HubApi` does two separable jobs: HF resolution (repo → file list, CDN
redirect, expected SHA256, metadata sidecar) and generic HTTP transfer.

Check whether it exposes **resolved file URLs and expected hashes without
performing the download** — e.g. a metadata or file-listing call that
returns them.

- **Yes** → background transfer later is ~200 lines: keep HubApi's
  resolution, own the transfer with a delegate-based background
  `URLSession`. Record as a scoped future item.
- **No** → foreground-only stands, and background is its own session.

Record the answer in `S3_RECON.md` or DECISIONS.md. **Do not build it
either way.**

### 4.7 UI — Models tab

Extend the existing `ModelsView` / `ModelRow` / `ModelsViewModel`. No new
navigation destination.

- Repo-id text entry plus a download action.
- Per-download row: progress, bytes, cancel.
- **iOS must state the foreground constraint plainly** — "keep GZ-BT open
  during download." An interrupted transfer must read as interrupted, not
  as a network error.
- Delete affordance with confirm.
- Store total and free space.
- **Starter list (cuttable):** 3–5 hardcoded known-good MLX repo ids as
  tappable presets. ~20 lines, and it's the difference between usable and
  "type this exact string." Cut this first if the session runs long.

All values from DesignSystem tokens.

### 4.8 Docs — the minimum honest fix for #13

Do **not** hand-reconcile ARCHITECTURE.md's perf row. Replacing one
undefined number with another undefined number is not progress.

Add one line beside it:

> Session-1 informal measurement; protocol undefined (no fixed prompt,
> warmup, or repetition). Persisted values on the same machine range
> 49.7–56.1 tok/s. A defined baseline arrives with the benchmark harness.

That is honest, costs nothing, and stops the number being cited as if it
were a baseline.

---

## 5. Architectural guardrail

**`Sources/Inference/` must not change.**

S2.5's strongest evidence was `git diff --stat … -- Sources/Inference/`
returning empty. S3 adds an entire subsystem; if the seam survives that
too, engine-neutrality stops being an assertion.

If something genuinely requires a seam change, **stop**. That is S3.25's
territory and it is TyPod's call.

---

## 6. Exit criteria

Pasted evidence, not prose.

| # | Criterion | Evidence |
|---|---|---|
| E1 | Download works | Download a model by repo id on macOS. It appears in the Models list, loads, and generates. |
| E2 | Layout + manifest | `ls` the store dir and `cat` the manifest. Directory name is the last path component; manifest names the full repo id. |
| E3 | Resume | Interrupt past 50 MB, restart. Confirm resume, not restart — byte count or elapsed time as evidence. |
| E4 | Cancel | Cancel mid-download. No partial directory in the store. Cache-cleanup behavior recorded either way. |
| E5 | Free space | Attempt a download with insufficient space. Clear, specific refusal. No partial write. |
| E6 | Collision | Attempt a download whose last path component matches an existing dir. Policy from §4.4 fires. |
| E7 | Delete | Delete a model. Gone from disk and list; reclaimed bytes shown. `SELECT COUNT(*) FROM message_telemetry;` **unchanged**. |
| E8 | Progress + isolation | Progress updates live during download. Compiles under `SWIFT_STRICT_CONCURRENCY: complete` with no isolation workaround and no access-control loosening. |
| E9 | `isScanning` | Observable as `true` from the UI during a scan. |
| E10 | Device | Download completes on tyFone, model loads, generation runs. |
| E11 | Seam intact | `git diff --stat v0.2.5-phoenix-s2.5 -- Sources/Inference/` is empty. |
| E12 | No drift | `Package.resolved` byte-identical. `xcodegen generate` produces no `.xcodeproj` diff. |
| E13 | Suite green | All existing tests plus new downloader/manifest/collision tests. macOS, iOS-Simulator, and iOS-device builds green. CI green on main. |

E10 may be blocked by the 7-day provisioning profile. If expired, rebuild
and reinstall — that is not a bug. Note the expiry date in the report.

---

## 7. Gotchas

- **Never call `useBackgroundSession: true`.** Uncatchable `NSGenericException`,
  SIGABRT, no `do/catch` contains it. Recon §3.1a.
- **`HubClient` is the wrong layer.** `computeFileHash` there is dead code;
  only `HubApi` verifies SHA256 live.
- **`GZBT_STORE_PATH` does not cover models** — it overrides the
  conversation DB only (`AppEnvironment.swift:34`). Tests that touch the
  model store still hit the real one. Do not extend it in this session
  unless a test forces it; if it does, record the extension.
- **Manifest last, always.** Written early, a crash mid-move leaves a
  directory that looks complete and isn't.
- **Don't cascade telemetry on delete.** See §4.5.
- **Same-volume move is a rename; cross-volume is a copy.** The external
  SSD path pays the doubling. Record if encountered.
- **Verify HubApi symbols in-session** (Gotcha #3), even where recon cites
  file:line — recon read them, this session calls them.

---

## 8. Definition of done

Merged to `main`, fast-forward, tagged `v0.3.0-phoenix-s3`, pushed.

Report per Gotcha #8: what changed · what was verified (commands + real
output) · what's red · open questions.

Docs in the same merge:

- **DECISIONS.md** — the 8 ratified items from §1 as numbered entries; the
  manifest-absent-means-legacy asymmetry; the no-cascade rule; §4.6's answer.
- **ARCHITECTURE.md** — `ModelDownloader` in the folder map and layer table;
  the download flow; §4.8's line.
- **CLAUDE.md** — state block; open threads.
- **QUESTIONS.md** — anything genuinely ambiguous, numbered.

A partial S3 that merges beats a complete S3 that doesn't. Cut order:
starter list → disk accounting UI → `isScanning`. Never cut exit criteria.

---

## 9. Next

**S3.25** — Seam-1 amendment (recon #10, #11). Half session. Make
`GenerationSummary`'s fabricated-if-remote fields Optional, give the load
path an endpoint/credential seat. Verification is cheap: it compiles, and
the existing suite proves the MLX path is unchanged.

The argument is Spectre's, not convenience: a fabricated
`promptTokensPerSecond` is a plausible-looking false number entering the
exact data stream the optimization layer reasons over. Gotcha #5 aimed
directly at Spectre's inputs. Note the amendment *reduces* divergence —
`MessageTelemetry`'s equivalents are already Optional.

Then **S3.5** (one remote provider), then **S3.75** (benchmark harness —
must run across engines, not just models, or it cannot test
model-agnosticism at all).
