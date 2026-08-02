# ARCHITECTURE.md — GZ-BT Phoenix

**Architecture version:** 1.0 (Build Session 1, 2026-07-24) · iOS 26 / macOS 26 · Swift 6.

## Module ownership (layers)
`App → Navigation → Views → ViewModels → Inference → Services → Models → Utilities`,
with **DesignSystem orthogonal** to all UI.

| Layer | Owns | Must NOT |
|-------|------|----------|
| **App** | process lifecycle, scene, composition root (`AppEnvironment`) | reach into Inference directly |
| **Navigation** | routing only (`AppRoute`, split-view shell) | hold business logic |
| **Views** | render state; read DesignSystem tokens | hold engine refs; hardcode visual values |
| **ViewModels** | presentation state (`@MainActor @Observable`) | import DesignSystem tokens; scan the filesystem; import MLX |
| **Inference** | engine-neutral contract + MLX binding | scan the filesystem; leak MLX types past the seam |
| **Services** | discovery/selection (`ModelManager`), settings, **chat persistence** (`ConversationStore`), **model download** (`ModelDownloader` + `ModelDownloadEngine`) | let SQL escape the store; let `HubApi` or a `Progress` escape the downloader |
| **Models** | domain value types | depend upward |
| **Utilities** | small helpers | hold state |
| **DesignSystem** | every color/type/spacing/radius/material/motion/gradient token | depend on anything above SwiftUI |

## Folder map (`Sources/`)
```
App/           GZBTApp · AppEnvironment
Navigation/    AppRoute · RootNavigationView · SidebarView
DesignSystem/  ChameleonPalette · Theme · Typography · Layout · Materials · Motion
Views/         Chat/{ChatView,ChatMessageRow,StreamingIndicatorView,ChatMetricsBar,
                     ConversationListView}
               Models/{ModelsView,ModelRow} · Settings/SettingsView · Placeholders/PlaceholderView
               Spectre/SpectreView
ViewModels/    ChatViewModel · ModelsViewModel · SpectreViewModel
Inference/     InferenceEngine (protocol + neutral types) · MLXInferenceEngine (actor)
Services/      ModelManager · AppSettings · ConversationStore · ConversationDatabase ·
               SQLite · TelemetryAccumulator · TelemetryHub ·
               ModelDownloader (@MainActor façade) · ModelDownloadEngine (actor, owns HubApi)
Models/        ChatMessage · DiscoveredModel · ResolvedModel · GenerationConfig ·
               Conversation · PersistedMessage · MessageTelemetry ·
               ModelManifest · ModelDownload (progress/plan/state/errors)
Utilities/     ByteFormat · Log
```

## Navigation graph
`RootNavigationView` = `NavigationSplitView { SidebarView } detail: { … }`.
`AppRoute` (12): chat · models · hats · prompts · memory · wiki · reader · tools · settings ·
osintinel · rsai · **spectre**. Sidebar groups Workspace / Labs / System. **Spectre** is
appended only when `AppSettings.spectreEnabled` is on (default OFF). Real destinations:
Chat, Models, Settings (Session 1) and **Spectre** (S2.5); the rest render one tokenized
`PlaceholderView`.

## Dependency rules (enforced by imports)
- Views → ViewModels, DesignSystem. ViewModels → Inference (protocol), Services, Models.
- **Only `MLXInferenceEngine` imports MLX** (`MLXLLM`, `MLXLMCommon`).
- DesignSystem imports SwiftUI only. Placeholders import DesignSystem only.
- `AppEnvironment` builds `AppSettings`, `ModelManager`, the engine, and the shared `ChatViewModel`,
  injecting them via `@Environment`.

## Inference flow
1. `ChatView` → `ChatViewModel.send()` builds a `GenerationRequest` (neutral `ChatTurn`s + `GenerationConfig`).
2. `ChatViewModel` awaits `engine.generate(request) -> AsyncStream<GenerationEvent>` and consumes
   `.token` / `.completed` / `.failed` on the main actor, appending tokens to the streaming message.
3. `MLXInferenceEngine` (actor) loads via `LLMModelFactory.loadContainer(ModelConfiguration(directory:))`
   and runs generation inside `ModelContainer.perform { generate(input:parameters:context:) }`,
   translating MLX `Generation` → neutral `GenerationEvent`. No MLX type crosses the boundary.
