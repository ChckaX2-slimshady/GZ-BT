import Foundation

/// One persisted Seam-1 record per assistant message.
///
/// `schemaVersion` + `extra` are a **database-layer** envelope so later telemetry
/// fields can land without a schema migration. This is deliberately *not* part of
/// the Seam-1 contract — Seam-1 is an enum with fixed cases — and must not be
/// removed as redundant (§4.2).
struct MessageTelemetry: Equatable, Sendable {
    /// Bump when the meaning of an existing column changes, not when `extra` grows.
    static let currentSchemaVersion = 1

    let messageID: UUID
    var modelID: String
    /// `mlx` | `llamacpp` | `remote:<provider>`. Supplied by the composition root,
    /// not by the engine — adding an identity property to `InferenceEngine` would
    /// be a contract change, and §7 forbids one this session.
    var engine: String

    var ttftMs: Double?
    var tokensPerSecond: Double?
    var contextUsed: Int?
    var contextCapacity: Int?

    // §4.4 predicted these three would be unfillable. They are not — see
    // DECISIONS.md, Session 2: `.completed(GenerationSummary)` carries all three.
    var promptTokens: Int?
    var tokensOut: Int?
    var finishReason: String?

    var schemaVersion: Int
    /// JSON, engine-specific fields. Unused this session; the envelope is the point.
    var extra: String?

    init(
        messageID: UUID,
        modelID: String,
        engine: String,
        ttftMs: Double? = nil,
        tokensPerSecond: Double? = nil,
        contextUsed: Int? = nil,
        contextCapacity: Int? = nil,
        promptTokens: Int? = nil,
        tokensOut: Int? = nil,
        finishReason: String? = nil,
        schemaVersion: Int = MessageTelemetry.currentSchemaVersion,
        extra: String? = nil
    ) {
        self.messageID = messageID
        self.modelID = modelID
        self.engine = engine
        self.ttftMs = ttftMs
        self.tokensPerSecond = tokensPerSecond
        self.contextUsed = contextUsed
        self.contextCapacity = contextCapacity
        self.promptTokens = promptTokens
        self.tokensOut = tokensOut
        self.finishReason = finishReason
        self.schemaVersion = schemaVersion
        self.extra = extra
    }
}
