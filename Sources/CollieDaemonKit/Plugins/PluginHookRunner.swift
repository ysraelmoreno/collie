import Foundation
import CollieCore
import CollieProtocol

/// Runs the helpers of the plug-ins that declared an agent event (PRD G4): one sandboxed process per plug-in, in
/// parallel, 3 s for the lot. Any failure is silence (fail open) plus one log line with the id and the reason.
enum PluginHookRunner {
    static let deadline: Duration = .seconds(3)

    /// A loaded, enabled plug-in whose manifest declares `event`, with its installed folder.
    typealias Candidate = (manifest: PluginManifest, folder: URL)

    static func candidates(_ store: PluginStore, event: PluginHooks.Event) async -> [Candidate] {
        var out: [Candidate] = []
        for (m, _) in await store.loaded() where m.helper != nil && m.hookEvents.contains(event.rawValue) {
            if let f = await store.folder(of: m.id) { out.append((m, f)) }
        }
        return out
    }

    static func run(event: PluginHooks.Event, files: [String], project: URL, agent: String, paddock: String,
                    plugins: [Candidate], dataRoot: URL) async -> PluginHooks.Verdict {
        guard !files.isEmpty, !plugins.isEmpty else { return PluginHooks.Verdict() }
        let stdin = PluginHooks.eventJSON(event: event, project: project, files: files, agent: agent, paddock: paddock)
        let verdicts = await withTaskGroup(of: Answer?.self) { group in
            for p in plugins {
                group.addTask { await one(p, stdin: stdin, project: project, dataRoot: dataRoot) }
            }
            var all: [(plugin: String, PluginHooks.Verdict)] = []
            for await a in group { if let a { all.append((a.plugin, a.verdict)) } }
            return all
        }
        return PluginHooks.merge(verdicts, event: event)
    }

    private struct Answer: Sendable { var plugin: String; var verdict: PluginHooks.Verdict }

    private static func one(_ p: Candidate, stdin: Data, project: URL, dataRoot: URL) async -> Answer? {
        let id = p.manifest.id
        guard let rel = p.manifest.helper else { return nil }
        let helper = p.folder.appendingPathComponent(rel)
        let data = dataRoot.appendingPathComponent(id)
        do {
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { return skip(id, "pasta de dados") }
        let input = PluginHelperInput(helper: helper, pluginDir: p.folder, project: project, dataDir: data)
        let cmd = PluginHelperProfile.command(input, profile: PluginHelperProfile.render(input))
        let env = ["PATH": "/usr/bin:/bin", "HOME": data.path, "COLLIE_PLUGIN_DATA": data.path]
        do {
            let r = try await BoundedProcess.run(executable: cmd.executable, args: cmd.args, in: p.folder, env: env,
                                                 timeout: deadline, cap: PluginHooks.maxInput, stdin: stdin)
            guard r.status == 0 else { return skip(id, "exit \(r.status)") }
            guard !r.truncated else { return skip(id, "saída grande demais") }
            let said = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if said.isEmpty || said == "{}" { return nil }   // nothing to say
            guard let v = PluginHooks.verdict(stdout: r.stdoutData) else { return skip(id, "saída inválida") }
            return Answer(plugin: id, verdict: v)
        } catch {
            return skip(id, error.code == .timeout ? "estourou o prazo" : error.message)
        }
    }

    private static func skip(_ id: String, _ why: String) -> Answer? {
        FileHandle.standardError.write(Data("collied: plugin-hook: \(id): \(why)\n".utf8))
        return nil
    }
}

/// The files each Claude terminal wrote this turn (for the `stop` event): in memory, 200 at most, no repeats.
struct PluginTurn: Sendable {
    static let maxFiles = 200
    private var byTerminal: [UUID: [String]] = [:]

    mutating func add(_ files: [String], to t: UUID) {
        var turn = byTerminal[t] ?? []
        for f in files where turn.count < Self.maxFiles && !turn.contains(f) { turn.append(f) }
        byTerminal[t] = turn
    }
    /// The turn's files, once: the turn starts over.
    mutating func take(_ t: UUID) -> [String] { byTerminal.removeValue(forKey: t) ?? [] }
    mutating func drop(_ t: UUID) { byTerminal[t] = nil; continuedTurns.remove(t) }

    /// Cursor has no Stop hook: the daemon ends its turns itself (an ask went idle). The turn's files, or none when this end
    /// is the continuation of a block: one continuation per turn.
    private var continuedTurns: Set<UUID> = []
    mutating func cursorEnd(_ t: UUID) -> [String] {
        let files = take(t)
        return continuedTurns.remove(t) == nil ? files : []
    }
    mutating func continued(_ t: UUID) { continuedTurns.insert(t) }

    /// Claude's Stop payload says `stop_hook_active` when it goes on because a Stop hook blocked.
    static func isContinued(_ payload: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: payload)) as? [String: Any])?["stop_hook_active"] as? Bool == true
    }
}
