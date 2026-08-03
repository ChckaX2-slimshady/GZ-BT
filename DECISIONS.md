# DECISIONS.md — GZ-BT Phoenix, Build Session 1 (2026-07-24)

Every architectural fork, the choice, and why. TyPod owns direction (ratified items);
Claude owns implementation choices within them.

## Ratified by TyPod (this session)
1. **Deployment targets: iOS 26 / macOS 26.** Matches the installed toolchain and TyPod's
   devices; unlocks the newest SwiftUI materials, `@Observable`, full Swift 6 concurrency
   with no back-deploy. MLX floor (iOS 17 / macOS 14) is well below.
2. **Navigation: `NavigationSplitView` sidebar.** 12 destinations, iPad/Mac-first ergonomics,
   collapses to a stack on iPhone; scales past TabView's 5-item iPhone limit.
3. **Identity: name "GZ-BT", bundle id `ai.gzbt.app`.**
4. **Inference model: a Bonsai model** — `Ternary-Bonsai-1.7B-mlx-2bit` (462 MB, `model_type`
   qwen3, 2-bit/group 128). Lightweight (fits the "reduce compute overhead" goal). It is an
   open-weight model; copied into GZ-BT's **own** store so discovery never reads another app's
   container. Verified: loads and streams at ~68 tok/s, TTFT ~0.23 s.

## Substrate & packages
5. **MLX Swift is the ratified substrate** (no swap). `mlx-swift-lm` pinned **2.31.3** — every
   MLX API used was read from this exact source in-session (no invented symbols).
6. **`mlx-swift` pinned 0.31.6, not 0.31.3.** 0.31.3 compiles Metal from source and needs the
   Metal Toolchain; 0.31.6 ships prebuilt Metal. Our code calls **no** mlx-swift API directly
   (only mlx-swift-lm), so the patch bump is API-safe.
7. **Metal Toolchain component downloaded (687 MB).** Required to compile MLX's Metal kernels
   under Xcode 26 (not bundled by default). The one unavoidable install; flagged, not silent.
8. **No third-party packages beyond the MLX substrate + its transitive deps.**

## Project & build
9. **XcodeGen generates the project — RATIFIED (TyPod, 2026-07-25).**
   `project.yml` is **authoritative**. XcodeGen was already installed (`/opt/homebrew/bin/xcodegen`),
   so no new tool was installed; it was adopted over the spec's hand-authored default, and TyPod has
   now ratified it. To keep a fresh clone building with **zero external tooling**, the generated
   `GZ-BT.xcodeproj` **is committed**, and is regenerated (`xcodegen generate`) and re-committed at
   each checkpoint. Package pins live in the committed `…/swiftpm/Package.resolved`. Editing the
   project = edit `project.yml` then regenerate; never hand-edit the `.xcodeproj`.
10. **Single multiplatform app target** (`supportedDestinations: [iOS, macOS]`).
11. **Two schemes: `GZ-BT` (app) and `GZ-BT-Tests` (macOS tests).** A macOS-only test target
    inside the app scheme breaks single-platform (iOS-Simulator) builds; splitting fixes it.
12. **Signing: ad-hoc "Sign to Run Locally" (`-`), no dev team** — headless macOS + sim dev.
13. **`-skipPackagePluginValidation` for headless builds** — trusts mlx-swift's `CudaBuild`
    build-tool plugin without an interactive enable prompt.
14. **iOS built via `-sdk iphonesimulator -arch arm64`; installed on the iOS 26.4 sim via
    `simctl`.** Only the 26.4 runtime is installed (SDK is 26.5), so xcodebuild's destination
    picker rejects it, but a 26.0-target build runs fine on 26.4 through `simctl`.

## Architecture
15. **Modern Observation (`@Observable`) + Swift 6 strict concurrency.** UI on `MainActor`;
    streaming via `AsyncStream`; cancellation via task cancellation.
16. **`MLXInferenceEngine` is an `actor` wrapping `ModelContainer`** (a `Sendable` class — not
    `actor` + `ObservableObject`, honoring the documented isolation gotcha). All MLX work runs
    inside `container.perform`; only `Sendable` values cross out.
17. **Seam-1 = `InferenceEngine.telemetry: AsyncStream<TelemetryEvent>`.** Engine-neutral; no
    MLX type crosses it. Built as a seam only — no Spectre. Future Spectre subscribes here.