4. `ModelManager` resolves a `DiscoveredModel` → `ResolvedModel(url:)`; the engine never scans disk.

## Download flow (Session 3)

`ModelsView` → `ModelsViewModel` → `ModelDownloader` (`@MainActor @Observable`) →
`ModelDownloadEngine` (`actor`) → `HubApi`.

1. **Preflight, metadata only.** `HubApi.getFilenames` (one GET) + `HubApi.getFileMetadata`
   (one HEAD per file) yield the file set, per-file bytes, per-file ETag, and the resolved
   commit SHA — **without transferring content**. This is what lets steps 2 and 3 refuse before
   any byte moves.
2. **Free space.** Refuse unless `2 × total + max(1 GB, 10%)` is available
   (`volumeAvailableCapacityForImportantUsage`, same key on both platforms). The `2 ×` is real:
   the transfer caches the body and then copies it to the snapshot directory.
3. **Collision (§4.4).** Absent → proceed. GZ-BT manifest with a matching `repo_id` → already
   installed. Manifest with a different `repo_id` → genuine collision, both ids named. **No**
   GZ-BT manifest → unknown occupant, refuse. Never auto-rename: a silent rename would break
   `activeModelID` and `message_telemetry.model_id`.
4. **Transfer.** `HubApi.snapshot(matching: ["*.safetensors","*.json","*.jinja"])`,
   `useBackgroundSession: false` — always. Progress crosses isolation as a `Sendable`
   `ModelDownloadProgress`; the non-`Sendable` `Progress` never leaves the `nonisolated`
   function that receives it.
5. **Verify, then move, then manifest — in that order.** The materialized directory must satisfy
   `ModelManager.isUsableModelDirectory` (the *same* predicate discovery uses) before it is moved;
   the move into the store is a same-volume rename; `.gzbt-model.json` is written **last**, so a
   crash mid-move can never leave a directory that looks complete.
6. **Rescan.** `ModelManager.scan()` — `async`, tree walk off the main actor.

`Sources/Inference/` is not involved at any step: the downloader puts files on disk, and the
engine still only ever receives a resolved local `URL`. Downloading via
`ModelConfiguration(id:)` / `LLMModelFactory.loadContainer` is deliberately **not** used — it
would land weights in `HubApi`'s cache instead of GZ-BT's store and move the download path into
`Inference/`.

## Seam-1
`InferenceEngine.telemetry: AsyncStream<TelemetryEvent>` (declared in `Inference/InferenceEngine.swift`).
**All contract cases are emitted:** `.lifecycle`, `.firstToken(ttft:)`, `.throughput` (tok/s),
`.context(used:capacity:)` (used = prompt+generated; capacity = model `max_position_embeddings`, read by
`ModelManager` and passed via `ResolvedModel`), `.completed`.

**Single consumer, many readers (S2.5).** `AsyncStream` supports exactly one iterator, so
`Services/TelemetryHub` is *the* consumer and re-broadcasts to registered sinks. It is started by
`AppEnvironment` **at launch, not by a view** — Spectre has to render live even if the user never
opens Chat. `ChatViewModel` registers a sink (its Session-2 handling is unchanged); `SpectreViewModel`
reads the hub's observable state. Adding a second stream to `InferenceEngine` would be a seam
amendment and is TyPod's call — it was not needed.

## Persistence (Session 2)
`Services/ConversationStore` (`@MainActor @Observable`) is the app-facing surface and the sole
owner of chat storage — `ModelManager`'s counterpart for models. It holds **no** SQLite state:
every statement runs inside `ConversationDatabase`, an `actor` wrapping the **system** SQLite3
library (`import SQLite3`, no package added), so a write can never block token streaming.
`ChatViewModel` talks to the store and never sees SQL. Built once in `AppEnvironment`, never in
SwiftUI `@State`.

**Store:** `~/Library/Application Support/GZ-BT/gzbt.sqlite` — beside `Models/` — and the sandbox
equivalent on iOS. Three tables (`conversations`, `messages`, `message_telemetry`) with
`ON DELETE CASCADE`; `PRAGMA foreign_keys = ON` is set **and asserted** at open. Migrations run
off `PRAGMA user_version` and are idempotent. `schema_version` + `extra` on the telemetry table
are a database-layer envelope for future fields — deliberately *not* part of the Seam-1 contract.

