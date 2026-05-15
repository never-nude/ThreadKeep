import Foundation

/// The top-level UI state of ThreadKeep.
///
/// Previously RootView managed this with five separate `@State` booleans and a polling loop.
/// Centralizing here lets the view model drive transitions and lets RootView be a clean switch.
enum AppFlow: Equatable, Sendable {
    /// Bootstrapping: loading the library before showing the welcome view.
    case determining
    /// Welcome view shown when ThreadKeep opens.
    case welcome
    /// Normal operation after the user continues into the library.
    case library
}
