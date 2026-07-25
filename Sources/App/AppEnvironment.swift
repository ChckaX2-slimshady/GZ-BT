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
    let engine: any InferenceEngine
    let chat: ChatViewModel

    init() {
        let settings = AppSettings()
        let models = ModelManager()
        let engine = MLXInferenceEngine()
        self.settings = settings
        self.models = models
        self.engine = engine
        self.chat = ChatViewModel(engine: engine, models: models)
    }
}