**Write policy:** the user row lands `complete` and the assistant row lands empty/`streaming`
before generation starts; tokens buffer **in memory** (no per-token writes); completion commits
final content, terminal status and the telemetry row in **one transaction**. Any row still
`streaming` at launch is a crash artifact and is swept to `failed`.

**Telemetry:** `TelemetryAccumulator` turns the Seam-1 event stream into one `message_telemetry`
row. `ChatViewModel` remains the single consumer of `InferenceEngine.telemetry` and feeds the
accumulator from its existing handler — no second iterator. Because telemetry and generation are
*independent* `AsyncStream`s with no relative ordering, the record is closed from the generation
stream's `GenerationSummary` (the engine yields the same value on both); relying on the telemetry
stream's `.completed` raced with turn completion and silently dropped rows.

**Persistence never enters `Inference/`.** The engine emits on Seam-1; the store consumes and
persists. Verified by grep as an exit criterion.

## Token semantics (DesignSystem)
Raw Veiled Chameleon ramp (`ChameleonPalette`) → semantic roles (`Theme`: surfaces, structure,
accents, text, warning) resolved per color scheme via `\.theme`. Dark is primary; light inverts around
bone. Depth is expressed through **membranes** (`membraneSurface` = material + canopy tint + hairline),
never shadows. `Space`/`Radius` scales, restrained `ChameleonType`, brief `Motion` springs.

## Concurrency
`@MainActor @Observable` for ViewModels and Services; UI on the main actor. `MLXInferenceEngine` is an
`actor` wrapping a `Sendable` `ModelContainer` (not actor + ObservableObject). Streaming is `AsyncStream`;
only `Sendable` values cross the actor boundary; cancellation propagates via `Task` cancellation.

## Build / run
`project.yml` is authoritative; `xcodegen generate` → `GZ-BT.xcodeproj`, which **is committed**
(regenerated and re-committed at each checkpoint) so a fresh clone builds with zero external tooling —
per DECISIONS #9, ratified 2026-07-25. Never hand-edit the `.xcodeproj`; edit `project.yml` and regenerate.
Scheme **GZ-BT** builds/runs the app per platform; **GZ-BT-Tests** runs the macOS test suite.
See `DECISIONS.md` for toolchain specifics.
```
xcodegen generate
xcodebuild -scheme GZ-BT -destination 'platform=macOS' -skipPackagePluginValidation build
xcodebuild -scheme GZ-BT -sdk iphonesimulator -arch arm64 -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
xcodebuild test -scheme GZ-BT-Tests -destination 'platform=macOS' -skipPackagePluginValidation

# Physical iPhone (real signing — see DECISIONS #20)
xcodebuild -scheme GZ-BT -destination 'generic/platform=iOS' -skipPackagePluginValidation \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device <udid> <path>/Debug-iphoneos/GZ-BT.app
```
`.github/workflows/ci.yml` runs the first four on every push: regenerate → **drift check**
(the committed `.xcodeproj` must match `project.yml`) → macOS build → iOS-Simulator build → tests.

## Measured performance
| Platform | Device | TTFT | tok/s | Model |
|---|---|---|---|---|
| macOS | M1 Air | ~0.23 s | ~68 | Ternary-Bonsai-1.7B-mlx-2bit |
| **iOS** | **iPhone 15 Pro Max (A17 Pro), iOS 26.5** | **225 ms** | **76.3** | same |

> **The macOS row is a Session-1 informal measurement; its protocol is undefined** — no fixed
> prompt, no warmup, no repetition, and the turn shape was not recorded. Persisted values from
> `message_telemetry` on the same machine range **49.7–56.1 tok/s** with TTFT **96.6–102.3 ms**.
> A defined baseline arrives with the benchmark harness (S3.75); until then this number should
> not be cited as one. See S3_RECON §6.

Device numbers are from gate item **G1** — read out of `message_telemetry` in the SQLite store
pulled off the phone with `devicectl device copy from`, not from a log line. They retire the
"*would* run on a real iPhone" claim in DECISIONS' known-limitations section: it does, and it is
faster than the M1 Air. The iOS **Simulator** still cannot run MLX (no Metal GPU) and is guarded.