18. **`ModelManager` (Services) is the only filesystem scanner.** Engines receive a resolved
    URL. Store: `~/Library/Application Support/GZ-BT/Models` (macOS non-sandboxed dev) / app
    sandbox on iOS.
19. **macOS app non-sandboxed for Session-1 dev** so it can read the shared model store.

## Known limitations (honest — not fake green)
- **MLX does not run on the iOS Simulator.** MLX needs a Metal GPU; the simulator has none, so
  `MLXInferenceEngine.load` would abort (`mlx::core::metal::Device::Device()` → SIGABRT, confirmed
  via crash log). We **guard it** with `#if targetEnvironment(simulator)` and surface a clear error
  instead of crashing. Inference is verified on **macOS** and on a **real iPhone** (see below); the
  sim renders UI + model discovery only.
  **Update (Session 2, gate item G1):** the "*would* run on a real iPhone" claim is retired — it
  does. Verified on an iPhone 15 Pro Max (A17 Pro, iOS 26.5): **TTFT 225 ms, 76.3 tok/s**, read out
  of `message_telemetry` in the store pulled off the device. Faster than the M1 Air.

(Seam-1 `.context(used:capacity:)` is now emitted — capacity from `max_position_embeddings`, ratified
and wired 2026-07-25 before merge.)

## Ratified by TyPod — Build Session 2 (2026-07-27)

20. **Code signing is per-platform — amends #12, does not replace it.** Ad-hoc signatures
    cannot install on a physical device, which gate item G1 requires. So signing now splits
    by SDK:
    - **iOS (`[sdk=iphoneos*]`)** — automatic signing, team **9TPK22K9J4**, cert
      *Apple Development: tyson.j.earl@gmail.com*, Xcode-managed provisioning profile.
      Device builds need `-allowProvisioningUpdates` so Xcode can mint/refresh the
      7-day free-provisioning profile.
    - **macOS and the iOS Simulator** — unchanged. Ad-hoc "Sign to Run Locally" (`-`),
      no development team, no profile. **#12 still holds for these platforms.**

    Encoded in `project.yml` as SDK-conditional build settings
    (`CODE_SIGN_STYLE[sdk=iphoneos*]`, `CODE_SIGN_IDENTITY[sdk=iphoneos*]`,
    `CODE_SIGNING_REQUIRED[sdk=iphoneos*]`, `DEVELOPMENT_TEAM[sdk=iphoneos*]`) so the
    split survives `xcodegen generate`. XcodeGen 2.45.4 passes bracketed condition keys
    through verbatim — verified against the installed distribution (its own CHANGELOG
    ships `CODE_SIGN_IDENTITY[sdk=iphoneos*]` in the iOS presets) and confirmed in the
    generated `.xcodeproj`, where both app-target configs carry the conditional keys
    alongside the unconditional ad-hoc base.

    Verified by building both lanes and inspecting the resulting signatures:
    ```
    macOS:  Signature=adhoc            TeamIdentifier=not set
            Signing Identity: "Sign to Run Locally"
    iOS:    Authority=Apple Development: tyson.j.earl@gmail.com (Y8G6ZJLPHM)
            TeamIdentifier=9TPK22K9J4
    ```
    **CI is unaffected** — it builds macOS + iOS-Simulator only, so it needs no secrets.

    *Process note (not a decision):* this arrived as a hand-edit to `project.pbxproj`
    made through the Xcode UI, which regeneration would have silently erased — the exact
    failure mode gate item G2 exists to catch. The intent was ratified; the mechanism moved
    to `project.yml`, per #9.

21. **Storage engine: system SQLite3 + a thin internal wrapper (BUILD_SESSION_2 §1.B, option a).**
    `import SQLite3` ships in the SDK, so **DECISIONS #8 is untouched — no package added**. Full
    SQL control, CLI-inspectable (the exit criteria assert row contents with `sqlite3`), and no
    third party owning our own data. Verified in-session before use: module imports, `open_v2` /
    `prepare_v2` / `bind_text` / `step` / `exec` all resolve, and `PRAGMA foreign_keys = ON` takes
    effect (libsqlite3 3.51.0). GRDB was **not** adopted; its case gets stronger at S6 when FTS5
    and knowledge-graph queries arrive, and it can be ratified then against evidence rather than
    anticipation. `Services/SQLite.swift` is the migration boundary — swapping engines replaces
    that file and nothing above `ConversationDatabase`. **SwiftData was rejected**: its store is
    not a schema we own, which breaks the CLI exit criteria outright.

