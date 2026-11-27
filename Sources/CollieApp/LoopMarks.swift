import SwiftUI
import CollieTheme

// ponytail: moved from the old context panel (gone in L3); the floating loop (`LoopFloat`) and the Laços modal draw them.

/// A loop's thin progress bar (decorative: the card's label says the count). Animates its fill unless Reduzir movimento is on.
struct LoopProgressBar: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            Capsule().fill(Color.collieBorder)
                .overlay(alignment: .leading) { Capsule().fill(Color.collieSecondary).frame(width: g.size.width * min(max(fraction, 0), 1)) }
        }
        .frame(height: 4)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: fraction)
        .accessibilityHidden(true)
    }
}

/// A loop task's state mark: ✓ done, ◐ running (turns, unless Reduzir movimento is on), – deferred, ○ open (decorative:
/// the row's accessibility label says the state).
struct LoopStateIcon: View {
    let state: LoopSection.State
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turn = false

    var body: some View {
        let spins = state == .running && !reduceMotion
        Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(color).frame(width: 14)
            .rotationEffect(.degrees(spins && turn ? 360 : 0))
            .animation(spins ? .linear(duration: 1.6).repeatForever(autoreverses: false) : nil, value: turn)
            .onAppear { turn = true }
            .accessibilityHidden(true)
    }
    private var symbol: String {
        switch state { case .done: "checkmark"; case .running: "circle.lefthalf.filled"; case .deferred: "minus"; case .open: "circle" }
    }
    private var color: Color {
        switch state { case .done: .collieSecondary; case .running: .collieAccent; case .deferred: .collieAttention; case .open: .collieMuted }
    }
}
