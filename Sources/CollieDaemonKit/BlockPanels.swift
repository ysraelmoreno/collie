import Foundation
import CollieCore
import CollieProtocol

/// Terminal chat, slice 4 ("Anexar como painel"): a collie-ui block opened as a `uiblock` panel in the terminal's
/// paddock. With a `source` naming an approved app do cercado and one of its plain GET commands, the panel is linked
/// to it (↻ and the optional interval call that command again); anything else is a snapshot of the block's JSON.
extension CommandRouter {
    /// The app and command a source names, if it may be called on its own: the app approved in `paddock`, an `http`
    /// command with GET and no `confirm` (a refresh must never change anything or ask the user).
    func linkable(_ s: UIBlockSource, paddock: UUID?) throws(ProtocolError) -> (PluginManifest, PluginManifest.Command) {
        guard let pid = paddock, let m = appManifests[pid]?[s.app] else {
            throw ProtocolError(code: .unavailable, message: "o app '\(s.app)' não está aprovado neste cercado")
        }
        guard let c = m.commands.first(where: { $0.name == s.command }), c.runs == "http" else {
            throw ProtocolError(code: .notFound, message: "o app '\(s.app)' não tem o comando http '\(s.command)'")
        }
        guard c.http?.method == "GET", !c.confirm else {
            throw ProtocolError(code: .unauthorized, message: "só um comando GET sem confirmação atualiza o painel sozinho")
        }
        return (m, c)
    }

    /// `admin.block.attach`, `admin.block.refresh` (the app only).
    func adminBlock(_ r: Request) async throws -> JSONValue {
        if r.command == "admin.block.refresh" {
            guard let pid = str(r, "panel").flatMap(UUID.init(uuidString:)), let p = ws.panels.first(where: { $0.id == pid }), p.pluginId == "uiblock" else {
                throw ProtocolError(code: .notFound, message: "no block panel '\(str(r, "panel") ?? "")'")
            }
            guard case .string(let app)? = p.state["app"], case .string(let command)? = p.state["command"] else {
                throw ProtocolError(code: .invalidArgs, message: "painel de instantâneo: não há fonte para atualizar")
            }
            var params: [String: JSONValue] = [:]
            if case .object(let o)? = p.state["params"] { params = o }
            let (m, c) = try linkable(UIBlockSource(app: app, command: command, params: params, refresh: nil), paddock: p.paddockId)
            // data from the app: the panel draws it as a block, never as text for an agent
            return .object(["data": try await PaddockApps.call(m, c, args: params)])
        }
        guard let tid = UUID(uuidString: try need(r, "terminal")), let t = ws.terminals.first(where: { $0.id == tid }) else {
            throw ProtocolError(code: .notFound, message: "no terminal '\(str(r, "terminal") ?? "")'")
        }
        let json = try need(r, "json")
        guard UIBlock.parse(json) != nil else { throw ProtocolError(code: .invalidArgs, message: "bloco collie-ui inválido") }
        var state: [String: JSONValue] = ["json": .string(json)]
        var why: String?
        if let s = UIBlockSource.parse(json) {
            do throws(ProtocolError) {
                _ = try linkable(s, paddock: t.paddockId)
                state["app"] = .string(s.app); state["command"] = .string(s.command); state["params"] = .object(s.params)
                if let n = s.refresh { state["refresh"] = .number(Double(n)) }
            } catch { why = error.message }
        }
        let name = freePanelName("bloco")
        try reserve(name); defer { launching.remove(name.lowercased()) }
        let (p, _, _) = try await openPanel(name: name, pluginId: "uiblock", placement: .canvas, state: state, file: nil, paddock: t.paddockId, caller: nil)
        var o: [String: JSONValue] = ["panel": .string(p.name), "id": .string(p.id.uuidString), "linked": .bool(state["app"] != nil)]
        if let why { o["why"] = .string(why) }
        return .object(o)
    }
}
