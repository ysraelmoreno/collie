import CollieCore
import CollieProtocol

/// One heavy job at a time on the daemon's data and staging (backup, import, the updater's download): the next one gets
/// `conflict` with what runs (spec 2026-11-17 §5).
actor Maintenance {
    private(set) var active: String?

    func enter(_ what: String) throws(ProtocolError) {
        if let active { throw ProtocolError(code: .conflict, message: tr("\(active) em andamento", "\(active) in progress")) }
        active = what
    }

    /// Only the holder releases it.
    func leave(_ what: String) { if active == what { active = nil } }
}
