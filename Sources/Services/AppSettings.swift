import Foundation
import Observation

/// App-level settings. The global Spectre toggle (default OFF) is the primary
/// switch; the experimental module set sits beneath it and is only consulted
/// while it is on. Persisted in `UserDefaults` — this is app configuration, not
/// the out-of-scope chat persistence.
@MainActor
@Observable
final class AppSettings {
    var spectreEnabled: Bool {
        didSet { UserDefaults.standard.set(spectreEnabled, forKey: Self.spectreKey) }
    }

    /// Which experimental modules the user has *asked* for. Requested is not
    /// effective: `SpectreLabRegistry.resolve` closes dependencies and refuses
    /// anything unbuilt, so this set is intent, not capability.
    ///
    /// Stored as a sorted string array rather than a `Set` because `UserDefaults`
    /// carries property-list types only.
    var spectreModules: Set<String> {
        didSet {
            UserDefaults.standard.set(spectreModules.sorted(), forKey: Self.modulesKey)
        }
    }

    private static let spectreKey = "settings.spectreEnabled"
    private static let modulesKey = "settings.spectreModules"

    init() {
        spectreEnabled = UserDefaults.standard.bool(forKey: Self.spectreKey)
        // First launch has no stored set — fall back to the registry's defaults
        // rather than an empty one, so the substrate is on when Spectre is.
        if let stored = UserDefaults.standard.array(forKey: Self.modulesKey) as? [String] {
            spectreModules = Set(stored)
        } else {
            spectreModules = SpectreLabRegistry.defaults
        }
    }
}
