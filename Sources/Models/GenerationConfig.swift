/// Neutral generation parameters. The engine maps these onto its own
/// parameter type internally, so no engine-specific type leaks into callers.
struct GenerationConfig: Sendable, Equatable {
    var maxTokens: Int
    var temperature: Double
    var topP: Double

    init(maxTokens: Int = 512, temperature: Double = 0.7, topP: Double = 0.95) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
    }
}
