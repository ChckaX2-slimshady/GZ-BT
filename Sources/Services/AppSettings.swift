import Foundation
import Observation

/// App-level settings. Session 1 owns exactly one real setting: the global
/// Spectre toggle (default OFF). Persisted in `UserDefaults` — this is app
/// configuration, not the out-of-scope chat persistence.
@MainActor
@Observable
final class AppSettings {
    var spectreEnabled: Bool {
        didSet { UserDefaults.standard.set(spectreEnabled, forKey: Self.spectreKey) }
    }

    private static let spectreKey = "settings.spectreEnabled"

    init() {
        spectreEnabled = UserDefaults.standard.bool(forKey: Self.spectreKey)
    }
}
