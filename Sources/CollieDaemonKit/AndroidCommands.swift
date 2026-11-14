import Foundation
import CollieProtocol

extension CommandRouter {
    /// `android.*`: the app's alone (admin token, not from a terminal). `install` replies `{job}` at once; the rest of the
    /// job is read with `android.status`.
    func androidCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        try await adminOnly(r, peer: peer)
        switch r.command {
        case "android.status": return try json(await android.status())
        case "android.licenses": return try json(await android.licenses())
        case "android.install":
            var ids: [String] = []
            switch r.args["accept"] {
            case .array(let a)?: ids = a.compactMap { if case .string(let s) = $0 { s } else { nil } }
            case .string(let s)?: ids = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }   // ponytail: also a comma string
            default: break
            }
            return .object(["job": try json(await android.start(accept: ids))])
        case "android.cancel":
            await android.cancel()
            return .object([:])
        default:
            throw ProtocolError(code: .internal, message: "'\(r.command)' not implemented yet")
        }
    }

    private func json<T: Encodable>(_ v: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(v))
    }
}
