import os

/// Shared `os.Logger` channels. Layer: **Utilities** — holds no state; `Logger` is a
/// value type over the unified logging system.
///
/// Channels are read back off-device with:
///   `xcrun devicectl device process launch --console …` (stdout/stderr), or
///   `log stream --predicate 'subsystem == "ai.gzbt.app"'` on macOS.
enum Log {
    private static let subsystem = "ai.gzbt.app"

    /// Persistence: store location, migrations, crash-artifact sweeps.
    static let store = Logger(subsystem: subsystem, category: "store")

    /// Seam-1 telemetry mirrored to the log for device runtime proof (gate item G1).
    static let telemetry = Logger(subsystem: subsystem, category: "telemetry")

    /// Model store: downloads, installs, deletions. Read back on-device with
    /// `log stream --predicate 'subsystem == "ai.gzbt.app"'` to tell an interrupted
    /// transfer apart from a network failure.
    static let models = Logger(subsystem: subsystem, category: "models")
}