22. **§1.A adjudicated: the generated `.xcodeproj` IS committed.** Settled by evidence, not
    opinion — `git ls-files | grep xcodeproj` returns 5 tracked files, and `.gitignore` documents
    the intent. DECISIONS #9 was already correct and carries the later ratification stamp;
    **ARCHITECTURE.md's "(git-ignored)" line was the stale one and has been corrected** in the
    same commit, so the conflict cannot recur. Gate item **G2** now enforces it in CI.

26. **Models are fetched, never bundled (answers QUESTIONS Q3).** A model is **user data**, not a
    build artifact. GZ-BT ships no weights; a fresh device has an empty store until the user
    downloads or imports one. Keeps DECISIONS #18 ("GZ-BT owns its own store") intact and keeps the
    binary small. Accepted consequence: until the ratified HuggingFace downloader / Import-from-Files
    land, putting a model on a device is a developer step (`devicectl device copy to`), and Chat
    correctly reports "No model selected" until then.

## Build Session 2.5 — Spectre view as seam falsification test (2026-07-30)

27. **`TelemetryHub` is the single Seam-1 consumer; the seam vends one stream, not two.**
    `AsyncStream` supports exactly one iterator — a second `for await` splits events
    non-deterministically. Spectre is the second reader, so BUILD_SESSION_2 §4.3's choice
    ("a broadcast wrapper or a single accumulator both read from") is resolved as a
    **broadcast hub in Services**. `InferenceEngine` is untouched: vending a second stream
    would be a seam amendment and is TyPod's call.

    The hub is started by **`AppEnvironment` at launch, not by a view**. Had the subscription
    stayed in `ChatView.task`, opening Spectre on a fresh launch without visiting Chat would
    show a dead dashboard. `ChatViewModel` now registers a sink; its Session-2 `apply(_:)`
    logic is unchanged, so the persistence path did not move.

28. **S2.5 exit criterion MET — the dashboard renders live with no new `TelemetryEvent` case.**
    `Sources/Inference/` is **byte-identical to `v0.2.0-phoenix-s2`** (`git diff --stat` empty).
    Every readout — lifecycle, TTFT, tok/s, peak, prompt/generated tokens, stop reason, context
    used/capacity, turn count, throughput series — is derived from the five cases the contract
    already had. Verified live on macOS and asserted in
    `TelemetryHubTests.testDashboardIsFullyPopulatedFromExistingSeamCasesOnly`, which fails if
    any readout falls back to "—".

    Together with **#23** (the §4.4 columns were also fillable), Seam-1 has now survived both
    halves of its falsification test. **No amendment is pending.**

## Findings — Build Session 2

