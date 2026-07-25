import Observation

/// Composition root. Holds the app's long-lived services and hands them to the
/// view tree through the environment. Grows over the session (ModelManager and
/// the inference engine arrive with Models/Chat); Session 1 starts with settings.
@MainActor
@Observable
final class AppEnvironment {
    let settings = AppSettings()
}
