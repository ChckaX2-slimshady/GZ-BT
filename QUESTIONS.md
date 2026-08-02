# QUESTIONS.md — open items for TyPod

Numbered, with context and best-guess options, per CLAUDE.md Gotcha #6.
Answered items stay here with their resolution so the reasoning is not lost.

---

## Open

### Q5 — `HubApi.getFileMetadata` ignores `revision` when listing files. Pin, work around, or leave?
**Raised: Build Session 3 (2026-08-02). Upstream defect, not ours. Not blocking S3.**

**Context.** `getFileMetadata(from:revision:matching:)` builds its `resolve/<revision>` URL
correctly but calls `getFilenames(from: repo, matching: globs)` **without forwarding `revision`**
(`HubApi.swift:1108`), so the file *list* always comes from `main` while the per-file metadata
comes from the requested revision. `snapshot` does not share the defect — it forwards correctly
at `:941`, verified by reading both call sites this session.

**Why it does not bite S3.** S3 preflights at `revision: "main"` and then passes the *resolved
commit sha* to `snapshot`, which lists correctly. So the manifest's `revision` and the bytes on
disk agree today.

**When it would bite.** The moment a session lets the user pin a revision (a specific commit, or
`refs/pr/N`): preflight would measure `main`'s file set while downloading the pinned revision's,
and a repo that added or removed a file between the two would produce a manifest describing files
that were never fetched — a silently wrong artifact, not a crash.

**Options.** (1) Leave it; document the constraint that S3 only ever preflights `main`.
(2) Stop using `getFileMetadata(from:…)` and drive `getFileMetadata(url:)` per file ourselves —
but the endpoint needed to build those URLs (`HubApi.endpoint`) is internal, so this means
reconstructing the host, which duplicates upstream logic. (3) Upstream a fix.

**Best guess: (1) for now, revisit if revision pinning is ever scoped.** Recorded so a later
session does not discover it the hard way.

### Q6 — The model store is in iOS backup, and every download strands ~473 MB in temp. Store policy is TyPod's call.
**Raised: Build Session 3 (2026-08-02). Deliberately NOT built this session — it is policy, not implementation.**

**Context, two related facts, both measured:**

1. **Nothing in `Sources/` sets `isExcludedFromBackup`** (S3_RECON §3.3; no matches in the repo).
   `Library/Application Support` is backed up to iCloud/iTunes by default, so the model store is
   too — **473 MB per model**, and S3 is precisely what makes N models one tap away. Before this
   session a device had one hand-copied model; after it, the store is user-growable.
2. **A completed download leaves ~473 MB of CFNetwork staging in `NSTemporaryDirectory()`** on top
   of the 473 MB store copy and the 473 MB retained HF cache (DECISIONS #47), so one model costs
   ~1.4 GB until the system purges temp. On iOS that purge is not on a schedule the app controls.

**Why this is not a one-line fix I should have just made.** Setting `isExcludedFromBackup` on the
model store is genuinely one line, but it decides *whether a user's downloaded models survive
restoring a new device*. Excluded → a restore silently yields an app with no models and a Chat tab
that says "No model selected"; not excluded → every model is in the user's iCloud backup. Both are
defensible and it is a store-policy decision, so per Gotcha #6 it is recorded rather than inferred.

**Options.**
1. **Exclude the store from backup.** Models are re-downloadable by definition now that S3 exists;
   backups stay small. Cost: restore produces an empty store and the user must re-download.
2. **Leave it included.** Restore is seamless; a 3-model device adds ~1.4 GB to every backup.
3. **Exclude, and add a "restore your models" affordance** that re-downloads from the manifests'
   `repo_id` values — the manifest already carries exactly what that needs. Bigger than S3.

**Best guess: (1)**, because #26 already ratified that models are fetched and never bundled — a
model is user data the app can always re-obtain, which is the same argument. But it is TyPod's.

## Answered — detail

### Q3 — Does the model ship with the app, or is it fetched? *(ANSWERED by TyPod, 2026-07-30)*
**Fetched, never bundled.** A model is user data, not a build artifact. See DECISIONS #26.
Original framing below.
**Context.** Gate item G1 exposed this. The Bonsai model (473 MB) had to be pushed onto the
iPhone out-of-band with `devicectl device copy to` before inference could run; a fresh install on
any other device has an empty model store and a Chat tab that can only say "No model selected".
FEATURE_SCOPE ratifies *Download models from HuggingFace (resumable, in-app browser)* and
*Import GGUF from Files* — both are real answers, and both are their own session.

**Options.**
1. **Leave it.** Device provisioning stays a developer step until the HuggingFace downloader lands.
   Costs nothing now; the app is simply not self-sufficient on a new device.
2. **Bundle a small model in the app.** Self-sufficient on first launch, but adds ~473 MB to the
   binary and makes the model a build artifact rather than user data.
3. **Prioritise the HuggingFace downloader** into the next session ahead of other Tier-1 work.

**Best guess: (1) now, (3) soon** — bundling fights the "GZ-BT owns its own store" posture in
DECISIONS #18. Not blocking; recorded so it is a decision rather than a drift.

### Q4 — Should `GZBT_STORE_PATH` survive past Session 2?
**Context.** A DEBUG-only environment override for the store location was added so the exit-criteria
runs could use a throwaway database instead of writing into real conversation history. It is
compiled out of Release builds entirely.

**Options.** (1) Keep it — it is the only way to run the app against a scratch store for evidence.
(2) Remove it once S2 merges and rely on unit tests alone.

**Resolved: keep it (1).** `#if DEBUG` only, four lines, and every future session needing
reproducible store-level evidence will want it.

---

## Answered

### Q1 — §1.A: is `GZ-BT.xcodeproj` committed or ignored? *(ANSWERED — settled by evidence)*
`git ls-files | grep xcodeproj` returns 5 tracked files. DECISIONS #9 (committed) is correct and
carries the later ratification stamp; ARCHITECTURE.md's "(git-ignored)" line was stale and has been
corrected. Now enforced in CI by gate item G2. See DECISIONS #22.

### Q2 — §1.B: which storage engine? *(ANSWERED by TyPod, 2026-07-27)*
System SQLite3 + a thin internal wrapper — option (a). No new package; DECISIONS #8 untouched.
See DECISIONS #21.

### Q5 — Per-platform code signing *(ANSWERED by TyPod, 2026-07-27)*
iOS device builds use automatic signing with team 9TPK22K9J4; macOS and the Simulator keep ad-hoc
"Sign to Run Locally". DECISIONS #12 is amended, not replaced. See DECISIONS #20.
