import Foundation
import CollieCore
import CollieProtocol

/// `plugin.hook` (terminal only): a Claude Code event for the plug-ins' helpers. Always ok; any failure is `{}`.
extension CommandRouter {
    func pluginHook(_ r: Request, from tid: UUID) async -> JSONValue {
        let none = JSONValue.object([:])
        guard let me = ws.terminals.first(where: { $0.id == tid }), me.preset == .claude,   // Cursor/Codex: not this phase
              let event = PluginHooks.Event(rawValue: str(r, "event") ?? ""),
              let payload = str(r, "payload").map({ Data($0.utf8) }), payload.count <= PluginHooks.maxInput,
              let project = try? await projectRoot(of: me) else { return none }
        let files: [String]
        switch event {
        case .edit:
            files = PluginHooks.editedFiles(toolPayload: payload, project: project)
            pluginTurn.add(files, to: tid)
        case .stop:
            let written = pluginTurn.take(tid)
            files = PluginTurn.isContinued(payload) ? [] : written   // a continued Stop (a plug-in blocked it once) never runs them again
        }
        let plugins = await PluginHookRunner.candidates(self.plugins, event: event)
        let v = await PluginHookRunner.run(event: event, files: files, project: project, agent: "claude",
                                           paddock: ws.paddocks.first { $0.id == me.paddockId }?.name ?? "",
                                           plugins: plugins, dataRoot: config.paths.root.appendingPathComponent("plugins-data"))
        var out: [String: JSONValue] = [:]
        if let g = v.guide { out["guide"] = .string(g) }
        if let b = v.block { out["block"] = .string(b) }
        return .object(out)
    }
}
