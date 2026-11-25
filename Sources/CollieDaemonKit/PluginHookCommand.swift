import Foundation
import CollieCore
import CollieProtocol

/// `plugin.hook` (terminal only): an agent event for the plug-ins' helpers. Always ok; any failure is `{}`.
/// Claude: PostToolUse (`edit`) and Stop (`stop`). Cursor (D1): `preToolUse`/`postToolUse` payloads under `edit`; a Cursor turn
/// ends through `cursorStop` (no Stop hook), and a block there is one continuation prompt, since the turn is already over.
extension CommandRouter {
    func pluginHook(_ r: Request, from tid: UUID) async -> JSONValue {
        let none = JSONValue.object([:])
        guard let me = ws.terminals.first(where: { $0.id == tid }),
              !reviewerHooksBare(me),   // F2 Z1: no plug-in guide (text from files in reach) into a reviewer
              let event = PluginHooks.Event(rawValue: str(r, "event") ?? ""),
              let payload = str(r, "payload").map({ Data($0.utf8) }), payload.count <= PluginHooks.maxInput else { return none }
        let files: [String]
        if me.preset == .claude {
            switch event {
            case .edit:
                guard let project = try? await projectRoot(of: me) else { return none }
                files = PluginHooks.editedFiles(toolPayload: payload, project: project)
                pluginTurn.add(files, to: tid)
            case .stop:
                let written = pluginTurn.take(tid)
                files = PluginTurn.isContinued(payload) ? [] : written   // a continued Stop (a plug-in blocked it once) never runs them again
            }
        } else if CommandRouter.agentName(me) == "cursor", event == .edit, let phase = PluginHooks.cursorToolPhase(payload) {
            await asks.cursorTool(tid, running: phase == .pre)   // mid-turn until its post: idle must not close an ask in a long tool
            guard phase == .post, let project = try? await projectRoot(of: me) else { return none }
            files = PluginHooks.editedFiles(toolPayload: payload, project: project)
            pluginTurn.add(files, to: tid)
        } else { return none }
        return Self.verdictJSON(await runPlugins(event, files: files, me: me, agent: CommandRouter.agentName(me)))
    }

    func noteTurnFiles(_ files: [String], _ tid: UUID) { pluginTurn.add(files, to: tid) }

    /// The end of a Cursor turn (an ask saw it go idle): the plug-ins' `stop` with the turn's files. A block is typed once as
    /// a prompt; the continuation's own end runs nothing. `guide` is ignored, as for Claude. `run` replaces the helpers (tests).
    func cursorStop(_ tid: UUID, run: (([String]) async -> PluginHooks.Verdict)? = nil) async {
        guard let me = ws.terminals.first(where: { $0.id == tid }) else { return }
        let files = pluginTurn.cursorEnd(tid)
        guard !files.isEmpty else { return }
        let v: PluginHooks.Verdict
        if let run { v = await run(files) } else { v = await runPlugins(.stop, files: files, me: me, agent: "cursor") }
        guard let reason = PluginHooks.claudeStopReason(v) else { return }
        pluginTurn.continued(tid)
        try? await asks.inject(to: tid, prompt: reason, afterQuiet: true)
    }

    private func runPlugins(_ event: PluginHooks.Event, files: [String], me: TerminalRecord, agent: String) async -> PluginHooks.Verdict {
        guard !files.isEmpty, let project = try? await projectRoot(of: me) else { return PluginHooks.Verdict() }
        let plugins = await PluginHookRunner.candidates(self.plugins, event: event)
        return await PluginHookRunner.run(event: event, files: files, project: project, agent: agent,
                                          paddock: ws.paddocks.first { $0.id == me.paddockId }?.name ?? "",
                                          plugins: plugins, dataRoot: config.paths.root.appendingPathComponent("plugins-data"))
    }

    private static func verdictJSON(_ v: PluginHooks.Verdict) -> JSONValue {
        var out: [String: JSONValue] = [:]
        if let g = v.guide { out["guide"] = .string(g) }
        if let b = v.block { out["block"] = .string(b) }
        return .object(out)
    }
}
