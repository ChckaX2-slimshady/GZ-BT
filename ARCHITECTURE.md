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
| **Services** | discovery/selection (`ModelManager`), settings | — |
| **Models** | domain value types | depend upward |
| **Utilities** | small helpers | hold state |
| **DesignSystem** | every color/type/spacing/radius/material/motion/gradient token | depend on anything above SwiftUI |

## Folder map (`Sources/`)
```
App/           GZBTApp · AppEnvironment
Navigation/    AppRoute · RootNavigationView · SidebarView
DesignSystem/  ChameleonPalette · Theme · Typography · Layout · Materials · Motion
Views/         Chat/{ChatView,ChatMessageRow,StreamingIndicatorView,ChatMetricsBar}
               Models/{ModelsView,ModelRow} · Settings/SettingsView · Placeholders/PlaceholderView
ViewModels/    ChatViewModel · ModelsViewModel
Inference/     InferenceEngine (protocol + neutral types) · MLXInferenceEngine (actor)
Services/      ModelManager · AppSettings
Models/        ChatMessage · DiscoveredModel · ResolvedModel · GenerationConfig
Utilities/     ByteFormat
```

## Navigation graph
`RootNavigationView` = `NavigationSplitView { SidebarView } detail: { … }`.
`AppRoute` (12): chat · models · hats · prompts · memory · wiki · reader · tools · settings ·
osintinel · rsai · **spectre**. Sidebar groups Workspace / Labs / System. **Spectre** is
appended only when `AppSettings.spectreEnabled` is on (default OFF). Session-1 real destinations:
Chat, Models, Settings; the rest render one tokenized `PlaceholderView`.

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

## Seam-1
`InferenceEngine.telemetry: AsyncStream<TelemetryEvent>` (declared in `Inference/InferenceEngine.swift`).
Contract cases: `.lifecycle`, `.firstToken(ttft:)`, `.throughput`, `.context(used:capacity:)`, `.completed`.
**Currently emitted:** lifecycle, firstToken (TTFT), throughput (tok/s), completed (prompt/generated
counts). **Not yet emitted:** `.context` (see DECISIONS "Known limitations"). Session-1's only consumer
is `ChatMetricsBar`; **Spectre subscribes here later** — this session builds only the seam.

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
`xcodegen generate` → `GZ-BT.xcodeproj` (git-ignored). Scheme **GZ-BT** builds/runs the app per platform;
**GZ-BT-Tests** runs the macOS test suite. See `DECISIONS.md` for toolchain specifics.
```
xcodegen generate
xcodebuild -scheme GZ-BT -destination 'platform=macOS' -skipPackagePluginValidation build
xcodebuild -scheme GZ-BT -sdk iphonesimulator -arch arm64 -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
xcodebuild test -scheme GZ-BT-Tests -destination 'platform=macOS' -skipPackagePluginValidation
```
