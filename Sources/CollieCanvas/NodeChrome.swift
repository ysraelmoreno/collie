import CoreGraphics
import CollieCore

/// A node's state as its title bar shows it: a dot plus this text (state is never shown by color alone).
public enum NodeStatus: Equatable, Sendable {
    case idle, working, attention, stopped(Int32?)

    /// An exit frame wins over the badge; `.stopped` without one means the terminal died with a previous daemon.
    public init(badge: StatusBadge?, exitCode: Int32?) {
        if exitCode != nil || badge == .stopped { self = .stopped(exitCode); return }
        switch badge ?? .idle {
        case .working: self = .working
        case .attention: self = .attention
        default: self = .idle
        }
    }

    public var text: String? {
        switch self {
        case .idle: nil
        case .working: "trabalhando"
        case .attention: "espera você"
        case .stopped(let c): c.map { "encerrado (código \($0))" } ?? "encerrado"
        }
    }
}

/// Leash stroke: agent↔agent solid, agent↔panel dashed [2, 6]; 2 pt, 3 pt when selected.
public struct LeashStyle: Equatable, Sendable {
    public var width: CGFloat, dash: [CGFloat], toPanel: Bool
    public init(width: CGFloat, dash: [CGFloat], toPanel: Bool) { self.width = width; self.dash = dash; self.toPanel = toPanel }
    public init(toPanel: Bool, selected: Bool) { self.init(width: selected ? 3 : 2, dash: toPanel ? [2, 6] : [], toPanel: toPanel) }
}
