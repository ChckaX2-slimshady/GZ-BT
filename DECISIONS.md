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
9. **XcodeGen generates the project — HONEST NOTE (needs TyPod ratification).**
   The Session-1 spec listed, as a *default* (not one of the four ratified interview questions):
   "hand-authored `.xcodeproj`… no XcodeGen/Tuist, no new tools installed." During Checkpoint 1 I
   found XcodeGen **already installed** (`/opt/homebrew/bin/xcodegen`) and switched to it for
   reliability, flagging the switch in-session. So: *no NEW tool was installed* (it pre-existed),
   but the generation **method changed from the stated default without explicit ratification** —
   it slipped in. `project.yml` is the source of truth; `GZ-BT.xcodeproj` is git-ignored.
   **Reproducibility cost:** a fresh clone must run `xcodegen generate` (needs XcodeGen present;
   `brew install xcodegen`) before building. If you want zero external tooling, the alternatives
   are to commit the generated `.xcodeproj` or hand-author one — **your call to ratify or revert.**
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
  instead of crashing. Inference is verified on **macOS** and would run on a **real iPhone**; the
  sim renders UI + model discovery only.
- **Seam-1 context utilization is not emitted yet.** `TelemetryEvent.context(used:capacity:)` exists
  in the contract but the engine never yields it. TTFT, tokens/sec, lifecycle, and prompt/generated
  token counts *are* emitted. Context *used* is derivable (prompt+generated); *capacity* is 32768 for
  Bonsai (from `max_position_embeddings`) but is not read into the stream. Wiring it is the first
  Seam-1 follow-up — deliberately not added during this verification-only close-out.

## Deferred / out of scope (unchanged from FEATURE_SCOPE)
Remote APIs, GGUF, persistence, iCloud, HATS/Memory/Wiki/Tools internals, Spectre internals
beyond Seam-1, theming UI. Light theme is implemented but the app pins dark (primary) for the
Session-1 showcase; a theme picker is out of scope.
