import XCTest
@testable import GZBT

/// A controllable `InferenceEngine` whose Seam-1 stream the test drives directly.
/// Lets the hub be exercised through the **real** subscription path — no access
/// control is loosened on `TelemetryHub` to reach into it (CLAUDE.md Gotcha #4).
/// Generation is not implemented: these tests are about telemetry only.
actor FakeInferenceEngine: InferenceEngine {
    nonisolated let telemetry: AsyncStream<TelemetryEvent>
    private nonisolated let tele: AsyncStream<TelemetryEvent>.Continuation

    init() {
        (telemetry, tele) = AsyncStream<TelemetryEvent>.makeStream()
    }

    /// Emit one Seam-1 event, as the MLX engine does from inside generation.
    nonisolated func emit(_ event: TelemetryEvent) { tele.yield(event) }
    nonisolated func finish() { tele.finish() }

    func load(_ model: ResolvedModel, progress: (@Sendable (Double) -> Void)?) async throws {}
    func unload() async {}
    func cancel() async {}
    func generate(_ request: GenerationRequest) -> AsyncStream<GenerationEvent> {
        AsyncStream { $0.finish() }
    }
}

/// S2.5 — the hub is the single Seam-1 consumer and the fan-out point. These run
/// everywhere: no model, no MLX, no device.
@MainActor
final class TelemetryHubTests: XCTestCase {

    private func summary(
        promptTokens: Int = 34,
        generatedTokens: Int = 6,
        tokensPerSecond: Double = 76.3,
        stopReason: String = "stop"
    ) -> GenerationSummary {
        GenerationSummary(
            promptTokens: promptTokens,
            generatedTokens: generatedTokens,
            tokensPerSecond: tokensPerSecond,
            promptTokensPerSecond: 410,
            timeToFirstToken: .milliseconds(225),
            totalTime: .milliseconds(700),
            stopReason: stopReason)
    }

    /// Emit a full turn's worth of Seam-1 events and wait for the hub to drain them.
    private func emitFullTurn(_ engine: FakeInferenceEngine, _ hub: TelemetryHub) async {
        engine.emit(.lifecycle(.generating))
        engine.emit(.firstToken(ttft: .milliseconds(225)))
        engine.emit(.throughput(tokensPerSecond: 76.3))
        engine.emit(.context(used: 40, capacity: 32768))
        engine.emit(.completed(summary()))
        await drain(hub, untilEvents: 5)
    }

    /// The stream is consumed asynchronously; poll rather than guess a sleep.
    private func drain(_ hub: TelemetryHub, untilEvents count: Int) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while hub.recentEvents.count < count && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Subscription

    /// Started from the composition root, the hub observes without any view existing —
    /// the reason the subscription moved out of `ChatView.task`. Spectre must render
    /// live even if the user never opens Chat.
    func testObservesWithoutAnyViewPresent() async {
        let engine = FakeInferenceEngine()
        let hub = TelemetryHub()
        hub.start(engine)
        defer { hub.stop() }

        XCTAssertTrue(hub.isObserving)
        engine.emit(.lifecycle(.loaded))
        await drain(hub, untilEvents: 1)

        XCTAssertEqual(TelemetryHub.describe(hub.lifecycle), "ready")
    }

    /// `start` is called from the composition root; a second call must not open a
    /// second iterator over the same stream.
    func testStartIsIdempotent() async {
        let engine = FakeInferenceEngine()
        let hub = TelemetryHub()
        hub.start(engine)
        hub.start(engine)
        hub.start(engine)
        defer { hub.stop() }

        engine.emit(.throughput(tokensPerSecond: 50))
        await drain(hub, untilEvents: 1)

        XCTAssertEqual(hub.recentEvents.count, 1, "one event must be recorded exactly once")
        XCTAssertEqual(hub.throughputSamples, [50])
    }

    // MARK: - Fan-out

    /// Two consumers both receive every event — the whole point. `AsyncStream` has one
    /// iterator, so a second `for await` would split the stream non-deterministically.
    func testFanOutDeliversEveryEventToEverySink() async {
        let engine = FakeInferenceEngine()
        let hub = TelemetryHub()
        hub.start(engine)
        defer { hub.stop() }

        var first: [String] = []
        var second: [String] = []
        hub.addSink { first.append(Self.tag($0)) }
        hub.addSink { second.append(Self.tag($0)) }

        await emitFullTurn(engine, hub)

        let expected = ["lifecycle", "firstToken", "throughput", "context", "completed"]
        XCTAssertEqual(first, expected)
        XCTAssertEqual(second, expected, "the second consumer must not be starved")
    }

