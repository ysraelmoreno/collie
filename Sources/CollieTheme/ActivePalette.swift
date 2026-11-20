import SwiftUI
import os

public extension Notification.Name {
    /// Posted on the main thread after the active palettes (or the app appearance) changed. Views that keep fixed
    /// colors (layer colors, terminal colors, web pages) observe it and resolve their colors again.
    static let collieThemeChanged = Notification.Name("collie.themeChanged")
}

/// The dark and light palettes in use. Readable from any thread; replaced at run time by `set`/`reset`.
/// `Palette.dark`/`.light` stay the built-in ones.
public enum ActivePalette {
    private struct State: Sendable { var dark = Palette.dark, light = Palette.light }
    private static let state = OSAllocatedUnfairLock(initialState: State())

    public static var dark: Palette { state.withLock { $0.dark } }
    public static var light: Palette { state.withLock { $0.light } }

    public static func set(dark: Palette, light: Palette) { state.withLock { $0 = State(dark: dark, light: light) } }
    public static func reset() { state.withLock { $0 = State() } }
}

private struct ThemeRevisionKey: EnvironmentKey { static let defaultValue = 0 }

public extension EnvironmentValues {
    /// Bumped on every theme swap. A SwiftUI view that reads it is evaluated again when the theme changes,
    /// so its `Color(nsColor:)` values resolve again. Set on the root without changing the root's `id`.
    var collieThemeRevision: Int {
        get { self[ThemeRevisionKey.self] }
        set { self[ThemeRevisionKey.self] = newValue }
    }
}
