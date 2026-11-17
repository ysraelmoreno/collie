import Foundation
import CollieCore
import CollieProtocol

/// Preferências › Memória › "Memória no Cursor" (`memory.cursor-mode`, spec 2026-11-17 cursor memory §7): the three
/// choices the owner approved and their copy.
enum CursorMemoryChoice: String, CaseIterable, Equatable {
    case full, start, off

    var label: String {
        switch self {
        case .full: "Início + consulta por tarefa"
        case .start: "Só início"
        case .off: "Desligada"
        }
    }

    /// Where the memory goes for each choice: out of Collie into cursor-agent, and from it to Cursor's cloud, like the rest
    /// of the conversation.
    var detail: String {
        switch self {
        case .full: "A memória do projeto vai para o Cursor no início de cada sessão e, quando o agente chama memory_task no começo de uma tarefa, a memória daquela tarefa. Ela sai do Collie para o cursor-agent e, com a conversa, para a nuvem do Cursor."
        case .start: "A memória do projeto vai para o Cursor só no início de cada sessão, como hoje. Ela sai do Collie para o cursor-agent e, com a conversa, para a nuvem do Cursor."
        case .off: "Nenhuma memória do projeto vai para o Cursor; ele recebe só as instruções do Collie."
        }
    }

    static let sessionsNote = "Vale para sessões novas."
    static let allowlistNote = "Na primeira chamada, escolha *Add to allowlist*."
    static let honest = "No Cursor a memória chega no início da sessão e quando o agente consulta no começo de cada tarefa. Ela não chega a cada mensagem sua: o cursor-agent não oferece isso sem mexer nos seus arquivos de configuração."

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

    var `where`: String { lot.map { "lote \($0)" } ?? repo ?? "" }
    var summary: String {
        before == nil ? "Arquivo que o Collie nunca gravou (criado à mão, por um agente ou por git)."
            : "Editado fora do Collie depois da última gravação dele."
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
            return "O registro de quem gravou cada memória estava danificado e recomeçou: as memórias que existiam antes ficam como editadas fora do Collie até você confiar em cada uma."
        }
        guard case .number(let n)? = o["adopted"], n >= 1 else { return nil }
        let k = Int(n)
        return k == 1 ? "1 memória que já existia foi aceita como do Collie na primeira leitura."
            : "\(k) memórias que já existiam foram aceitas como do Collie na primeira leitura."
    }
}

/// The terminal card's memory badge for a Cursor terminal (C6): from `memory.stats --terminal <name>`'s `byAgent.cursor`.
/// The obedience it hints at covers Collie's asks only (spec 2026-11-17 cursor memory §6).
enum CursorMemoryBadge {
    struct State: Equatable { var text: String; var help: String; var warn: Bool }
    static let scope = "cobre só pedidos feitos pelo Collie; o que você digita no Cursor não é visto"

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
        let text = "Memória: " + (n("sessionsWithStart") > 0 ? "início ✓" : "sem início") + " · \(pulls) " + (pulls == 1 ? "consulta" : "consultas")
        let warn = asks >= 2 && pulls == 0
        let help = (warn ? "o agente não está consultando a memória (\(asks) pedidos do Collie sem memory_task). " : "")
            + "Consultas memory_task nas últimas 24 h; " + scope + "."
        return State(text: text, help: help, warn: warn)
    }
}
