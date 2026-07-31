# QUESTIONS.md — open items for TyPod

Numbered, with context and best-guess options, per CLAUDE.md Gotcha #6.
Answered items stay here with their resolution so the reasoning is not lost.

---

## Open

*(none — Q3 and Q4 answered 2026-07-30)*

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
