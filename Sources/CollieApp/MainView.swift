/// What the main area of the Completa structure (Trilho) shows: the canvas or, in its place, Preferências.
enum MainView: Equatable { case canvas, preferences }

/// Which `MainView` is on screen. Never persisted: the app always opens on the canvas. No SwiftUI, so it is tested alone.
struct MainViewState: Equatable {
    private(set) var current = MainView.canvas
    var isPreferences: Bool { current == .preferences }
    mutating func show(_ view: MainView) { current = view }
    /// Leaves Preferências; on the canvas it changes nothing.
    mutating func back() { current = .canvas }
}
