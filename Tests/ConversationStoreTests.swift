import XCTest
@testable import GZBT

/// Persistence-layer proofs. These run everywhere — no model required — so CI
/// exercises them on every push.
final class ConversationStoreTests: XCTestCase {

    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        storeURL = FileManager.default.temporaryDirectory
            .appending(path: "gzbt-test-\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: storeURL.deletingLastPathComponent()
                    .appending(path: storeURL.lastPathComponent + suffix))
        }
        storeURL = nil
        super.tearDown()
    }

    // MARK: - Schema & migrations

    /// E6 — launching twice on a populated DB must not error or duplicate schema.
    func testMigrationIsIdempotent() async throws {
        let first = try ConversationDatabase(url: storeURL)
        let conversation = Conversation(title: "Kept", createdAt: .now, updatedAt: .now)
        try await first.insert(conversation)
        let afterInsert = try await first.conversations()
        XCTAssertEqual(afterInsert.count, 1)

        // Second open over the same file — the migration runner must be a no-op.
        let second = try ConversationDatabase(url: storeURL)
        let survived = try await second.conversations()
        XCTAssertEqual(survived.count, 1, "re-opening must not wipe or duplicate")
        XCTAssertEqual(survived.first?.title, "Kept")

        // A third open, for good measure — still exactly one row, no throw.
        let third = try ConversationDatabase(url: storeURL)
        let afterThird = try await third.conversations()
        XCTAssertEqual(afterThird.count, 1)
    }

    /// §8 — `foreign_keys` is OFF by default in raw SQLite3, and E7 depends on it.
    func testForeignKeysPragmaIsOn() async throws {
        let database = try ConversationDatabase(url: storeURL)
        // Proven behaviourally: an orphan insert must be refused.
        let orphan = PersistedMessage(
            id: UUID(),
            conversationID: UUID(),          // no such conversation
            role: .user,
            content: "orphan",
            createdAt: .now,
            sequence: 0,
            status: .complete)
        do {
            try await database.insert(orphan)
            XCTFail("insert with a dangling conversation_id should violate the FK")
        } catch {
            // expected
        }
        let counts = try await database.counts()
        XCTAssertEqual(counts.messages, 0)
    }

    // MARK: - Cascade

    /// E7 — deleting a conversation leaves no orphan messages or telemetry.
    func testDeleteCascades() async throws {
        let database = try ConversationDatabase(url: storeURL)
        let conversation = Conversation(title: "Doomed", createdAt: .now, updatedAt: .now)
        try await database.insert(conversation)

        let messageID = UUID()
        try await database.insert(PersistedMessage(
            id: messageID,
            conversationID: conversation.id,
            role: .assistant,
            content: "hello",
            createdAt: .now,
            sequence: 0,
            status: .streaming))
        try await database.finishMessage(
            id: messageID,
            content: "hello there",
            status: .complete,
            telemetry: MessageTelemetry(
                messageID: messageID, modelID: "m", engine: "mlx",
                ttftMs: 12, tokensPerSecond: 40, contextUsed: 20, contextCapacity: 32768,
                promptTokens: 8, tokensOut: 12, finishReason: "stop"),
            conversationID: conversation.id,
            touchedAt: .now)

        var counts = try await database.counts()
        XCTAssertEqual(counts.messages, 1)
        XCTAssertEqual(counts.telemetry, 1)

        try await database.deleteConversation(id: conversation.id)

        counts = try await database.counts()
        XCTAssertEqual(counts.conversations, 0)
        XCTAssertEqual(counts.messages, 0, "messages must cascade")
        XCTAssertEqual(counts.telemetry, 0, "telemetry must cascade")

        let orphans = try await database.orphanCounts()
        XCTAssertEqual(orphans.messages, 0)
        XCTAssertEqual(orphans.telemetry, 0)
    }

    // MARK: - Crash recovery

    /// E5 — a row left `streaming` is a crash artifact; the launch sweep reclaims it.
    @MainActor
    func testLaunchSweepReclaimsInterruptedMessages() async throws {
        let crashed = try ConversationDatabase(url: storeURL)
        let conversation = Conversation(title: "Interrupted", createdAt: .now, updatedAt: .now)
        try await crashed.insert(conversation)
        try await crashed.insert(PersistedMessage(
            id: UUID(),
            conversationID: conversation.id,
            role: .assistant,
            content: "half a rep",
            createdAt: .now,
            sequence: 0,
            status: .streaming))       // process dies here

        // Relaunch.
        let store = ConversationStore(url: storeURL)
        await store.start()
        XCTAssertEqual(store.reclaimedOnLaunch, 1)

        let counts = await store.counts()
        XCTAssertEqual(counts.streaming, 0, "no row may remain 'streaming' after a launch sweep")

        let messages = await store.messages(in: conversation.id)
        XCTAssertEqual(messages.first?.status, .failed)
        XCTAssertEqual(messages.first?.content, "half a rep", "buffered content is kept, not discarded")

        // And it must not render as a live stream — no phantom empty bubble.
        let display = try XCTUnwrap(messages.first.flatMap(ChatMessage.init))
        XCTAssertFalse(display.isStreaming)
        XCTAssertEqual(display.status, .failed)
        XCTAssertEqual(display.text, "half a rep", "buffered content is shown as-is")
    }

    /// A turn killed before any content was written must explain itself rather than
    /// render as an unexplained empty bubble (E5).
    @MainActor
    func testInterruptedEmptyMessageRendersAnExplanation() async throws {
        let crashed = try ConversationDatabase(url: storeURL)
        let conversation = Conversation(title: "Killed", createdAt: .now, updatedAt: .now)
        try await crashed.insert(conversation)
        try await crashed.insert(PersistedMessage(
            id: UUID(), conversationID: conversation.id, role: .assistant,
            content: "",                       // no tokens had been flushed yet
            createdAt: .now, sequence: 0, status: .streaming))

        let store = ConversationStore(url: storeURL)
        await store.start()
        let messages = await store.messages(in: conversation.id)
        let display = try XCTUnwrap(messages.first.flatMap(ChatMessage.init))

        XCTAssertEqual(display.status, .failed)
        XCTAssertFalse(display.isStreaming)
        XCTAssertFalse(display.text.isEmpty, "an empty failed turn must not render blank")
    }

    // MARK: - Write policy

    /// §4.5 — user row complete on send; assistant row streaming, then one commit.
    @MainActor
    func testStreamingWritePolicy() async throws {
        let store = ConversationStore(url: storeURL)
        await store.start()

        let created = await store.createConversation(title: "Policy")
        let conversation = try XCTUnwrap(created)
        let userID = UUID(), assistantID = UUID()

        await store.appendUserMessage("hi", id: userID, to: conversation.id)
        await store.beginAssistantMessage(id: assistantID, in: conversation.id)

        var mid = await store.messages(in: conversation.id)
        XCTAssertEqual(mid.map(\.status), [.complete, .streaming])
        XCTAssertEqual(mid.last?.content, "", "assistant row starts empty — no per-token writes")

        var accumulator = TelemetryAccumulator()
        accumulator.apply(.firstToken(ttft: .milliseconds(230)))
        accumulator.apply(.throughput(tokensPerSecond: 68))
        accumulator.apply(.context(used: 40, capacity: 32768))
        accumulator.apply(.completed(GenerationSummary(
            promptTokens: 9, generatedTokens: 31, tokensPerSecond: 67.4,
            promptTokensPerSecond: 300, timeToFirstToken: .milliseconds(228),
            totalTime: .milliseconds(700), stopReason: "stop")))

        await store.finishAssistantMessage(
            id: assistantID,
            in: conversation.id,
            content: "hello!",
            status: .complete,
            telemetry: accumulator.record(messageID: assistantID, modelID: "bonsai", engine: "mlx"))

        mid = await store.messages(in: conversation.id)
        XCTAssertEqual(mid.map(\.status), [.complete, .complete])
        XCTAssertEqual(mid.last?.content, "hello!")

        let storedTelemetry = await store.telemetry(for: assistantID)
        let telemetry = try XCTUnwrap(storedTelemetry)
        XCTAssertEqual(telemetry.promptTokens, 9)
        XCTAssertEqual(telemetry.tokensOut, 31)
        XCTAssertEqual(telemetry.finishReason, "stop")
        XCTAssertEqual(telemetry.contextCapacity, 32768)
        XCTAssertEqual(telemetry.schemaVersion, MessageTelemetry.currentSchemaVersion)
        XCTAssertNil(telemetry.extra, "the envelope exists but is unused this session")

        // Conversation list reflects the turn.
        XCTAssertEqual(store.conversations.first?.messageCount, 2)
    }

    /// A cancelled turn keeps whatever was buffered and writes no telemetry row.
    @MainActor
    func testCancelledTurnPersistsBufferAndNoTelemetry() async throws {
        let store = ConversationStore(url: storeURL)
        await store.start()
        let created = await store.createConversation(title: "Cancelled")
        let conversation = try XCTUnwrap(created)
        let assistantID = UUID()
        await store.beginAssistantMessage(id: assistantID, in: conversation.id)
        await store.finishAssistantMessage(
            id: assistantID, in: conversation.id,
            content: "partial…", status: .cancelled, telemetry: nil)

        let messages = await store.messages(in: conversation.id)
        XCTAssertEqual(messages.first?.status, .cancelled)
        XCTAssertEqual(messages.first?.content, "partial…")
        let counts = await store.counts()
        XCTAssertEqual(counts.telemetry, 0)
        XCTAssertEqual(counts.streaming, 0)
    }

    // MARK: - Ordering

    /// `sequence`, not `created_at` — two messages can share a sub-ms timestamp.
    func testOrderingUsesSequenceNotTimestamp() async throws {
        let database = try ConversationDatabase(url: storeURL)
        let conversation = Conversation(title: "Order", createdAt: .now, updatedAt: .now)
        try await database.insert(conversation)

        let sharedInstant = Date()
        for index in 0..<5 {
            let sequence = try await database.nextSequence(in: conversation.id)
            XCTAssertEqual(sequence, index)
            try await database.insert(PersistedMessage(
                id: UUID(),
                conversationID: conversation.id,
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "m\(index)",
                createdAt: sharedInstant,     // identical timestamps on purpose
                sequence: sequence,
                status: .complete))
        }

        let messages = try await database.messages(in: conversation.id)
        XCTAssertEqual(messages.map(\.content), ["m0", "m1", "m2", "m3", "m4"])
    }

    // MARK: - Titling

    func testAutoTitle() {
        XCTAssertEqual(
            Conversation.autoTitle(from: "  What is the capital of France?  "),
            "What is the capital of France?")
        XCTAssertEqual(
            Conversation.autoTitle(from: "one two three four five six seven eight"),
            "one two three four five six…")
        XCTAssertEqual(Conversation.autoTitle(from: "   "), "New conversation")
    }
}

