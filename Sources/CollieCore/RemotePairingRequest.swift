import Foundation

/// What the Mac app shows when a phone asks to pair (remote API spec §2): "Parear ‘name’ (model, via address)?
/// Código 482 913 — Parear / Recusar", answered with `admin.remote.pair.confirm` before `deadline`.
public struct RemotePairingRequest: Codable, Sendable, Equatable {
    public var pairingId: UUID
    public var name: String
    public var model: String
    public var address: String
    /// lan | tailscale
    public var via: String
    public var code: String
    public var deadline: Date
    public init(pairingId: UUID, name: String, model: String, address: String, via: String, code: String, deadline: Date) {
        self.pairingId = pairingId; self.name = name; self.model = model; self.address = address; self.via = via
        self.code = code; self.deadline = deadline
    }
}
