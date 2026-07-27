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

## Deferred / out of scope (unchanged from FEATURE_SCOPE)
Remote APIs, GGUF, persistence, iCloud, HATS/Memory/Wiki/Tools internals, Spectre internals
beyond Seam-1, theming UI. Light theme is implemented but the app pins dark (primary) for the
Session-1 showcase; a theme picker is out of scope.