/// §4.3/§4.4 — the accumulator is the only thing that turns a stream of Seam-1
/// enum cases into one telemetry row.
final class TelemetryAccumulatorTests: XCTestCase {

    private func summary(stopReason: String = "stop") -> GenerationSummary {
        GenerationSummary(
            promptTokens: 11,
            generatedTokens: 42,
            tokensPerSecond: 68.3,
            promptTokensPerSecond: 410,
            timeToFirstToken: .milliseconds(231),
            totalTime: .milliseconds(850),
            stopReason: stopReason)
    }

    func testAccumulatesAcrossEventsAndCompletes() {
        var accumulator = TelemetryAccumulator()
        XCTAssertFalse(accumulator.isComplete)

        accumulator.apply(.lifecycle(.generating))
        accumulator.apply(.firstToken(ttft: .milliseconds(240)))
        accumulator.apply(.throughput(tokensPerSecond: 65))
        accumulator.apply(.context(used: 53, capacity: 32768))
        XCTAssertFalse(accumulator.isComplete, "only .completed may finish a row")

        accumulator.apply(.completed(summary()))
        XCTAssertTrue(accumulator.isComplete)

        let record = accumulator.record(messageID: UUID(), modelID: "bonsai", engine: "mlx")
        XCTAssertEqual(record.contextUsed, 53)
        XCTAssertEqual(record.contextCapacity, 32768)
        // .completed is authoritative where it overlaps the incremental events —
        // mirroring ChatViewModel.apply so the store and metrics bar cannot diverge.
        XCTAssertEqual(record.tokensPerSecond ?? 0, 68.3, accuracy: 0.001)
        XCTAssertEqual(record.ttftMs ?? 0, 231, accuracy: 0.5)
    }