23. **§4.4's three predicted seam gaps are FALSIFIED. No amendment is needed.** BUILD_SESSION_2
    predicted `prompt_tokens`, `tokens_out` and `finish_reason` would be unfillable from Seam-1
    and should be written NULL and escalated. Reading the actual contract disproves all three:
    `TelemetryEvent.completed(GenerationSummary)` carries `promptTokens`, `generatedTokens` and
    `stopReason` (`Sources/Inference/MLXInferenceEngine.swift`, where the summary is built from
    MLX's `info`). All three columns are **populated in production**, confirmed by `sqlite3`
    against a real turn:
    ```
    prompt_tokens  tokens_out  finish_reason
    34             6           stop
    ```
    The §4.4 prediction was reasoned from the *event case list* alone; `.completed`'s payload was
    the missing piece. **Seam-1 is unchanged.** This retires most of the planned S2.5
    falsification test early — S2.5 can go straight to the live Spectre view.

24. **Streaming write policy (§4.5) as specified — no per-token writes.** User row `complete` on
    send; assistant row empty/`streaming` before generation; tokens buffer in memory; one
    transaction commits final content + terminal status + the telemetry row. Any row still
    `streaming` at launch is a crash artifact and is swept to `failed`. Consequence, accepted: a
    hard kill loses the in-memory buffer, so the reclaimed row has empty content — it renders an
    explicit "interrupted" line rather than a blank turn.

25. **Telemetry is closed from the generation stream's summary, not the telemetry stream's
    `.completed`.** `InferenceEngine.telemetry` and the per-request `AsyncStream<GenerationEvent>`
    are independent streams consumed by different tasks, so their events have **no relative
    ordering**. The first implementation waited on the telemetry stream's `.completed` and
    silently dropped `message_telemetry` rows when a turn finished first — caught by exit
    criterion E3 against a live store (3 assistant messages, 2 telemetry rows). The engine yields
    the *same* `GenerationSummary` on both streams, so the accumulator now closes from the one we
    know has arrived, deriving `context_used` as `promptTokens + generatedTokens` exactly as the
    engine defines it. **No seam change**; two regression tests cover it.

## Ratified by TyPod — Build Session 3 (2026-08-02)

The first eight carry `S3_RECON.md`'s 14 decisions into S3 per BUILD_SESSION_3 §1.

29. **`HubApi` (swift-transformers) is the one HuggingFace path.** Not `HubClient`
    (swift-huggingface), whose `computeFileHash` is dead code with no callers; only `HubApi`
    verifies SHA256 live. The MLX substrate already calls `HubApi`
    (`MLXLMCommon/Load.swift:22–39`), so using it keeps **one** HF path. Two would be a silent
    substrate divergence (Gotcha #1). Recon #1.

30. **`swift-transformers` is declared in `project.yml` at the already-resolved pin.** It was
    already in the graph transitively (`mlx-swift-lm 2.31.3 → swift-transformers 1.2.1`); S3
    calls it directly, so the dependency is declared rather than relied on as implicit
    transitive module visibility. This does not violate #8 — it makes a true thing explicit.
    The pin is copied verbatim from `Package.resolved`, **including the missing `.git`
    suffix** (`https://github.com/huggingface/swift-transformers`), because a URL mismatch
    rewrites `location` and would fail E12 for a purely cosmetic reason. Verified:
    `Package.resolved` md5 `ccbb19626988d9597d06297a9fd0e2f0` before and after both
    `xcodegen generate` and a full build. Recon #2.

31. **Foreground-only.** `HubApi(useBackgroundSession: true)` aborts the process with an
    uncatchable `NSGenericException` (SIGABRT) — no `do/catch` at any call site contains it
    (S3_RECON §3.1a, reproduced twice). `ModelDownloadEngine` hardcodes `false`. iOS states the
    constraint in the UI rather than pretending the transfer survives backgrounding. Recon #3.

32. **Download to `HubApi`'s cache, then move into the store on completion.** Not `downloadBase`
    retargeting, not discovery changes. `downloadBase` is set to `…/GZ-BT/Downloads` — beside the
    store, so the completion move is a same-volume rename, and deliberately *outside* `Models/`
    so a partially-materialized repo is never visible to `scan()`. Recon #4.

33. **Directory name = last path component of the repo id.** `prism-ml/Ternary-Bonsai-1.7B-mlx-2bit`
    → `Ternary-Bonsai-1.7B-mlx-2bit`, which is exactly the existing store dir and the only
    `model_id` in `message_telemetry`. No migration. The full id survives in the manifest's
    `repo_id`. Recon #5.

34. **Keep the cache.** A same-volume move is a rename, so the ~946 MB *peak* does not occur at
    install time. **Measured consequence not stated when this was ratified: the cache is also
    kept after completion, so an installed model costs ~2× on disk permanently** — 473 MB in
    `~/.cache/huggingface/hub` alongside 473 MB in the store, confirmed by `du` after E1. That
    is the price of resume remaining available (#37). Cross-volume stores (an external SSD)
    would additionally pay a real copy; recorded, not solved. Recon #6.

35. **Manifest presence = complete.** Partial downloads never enter the store, so a directory
    carrying the manifest is known-good. Recon #7.

36. **Progress crosses isolation via a `Sendable` snapshot, owned by an actor.** Recon #14 named
    the `TelemetryHub` pattern; the actual shape is the **`ConversationDatabase` +
    `ConversationStore`** pair, because the problem is the inverse of `TelemetryHub`'s.
    `TelemetryHub` is `@MainActor @Observable` *consuming* an already-`Sendable` `AsyncStream`;
    it owns no handler and crosses no boundary. S3's problem is passing a **non-`Sendable`
    `(Progress) -> Void` INTO a non-isolated API**. So `ModelDownloadEngine` is an `actor` that
    owns `HubApi` (as `ConversationDatabase` owns the `sqlite3` handle) and `ModelDownloader` is
    the `@MainActor @Observable` façade holding no unsafe state (as `ConversationStore` does).
    The handler is built inside a `nonisolated static` function, converts `Progress` to a
    `Sendable ModelDownloadProgress` on the spot, and lets the `Progress` die there — so it
    compiles under `SWIFT_STRICT_CONCURRENCY: complete` with no `@unchecked Sendable`, no
    `nonisolated(unsafe)`, and no access-control loosening. The callback signature matches the
    seam's own shape, `(@Sendable (Double) -> Void)?` on `InferenceEngine.load`.

37. **Free-space requirement is `2 × total + headroom`, headroom = `max(1 GB, 10% of total)`.**
    The `2 ×` is not conservatism: `HubClient` stores the body into its cache blob and then
    **copies** it to the materialized snapshot directory, so both exist simultaneously —
    measured at 968,098,633 B on disk for a 495,528,947 B model during E3.
    **Superseded in part by #51: the real peak is `3 ×`, because #47 found a third simultaneous
    copy in CFNetwork's temp staging. S3 ships the 2× figure; 3× is the correct one.** The headroom is a
    chosen number recorded here rather than an unexplained constant, so a model can never be
    the thing that fills the volume. Refusal names both figures.

    **Correction to BUILD_SESSION_3 §4.2**, which cites "the iOS vs macOS API difference":
    there is none. `volumeAvailableCapacityForImportantUsage` is `macos(10.13)+ / ios(11.0)+`
    (S3_RECON §3.2) and both deployment targets clear it. The difference is *semantic* — the key
    reports space including what the system expects to reclaim by purging caches — so the same
    key is used on both platforms.

38. **The manifest records `etag` + `etag_kind`, never a field named `sha256`.**
    Amends BUILD_SESSION_3 §4.3's example schema. Per file:
    `{ "path": …, "bytes": N, "etag": …, "etag_kind": "sha256" | "git-blob" }`.

    HuggingFace's ETag is a SHA256 **only for LFS files**; for everything else it is a 40-hex
    git blob hash. Measured across the three starter repos: 2/6, 1/8, and 2/6 entries are real
    SHA256s, and those are exactly the weight files. `HubApi` verifies content only when
    `isValidSHA256(etag)` holds, so its integrity coverage is precisely the LFS files and
    nothing else. Writing `"sha256"` for all six would have put a git blob hash under a false
    name in **our own artifact** — Gotcha #5 aimed at something we produce, not something we
    consume. Asserted by `ModelDownloadTests.testManifestRoundTripsWithSpecifiedJSONShape`,
    which fails if a `sha256` key ever appears.

39. **Manifest absent = legacy, assume complete. Manifest present but unreadable = broken.**
    The asymmetry BUILD_SESSION_3 §4.3 requires, with one correction to that section: it states
    "the existing hand-copied model has no manifest." **It has `.hfmanifest.json`** — verified
    on disk, and verified absent from the live HF listing for
    `prism-ml/Ternary-Bonsai-1.7B-mlx-2bit`, so it is a local artifact of whatever originally
    fetched the model. No `HubApi` download reproduces it: `HubApi` writes
    `.cache/huggingface/download/<file>.metadata` sidecars instead (3 lines — commit sha, etag,
    unix timestamp — confirmed by materialising a real one).

    Therefore completeness is keyed on the **exact filename `.gzbt-model.json`**, deliberately
    distinct. A loose "does it have a manifest?" check would read the legacy directory as
    GZ-BT-complete and invert §4.4's collision asymmetry. Asserted by
    `testManifestFilenameIsDistinctFromTheLegacyHFArtifact`.

40. **Deleting a model does not touch telemetry.** `message_telemetry.model_id` is a plain
    string with no foreign key. History outliving the model is deliberate — Spectre's
    comparative work depends on being able to reason about a model that is no longer installed.
    **A later session must not "fix" this into a cascade.** Asserted against a non-zero row
    count by `testDeletingAModelLeavesTelemetryRowsIntact`, so the test cannot pass vacuously.

41. **`unload()` before delete — forced, not chosen.** `MLXInferenceEngine` holds `container`
    and `loaded` `private`, and `InferenceEngine` exposes no accessor for what is loaded, so a
    refuse-if-loaded rule would require adding a read property to the protocol — which §5
    forbids this session. `unload()` is already on the protocol, so it is called
    unconditionally before the directory is removed.

    The failure this prevents: MLX keeps weights resident, so `generate()` would keep working
    from RAM against a deleted directory while `reconcileSelection()` had already silently
    repointed `activeModelID` at a different model — and `TelemetryHub.lifecycle` reports
    `.loaded` with no model identity, so nothing in the app could tell which model produced the
    output.

42. **`ModelManager.root` is injectable; `GZBT_STORE_PATH` is not extended.** `modelsRoot` was a
    computed static with no seat, so every downloader/manifest/collision test would have written
    into the real model store. The mechanism is the one `ConversationStore.init(url:)` already
    established. `GZBT_STORE_PATH` gates the conversation DB only and is left alone. An injected
    root also suppresses persisting `activeModelID` to the shared `UserDefaults` key, so a test
    run cannot silently repoint the developer's active model.

43. **The download glob is `["*.safetensors", "*.json", "*.jinja"]`, chosen deliberately.**
    §4.2 step 3 does not fix it. This matches what the substrate itself downloads
    (`MLXLMCommon/Load.swift`), so an installed model is the file set MLX expects. It **excludes
    `tokenizer.model`**; verified against live listings that all three starter repos ship
    `tokenizer.json`, and `ModelManager.isUsableModelDirectory` — the same predicate discovery
    uses — is run against the materialized directory *before* the move and *before* the
    manifest, turning any future miss into a loud failure instead of an invisible model.

## Findings — Build Session 3

44. **§4.6 is answered YES: `HubApi` exposes resolved file URLs and expected hashes without
    downloading.** Two symbols, called this session against swift-transformers 1.2.1
    (`58c4bc11963a`), not merely read:

    - `getFilenames(from:matching:) -> [String]` — one GET to `/api/models/<id>/revision/<rev>`,
      parsing `siblings`.
    - `getFileMetadata(from:revision:matching:) -> [FileMetadata]` — one **HEAD** per file
      (`HubApi.swift:1059`), returning `commitHash`, `etag`, `location` (the resolved CDN URL),
      and `size`.

    Cost: 1 + N small requests, no content transfer. Measured totals — Llama-3.2-1B 712,575,975 B
    at `08231374ee…`; Qwen2.5-3B 1,746,177,197 B at `4f83f8f146…`; Bonsai 495,528,947 B at
    `5f3e306330…`.

    **Consequence, recorded and deliberately not built:** a future background transfer keeps
    `HubApi` for resolution and owns only the byte movement with a delegate-based background
    `URLSession`. That is the ~200-line path §4.6 describes, and it is now a scoped future item
    rather than an open question.

45. **Resume works at file granularity and NOT at byte granularity.** E3's criterion is met, but
    the honest characterisation matters and the two runs measure different things:

    - **Between files** — interrupting after `model.safetensors` completed retained
      968,098,633 B and the retry finished in **6.5 s** against a 50.3 s cold baseline. Completed
      files are reused.
    - **Mid-file** — interrupting 15 s in, at 33.3% with **114,418,584 B** of the weight file
      staged in `/T/CFNetworkDownload_*.tmp`, retained only **9,126 B** (the two small completed
      blobs). The partial was discarded and the retry took **77.3 s** — *slower* than a cold
      start. The weight file restarted from zero.

    This is exactly what S3_RECON §2.3 predicts: `HubApi` computes `incompleteDestination` and
    never passes it to `downloadFile` (`:823–827` vs `:849–856`), so resume can only occur
    inside swift-huggingface's ETag+cache branch, which a cancelled task never reaches. **A
    restart is reported as a restart.** Practical effect for foreground-only iOS: backgrounding
    the app during the 473 MB weight file loses that file's progress entirely.

46. **`HubApi.snapshot` returns the destination *normally* when the task is cancelled** rather
    than throwing (`HubApi.swift:966–968`). Trusting its return value would move a partial
    directory into the store as a complete model. `ModelDownloadEngine.download` therefore checks
    `Task.isCancelled` after `snapshot` returns, deletes the materialized tree, and throws.
    Verified by E4: `store contents after cancel: []`, nothing discoverable, and the failure
    surfaces as `NSURLErrorDomain -999 "cancelled"` rather than a silent success.

47. **Every transfer strands CFNetwork staging files in the temp directory — including
    successful ones. A completed 473 MB model occupies ~1.4 GB across three locations.**

    First observed as 33 `CFNetworkDownload_*.tmp` files totalling **2.9 GB** after the
    E1/E3/E4 runs, with sizes matching Bonsai's files exactly. Isolated afterwards by clearing
    the temp directory and running **one clean, uncancelled** download: it left **6 files,
    473 MB — one per downloaded file**. So the leak is *not* cancellation-specific; it is the
    normal path.

    Full steady-state cost of one installed 473 MB model:

    | Location | Bytes | Persists? |
    |---|---|---|
    | `Application Support/GZ-BT/Models/` | 473 MB | permanently — the model |
    | `~/.cache/huggingface/hub` (iOS: `Library/Caches`) | 473 MB | permanently, per #34 |
    | `NSTemporaryDirectory()/CFNetworkDownload_*.tmp` | 473 MB | until the system purges |

    These files are created below `HubApi`, by CFNetwork's own download staging — nothing in
    `Sources/` creates, names, or can see them without guessing at a private filename pattern.
    Recorded per E4's "cache-cleanup behaviour recorded either way".

    **Classification: a LIMIT, not a defect — and therefore not ours to clean up.** Both
    platforms stage into the OS temporary directory, which has a system reaper:

    | Platform | Measured path | Volume semantics |
    |---|---|---|
    | macOS | `$TMPDIR` = `/var/folders/j4/…/T/CFNetworkDownload_*.tmp` | Per-user temp. Reaped by `com.apple.bsd.dirhelper` (`/System/Library/LaunchDaemons/com.apple.bsd.dirhelper.plist`). **Same volume as the store** — `stat -f %d` returns `16777232` for both, so it competes for the same free space until reaped. |
    | iOS | `<app container>/tmp/CFNetworkDownload_*.tmp` — verified on tyFone after the E10 download: 6 files including the full 663.1 MB weight | `NSTemporaryDirectory()`. Purgeable by the system when the app is not running, and (per Apple's container contract) not included in backup. |

    So the bytes are reclaimable rather than stranded forever, which is why this is filed as a
    limit. Two consequences follow and neither is hypothetical:

    - **Reclaimable is not the same as reclaimed.** The staging sits on the same volume as the
      store and is not purged on any schedule the app controls — the iOS copies were still
      present hours after E10. Meanwhile `volumeAvailableCapacityForImportantUsage`, the key
      #37 uses, *does* count purgeable space as available, so the free-space check and the
      purge semantics are at least coherent with each other.
    - **It is not ours to delete.** The files are created by CFNetwork beneath `HubApi`;
      removing them would mean matching a private filename pattern in a directory the HF layer
      owns. That is precisely the routing-around Gotcha #1 forbids. If it ever must be solved,
      it belongs with the background-transfer work (#44), which already owns the byte movement.

    Because it is a limit and not a defect, it does **not** relieve #51 — the free-space
    preflight still has to budget for it. See also QUESTIONS Q6, whose backup half is narrowed
    by this: `tmp/` is not backed up, so only the store's 473 MB inflates an iOS backup, not
    the full ~1.4 GB.

48. **`HubApi`'s snapshot progress counts files, not bytes — so no byte counter is displayed.**
    `Progress(totalUnitCount: filenames.count)` with one pending unit per file
    (`HubApi.swift:942–944`). Multiplying `fractionCompleted` by the preflighted total yields a
    number that looks like bytes and is not: measured on Bonsai, "1 of 6 files complete" renders
    as 82.6 MB whether the completed file was `config.json` (2,939 B) or `model.safetensors`
    (484,049,216 B) — five orders of magnitude apart, displayed identically. `getFilenames`
    returns `Array(Set<String>)`, so the order is not even stable between runs and the error is
    not a consistent bias.

    An earlier draft of this session's UI shipped exactly that derived byte figure, and it was
    caught only because two live runs reported the same "82.6 MB" with 2,991 B and 484,049,292 B
    actually on disk. The UI now reports a percentage and a file count, with the total size shown
    separately. Gotcha #5 applied to our own readout.

49. **`getFileMetadata(from:revision:matching:)` does not forward `revision` to its internal
    `getFilenames` call** (`HubApi.swift:1108`) — the file *list* always comes from `main` while
    the per-file metadata comes from `revision`. Harmless at `revision: "main"`, which is all S3
    uses, and a trap the moment a session pins a revision. `snapshot` does **not** share the
    defect: it forwards correctly at `:941`. Upstream, not ours. See QUESTIONS Q5.

50. **E10 met — the session's goal is proved on hardware.** `mlx-community/Llama-3.2-1B-Instruct-4bit`
    was downloaded **by the phone itself**, from a repo id tapped in the Models tab, with no
    `devicectl device copy to` and no developer attached. The device manifest independently
    reproduces the macOS preflight — `revision 08231374eeacb049a0eade7922910865b8fce912`,
    `total_bytes 712575975` — having never seen it, which is the strongest available evidence
    that preflight and transfer agree. `.cache` was not carried into the store, and
    `Downloads/models/mlx-community/` was left **empty**, confirming the install is a move and
    not a copy.

    It then loaded and generated: `message_telemetry` on device carries
    `model_id = Llama-3.2-1B-Instruct-4bit`, **ttft_ms 117.1, tokens_per_sec 32.2** (iPhone 15
    Pro Max, A17 Pro). Two models now coexist in the device store (Llama 2 rows, Bonsai 7),
    which also exercises `reconcileSelection`'s multi-model path.

    **These numbers are not a baseline** and are deliberately not added to ARCHITECTURE's
    performance table: same absent protocol as #13 — no fixed prompt, no warmup, no repetition.
    A 1B-at-4bit model and a 1.7B-at-2bit model are not comparable on one turn each. Recorded as
    exit-criterion evidence only; S3.75 owns comparable numbers.

51. **The free-space preflight budgets `2 ×`, but #47's real peak footprint is `3 ×`. It
    under-counts by one full copy of the model.** Finding only — **no code changed this
    session**; the correct multiplier is stated here for whoever implements it.

    **What the code actually computes** (`ModelDownloadPlan`, S3 as shipped):

    ```
    requiredBytes = totalBytes × 2 + headroomBytes
    headroomBytes = max(1_000_000_000, totalBytes / 10)
    ```

    So it is **not** `1 × total_bytes` — the 2× for the cache-then-copy was budgeted from the
    start (#37). E5's refusal reproduces exactly:

    ```
    available            = 15.86 GB   (volumeAvailableCapacityForImportantUsage)
    totalBytes           = 15.86 GB   (the E5 plan sets total = available deliberately)
    2 × totalBytes       = 31.72 GB
    headroom = max(1 GB, totalBytes/10) = max(1 GB, 1.586 GB) = 1.586 GB
    requiredBytes        = 31.72 + 1.586        = 33.31 GB   ← matches E5's message
    ```

    **Why 2× is still wrong.** #37 counted two simultaneous copies — the HF cache blob and the
    materialized `downloadBase` snapshot. #47 established a **third**: CFNetwork's `tmp/`
    staging, one full-size file per repo file, all still present at completion. At the moment
    before the final rename, all three coexist:

    | Copy | Location | Measured |
    |---|---|---|
    | CFNetwork staging | `tmp/CFNetworkDownload_*.tmp` | 473 MB (6 files) after a clean download |
    | HF cache blob | `~/.cache/huggingface/hub` (iOS: `Library/Caches`) | 484,049,292 B at cancel |
    | `downloadBase` snapshot | `…/GZ-BT/Downloads/models/<org>/<name>/` | 484,049,340 B at cancel |

    E3 measured cache + `downloadBase` alone at **968,098,633 B** for a **495,528,947 B** model
    — `1.95 ×`. Adding the third copy gives ≈ 1.46 GB, i.e. **≈ 2.95 ×**. All three sit on the
    same volume (`stat -f %d` → `16777232` for both `$TMPDIR` and the store).

    **Correct multiplier: `3 × total_bytes + max(1 GB, 10%)`.** For Bonsai that is 2.49 GB
    rather than the 1.99 GB S3 currently demands; for Qwen2.5-3B, 5.4 GB rather than 3.7 GB.

    **Consequence, stated plainly:** a download can pass preflight and still exhaust the volume.
    The window is `1 × total_bytes` wide — on a volume with between `2 ×` and `3 ×` free, S3
    accepts the job and can run the disk to zero mid-transfer. The 1 GB headroom floor absorbs
    it only for models under ~1 GB. It is partially masked by
    `volumeAvailableCapacityForImportantUsage` counting purgeable space (#47) as available, but
    that is luck, not design: freshly-written staging is not reclaimable on any timeline the
    check can rely on.

    Not fixed here because changing the refusal threshold changes which downloads S3 accepts,
    and S3 has already been verified end-to-end at 2×. It is a one-line change with a real
    behavioural blast radius, so it belongs to a session that can re-run E5 and E1.

## Deferred / out of scope (unchanged from FEATURE_SCOPE)
Remote APIs, GGUF, persistence, iCloud, HATS/Memory/Wiki/Tools internals, Spectre internals
beyond Seam-1, theming UI. Light theme is implemented but the app pins dark (primary) for the
Session-1 showcase; a theme picker is out of scope.
