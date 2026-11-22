import Foundation

/// The frame a Device panel draws around the screen, by device type (PRD D1, docs/superpowers/roadmap/2026-11-22-device-molduras).
/// Stored by the daemon as the panel's `state["frame"]`; a panel without it is `bare`.
public enum DeviceFrame {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case phone, fold, tablet, island, classic, ipad, bare
    }
}