    /// The headline §4.4 result: all three "unfillable" columns are fillable.
    func testPredictedGapsAreActuallyPopulated() {
        var accumulator = TelemetryAccumulator()
        accumulator.apply(.completed(summary(stopReason: "maxTokens")))
        let record = accumulator.record(messageID: UUID(), modelID: "bonsai", engine: "mlx")

        XCTAssertEqual(record.promptTokens, 11, "GenerationSummary.promptTokens")
        XCTAssertEqual(record.tokensOut, 42, "GenerationSummary.generatedTokens")
        XCTAssertEqual(record.finishReason, "maxTokens", "GenerationSummary.stopReason")
    }

    /// Regression: telemetry and generation are two independent streams, so the
    /// telemetry `.completed` may never arrive before the turn ends. Closing from the
    /// generation stream's summary must still yield a complete row — previously this
    /// race dropped the `message_telemetry` row entirely.
    func testCompletesFromGenerationSummaryWithoutTelemetryCompleted() {
        var accumulator = TelemetryAccumulator()
        // Only the incremental events land; `.completed` never reaches the accumulator
        // via the telemetry stream.
        accumulator.apply(.lifecycle(.generating))
        accumulator.apply(.firstToken(ttft: .milliseconds(97)))
        XCTAssertFalse(accumulator.isComplete)

        accumulator.complete(with: summary(), contextCapacity: 32768)

        XCTAssertTrue(accumulator.isComplete)
        let record = accumulator.record(messageID: UUID(), modelID: "bonsai", engine: "mlx")
        XCTAssertEqual(record.promptTokens, 11)
        XCTAssertEqual(record.tokensOut, 42)
        XCTAssertEqual(record.finishReason, "stop")
        // Derived exactly as the engine defines it: prompt + generated.
        XCTAssertEqual(record.contextUsed, 53)
        XCTAssertEqual(record.contextCapacity, 32768)
    }

    /// When the telemetry stream *did* deliver `.context`, that value wins — the
    /// derivation is a fallback, not an override.
    func testDeliveredContextIsNotOverwrittenByDerivation() {
        var accumulator = TelemetryAccumulator()
        accumulator.apply(.context(used: 999, capacity: 4096))
        accumulator.complete(with: summary(), contextCapacity: 32768)

        let record = accumulator.record(messageID: UUID(), modelID: "b", engine: "mlx")
        XCTAssertEqual(record.contextUsed, 999)
        XCTAssertEqual(record.contextCapacity, 4096)
    }

    func testResetClearsEverything() {
        var accumulator = TelemetryAccumulator()
        accumulator.apply(.context(used: 5, capacity: 10))
        accumulator.apply(.completed(summary()))
        accumulator.reset()

        XCTAssertFalse(accumulator.isComplete)
        XCTAssertNil(accumulator.contextUsed)
        XCTAssertNil(accumulator.promptTokens)
        XCTAssertNil(accumulator.finishReason)
    }
}
