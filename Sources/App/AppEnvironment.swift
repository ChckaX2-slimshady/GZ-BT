import Foundation
import Observation

/// Composition root. Builds and holds the app's long-lived services and the
/// Chat coordinator, and hands them to the view tree through the environment.
///
/// Chat is held here (not created per-view) so its Seam-1 telemetry subscription
/// survives navigation between destinations.
@MainActor
@Observable
final class AppEnvironment {
    let settings: AppSettings
    let models: ModelManager
    /// Owns `HubApi` and the model-store writes. Built here so a download survives
    /// navigating away from the Models tab.
    let downloader: ModelDownloader
    let store: ConversationStore
    let engine: any InferenceEngine
    /// Single Seam-1 consumer, shared by Chat's metrics bar and the Spectre view.
    let telemetry: TelemetryHub
    let chat: ChatViewModel

    /// The engine's storage-facing identity. Lives here, not on `InferenceEngine`:
    /// adding a property to that protocol would amend the inference contract, which
    /// BUILD_SESSION_2 §7 rules out for this session.
    private static let engineID = "mlx"

    init() {
        let settings = AppSettings()
        let models = ModelManager()
        // One store owner, built here — never in SwiftUI `@State`, which is recreated
        // and would open several connections to the same file (§8).
        #if DEBUG
        // Evidence aid: `GZBT_STORE_PATH` points the app at a throwaway store, so
        // exit-criteria runs never write into real conversation history. Release
        // builds always use the canonical location.
        let override = ProcessInfo.processInfo.environment["GZBT_STORE_PATH"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let store = ConversationStore(url: override)
        #else
        let store = ConversationStore()
        #endif
        let engine = MLXInferenceEngine()
        let telemetry = TelemetryHub()
        self.settings = settings
        self.models = models
        self.downloader = ModelDownloader(manager: models)
        self.store = store
        self.engine = engine
        self.telemetry = telemetry
        self.chat = ChatViewModel(
            engine: engine, models: models, store: store,
            telemetry: telemetry, engineID: Self.engineID)

        // Subscribe at launch, not from a view. Spectre has to render live even if the
        // user never opens Chat, and the engine emits `.lifecycle(.idle)` at init.
        telemetry.start(engine)
    }
}
