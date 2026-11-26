import Foundation
import CollieCore
import CollieProtocol

/// Preferências › Memória › "Memória no Cursor" (`memory.cursor-mode`, spec 2026-11-17 cursor memory §7): the three
/// choices the owner approved and their copy.
enum CursorMemoryChoice: String, CaseIterable, Equatable {
    case full, start, off

    var label: String {
        switch self {
        case .full: tr("Início + consulta por tarefa", "Start + per-task lookup")
        case .start: tr("Só início", "Start only")
        case .off: tr("Desligada", "Off")
        }
    }

    /// Where the memory goes for each choice: out of Collie into cursor-agent, and from it to Cursor's cloud, like the rest
    /// of the conversation.
    var detail: String {
        switch self {
        case .full: tr("A memória do projeto vai para o Cursor no início de cada sessão e, quando o agente chama memory_task no começo de uma tarefa, a memória daquela tarefa. Ela sai do Collie para o cursor-agent e, com a conversa, para a nuvem do Cursor.",
                       "The project memory goes to Cursor at the start of each session and, when the agent calls memory_task at the start of a task, that task's memory. It leaves Collie for cursor-agent and, with the conversation, goes to Cursor's cloud.")
        case .start: tr("A memória do projeto vai para o Cursor só no início de cada sessão, como hoje. Ela sai do Collie para o cursor-agent e, com a conversa, para a nuvem do Cursor.",
                        "The project memory goes to Cursor only at the start of each session, as today. It leaves Collie for cursor-agent and, with the conversation, goes to Cursor's cloud.")
        case .off: tr("Nenhuma memória do projeto vai para o Cursor; ele recebe só as instruções do Collie.", "No project memory goes to Cursor; it only receives Collie's instructions.")
        }
    }

    static var sessionsNote: String { tr("Vale para sessões novas.", "Applies to new sessions.") }
    static var allowlistNote: String { tr("Na primeira chamada, escolha *Add to allowlist*.", "On the first call, choose *Add to allowlist*.") }
    static var honest: String {
        tr("No Cursor a memória chega no início da sessão e quando o agente consulta no começo de cada tarefa. Ela não chega a cada mensagem sua: o cursor-agent não oferece isso sem mexer nos seus arquivos de configuração.",
           "In Cursor, memory arrives at the start of the session and when the agent looks it up at the start of each task. It does not arrive with each message you send: cursor-agent does not offer that without touching your configuration files.")
    }

    /// The `memory.cursor-mode` reply (`{mode}`); nil when it is anything else.
    static func from(reply: JSONValue) -> CursorMemoryChoice? {
        guard case .object(let o) = reply, case .string(let v)? = o["mode"] else { return nil }
        return CursorMemoryChoice(rawValue: v)
    }
}

/// One row of `memory.untrusted`: a memory that isn't what Collie wrote (C7: it stays a bare title in the agents' context
/// until the user trusts it, one at a time, after seeing the difference).
struct UntrustedMemory: Equatable, Identifiable {
    var id: String
    var kind: String
    var title: String
    var repo: String?
    var lot: String?
    var file: String
    /// Collie's last text for this id; nil: it never wrote it.
    var before: String?
    var after: String

    var `where`: String { lot.map { tr("lote \($0)", "lot \($0)") } ?? repo ?? "" }
    var summary: String {
        before == nil ? tr("Arquivo que o Collie nunca gravou (criado à mão, por um agente ou por git).", "File Collie never wrote (created by hand, by an agent or by git).")
            : tr("Editado fora do Collie depois da última gravação dele.", "Edited outside Collie after its last write.")
    }
    /// `memory.trust`'s arguments: the store it lives in (a repo path or a lot name).
    var trustArgs: [String: JSONValue] {
        var a: [String: JSONValue] = ["id": .string(id)]
        if let lot { a["lot"] = .string(lot) } else if let repo { a["repo"] = .string(repo) }
        return a
    }

    static func list(_ reply: JSONValue) -> [UntrustedMemory] {
        guard case .array(let a) = reply else { return [] }
        return a.compactMap { v in
            guard case .object(let o) = v, case .string(let id)? = o["id"], case .string(let after)? = o["after"] else { return nil }
            func s(_ k: String) -> String? { if case .string(let x)? = o[k] { x } else { nil } }
            return UntrustedMemory(id: id, kind: s("kind") ?? "", title: s("title") ?? "", repo: s("repo"), lot: s("lot"),
                                   file: s("file") ?? "", before: s("before"), after: after)
        }
    }