    func testRemovedSinkStopsReceiving() async {
        let engine = FakeInferenceEngine()
        let hub = TelemetryHub()
        hub.start(engine)
        defer { hub.stop() }

        var seen: [String] = []
        let token = hub.addSink { seen.append(Self.tag($0)) }

        engine.emit(.throughput(tokensPerSecond: 10))
        await drain(hub, untilEvents: 1)
        hub.removeSink(token)
        engine.emit(.throughput(tokensPerSecond: 20))
        await drain(hub, untilEvents: 2)

        XCTAssertEqual(seen, ["throughput"])
    }

    // MARK: - Exit criterion

    /// **S2.5's exit criterion as a test.** Every readout the dashboard shows is
    /// populated from the five cases `TelemetryEvent` already has. Nothing is added.
    func testDashboardIsFullyPopulatedFromExistingSeamCasesOnly() async {
        let engine = FakeInferenceEngine()
        let hub = TelemetryHub()
        hub.start(engine)
        defer { hub.stop() }
        let vm = SpectreViewModel(telemetry: hub)

        XCTAssertFalse(vm.hasData)
        XCTAssertEqual(vm.ttft, "—")

        await emitFullTurn(engine, hub)

        XCTAssertTrue(vm.hasData)
        XCTAssertEqual(vm.lifecycleLabel, "generating")
        XCTAssertEqual(vm.ttft, "225 ms")
        XCTAssertEqual(vm.tokensPerSecond, "76.3")
        XCTAssertEqual(vm.context, "40 / 32768")
        XCTAssertEqual(vm.contextFraction ?? 0, 40.0 / 32768.0, accuracy: 0.0001)
        XCTAssertFalse(vm.samples.isEmpty, "the sparkline needs a series")

        // An "—" in any readout would mean the seam could not feed the dashboard,
        // which is precisely the finding S2.5 exists to detect.
        for (name, value) in [
            ("ttft", vm.ttft), ("tok/s", vm.tokensPerSecond), ("context", vm.context),
            ("prompt", vm.promptTokens), ("generated", vm.generatedTokens),
            ("stop", vm.finishReason), ("turns", vm.completedTurns), ("peak", vm.peakThroughput)
        ] {
            XCTAssertNotEqual(value, "—", "\(name) should be populated from Seam-1 alone")
        }
    }

    // MARK: - Bounds & robustness

    func testThroughputSamplesAreCapped() async {
        let engine = FakeInferenceEngine()
        let hub = TelemetryHub()
        hub.start(engine)
        defer { hub.stop() }

        let total = TelemetryHub.sampleLimit + 25
        for index in 0..<total { engine.emit(.throughput(tokensPerSecond: Double(index + 1))) }
        await drain(hub, untilEvents: TelemetryHub.eventLimit)

        XCTAssertEqual(hub.throughputSamples.count, TelemetryHub.sampleLimit)
        XCTAssertEqual(hub.throughputSamples.last, Double(total), "newest sample is kept")
    }

    func testEventLogIsCappedAndNewestFirst() async {
        let engine = FakeInferenceEngine()
        let hub = TelemetryHub()
        hub.start(engine)
        defer { hub.stop() }

        let total = TelemetryHub.eventLimit + 10
        for index in 0..<total { engine.emit(.throughput(tokensPerSecond: Double(index + 1))) }
        await drain(hub, untilEvents: TelemetryHub.eventLimit)

        XCTAssertEqual(hub.recentEvents.count, TelemetryHub.eventLimit)
        XCTAssertEqual(hub.recentEvents.first?.detail,
                       String(format: "%.1f tok/s", Double(total)),
                       "newest first")
    }

    func testFailedLifecycleIsSurfacedNotSwallowed() async {
        let engine = FakeInferenceEngine()
        let hub = TelemetryHub()
        hub.start(engine)
        defer { hub.stop() }
        let vm = SpectreViewModel(telemetry: hub)

        engine.emit(.lifecycle(.failed("simulator")))
        await drain(hub, untilEvents: 1)

        XCTAssertTrue(vm.isFailed)
        XCTAssertFalse(vm.isLive)
        XCTAssertEqual(vm.lifecycleLabel, "failed: simulator")
    }

    /// Zero and NaN must not poison the sparkline's min/max.
    func testDegenerateThroughputSamplesAreIgnored() async {
        let engine = FakeInferenceEngine()
        let hub = TelemetryHub()
        hub.start(engine)
        defer { hub.stop() }

        engine.emit(.throughput(tokensPerSecond: 0))
        engine.emit(.throughput(tokensPerSecond: .nan))
        engine.emit(.throughput(tokensPerSecond: 42))
        await drain(hub, untilEvents: 3)

        XCTAssertEqual(hub.throughputSamples, [42])
    }

    // MARK: - Helpers

    private static func tag(_ event: TelemetryEvent) -> String {
        switch event {
        case .lifecycle: "lifecycle"
        case .firstToken: "firstToken"
        case .throughput: "throughput"
        case .context: "context"
        case .completed: "completed"
        }
    }
}