    enum DiffLine: Equatable { case same(String), removed(String), added(String) }

    /// Line by line (stdlib `difference(from:)`), in reading order: each removed line right before what replaced it.
    static func diff(before: String?, after: String) -> [DiffLine] {
        let new = after.components(separatedBy: "\n")
        guard let before else { return new.map(DiffLine.added) }
        let old = before.components(separatedBy: "\n")
        let d = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for c in d { switch c { case .remove(let o, _, _): removed.insert(o); case .insert(let o, _, _): inserted.insert(o) } }
        var out: [DiffLine] = [], i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) { out.append(.removed(old[i])); i += 1; continue }
            if j < new.count, inserted.contains(j) { out.append(.added(new[j])); j += 1; continue }
            if i < old.count, j < new.count { out.append(.same(new[j])); i += 1; j += 1 } else { break }
        }
        return out
    }

    /// The `memory.provenance-status` note: the ledger restarted after damage (limitation 3), or how many files C3 took
    /// as Collie's; nil when there is nothing to say.
    static func ledgerNote(_ reply: JSONValue) -> String? {
        guard case .object(let o) = reply else { return nil }
        if o["restarted"] == .bool(true) {
            return tr("O registro de quem gravou cada memória estava danificado e recomeçou: as memórias que existiam antes ficam como editadas fora do Collie até você confiar em cada uma.", "The record of who wrote each memory was damaged and restarted: memories that existed before stay as edited outside Collie until you trust each one.")
        }
        guard case .number(let n)? = o["adopted"], n >= 1 else { return nil }
        let k = Int(n)
        return k == 1 ? tr("1 memória que já existia foi aceita como do Collie na primeira leitura.", "1 memory that already existed was accepted as Collie's on the first read.")
            : tr("\(k) memórias que já existiam foram aceitas como do Collie na primeira leitura.", "\(k) memories that already existed were accepted as Collie's on the first read.")
    }
}

/// The terminal card's memory badge for a Cursor terminal (C6): from `memory.stats --terminal <name>`'s `byAgent.cursor`.
/// The obedience it hints at covers Collie's asks only (spec 2026-11-17 cursor memory §6).
enum CursorMemoryBadge {
    struct State: Equatable { var text: String; var help: String; var warn: Bool }
    static var scope: String { tr("cobre só pedidos feitos pelo Collie; o que você digita no Cursor não é visto", "covers only requests made by Collie; what you type in Cursor is not seen") }

    /// A Cursor terminal: the preset, or a custom command whose program (past `env` and `VAR=…`) is `cursor-agent`.
    static func isCursor(preset: Preset, command: String?) -> Bool {
        if preset == .cursor { return true }
        guard preset == .custom, let command else { return false }
        let program = command.split(separator: " ").map(String.init)
            .first { $0 != "env" && !$0.hasSuffix("/env") && !($0.contains("=") && !$0.hasPrefix("/")) }
        return program.map { URL(fileURLWithPath: $0).lastPathComponent } == "cursor-agent"
    }

    /// nil: no Cursor events yet (nothing to show).
    static func state(_ stats: JSONValue) -> State? {
        guard case .object(let o) = stats, case .object(let by)? = o["byAgent"], case .object(let c)? = by["cursor"] else { return nil }
        func n(_ k: String) -> Int { if case .number(let x)? = c[k] { Int(x) } else { 0 } }
        let pulls = n("pulls"), asks = n("asksDelivered")
        let started = n("sessionsWithStart") > 0
        let text = tr("Memória: \(started ? "início ✓" : "sem início") · \(pulls) \(pulls == 1 ? "consulta" : "consultas")",
                      "Memory: \(started ? "start ✓" : "no start") · \(pulls) \(pulls == 1 ? "lookup" : "lookups")")
        let warn = asks >= 2 && pulls == 0
        let help = (warn ? tr("o agente não está consultando a memória (\(asks) pedidos do Collie sem memory_task). ", "the agent is not looking up memory (\(asks) Collie requests without memory_task). ") : "")
            + tr("Consultas memory_task nas últimas 24 h; \(scope).", "memory_task lookups in the last 24 h; \(scope).")
        return State(text: text, help: help, warn: warn)
    }
}
