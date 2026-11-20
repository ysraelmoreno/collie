import Foundation
import CollieCore

/// M3.1: which tasks of a work may start now, from its task graph (`WorkTask.needs`, `WorkTask.scope`). Pure: no
/// host, store, git or clock. Nothing calls `ready` yet: the engine takes it in M3.5.
enum TaskScheduler {
    static let maxParallel = 4
    static let maxScope = 20

    /// The open tasks that may start now, in the order of `tasks`, at most `parallel` (cut at `maxParallel`) minus the
    /// ones in `running`. `running`: ids with an attempt in a lane; `integrating`: ids that passed in their lane and
    /// are being merged (a task is `done` only once integrated, so one in `integrating` satisfies no `needs` yet; it
    /// takes no slot, but its scope is still taken). `approved`: the ids the owner approved (nil: every open task).
    ///
    /// A task enters when every one of its `needs` is `done` and out of `integrating`, and its `scope` overlaps no
    /// task running, integrating or entering with it. A task with no `scope` is exclusive: it enters only with nothing
    /// running or integrating, and alone. An exclusive task that is ready but must wait closes the door behind it
    /// (nothing after it enters), so the lanes drain and it is not starved by later tasks. A running or integrating id
    /// that is not in `tasks` is treated as exclusive (nothing enters).
    static func ready(tasks: [WorkTask], running: Set<String>, integrating: Set<String>, parallel: Int,
                      approved: Set<String>? = nil) -> [WorkTask] {
        let slots = min(max(parallel, 0), maxParallel) - running.count
        guard slots > 0 else { return [] }
        let busyIds = running.union(integrating)
        let busy = tasks.filter { busyIds.contains($0.id) }
        guard Set(busy.map(\.id)) == busyIds, !busy.contains(where: exclusive) else { return [] }
        let state = Dictionary(tasks.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
        var picked: [WorkTask] = []
        for t in tasks where t.state == .open && !busyIds.contains(t.id) && approved?.contains(t.id) != false {
            guard picked.count < slots else { break }
            guard (t.needs ?? []).allSatisfy({ state[$0] == .done && !integrating.contains($0) }) else { continue }
            let others = busy + picked
            if exclusive(t) {
                if others.isEmpty { picked.append(t) }
                break
            }
            if !others.contains(where: { scopesOverlap(t.scope ?? [], $0.scope ?? []) }) { picked.append(t) }
        }
        return picked
    }

    private static func exclusive(_ t: WorkTask) -> Bool { t.scope?.isEmpty ?? true }

    struct Blocked: Sendable, Equatable { var task: String; var reason: String }

    /// The open tasks that cannot start until the owner acts, with why (in Portuguese, for the owner): one of their
    /// `needs`, directly or through another open task, is deferred, abandoned, missing or in a cycle. In the order of
    /// `tasks`. They never come out of `ready` (their `needs` are not `done`), and they hold no other task back.
    static func blocked(tasks: [WorkTask]) -> [Blocked] {
        let byId = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var memo: [String: String?] = [:]
        func why(_ t: WorkTask, _ path: Set<String>) -> String? {
            if let known = memo[t.id] { return known }
            var reason: String?
            for n in t.needs ?? [] where reason == nil {
                guard let d = byId[n] else { reason = "depende de '\(n)', que não existe neste trabalho"; break }
                let name = "«\(d.title)» [\(n)]"
                if n == t.id || path.contains(n) { reason = "depende de \(name) num ciclo"; break }
                switch d.state {
                case .done: break
                case .deferred: reason = "depende de \(name), que foi adiada"
                case .abandoned: reason = "depende de \(name), que foi abandonada"
                case .open, .inProgress:
                    if why(d, path.union([t.id])) != nil { reason = "depende de \(name), que está bloqueada" }
                }
            }
            memo[t.id] = reason
            return reason
        }
        return tasks.filter { $0.state == .open }.compactMap { t in why(t, []).map { Blocked(task: t.id, reason: $0) } }
    }

    // MARK: scopes

    /// Whether a task with scope `a` and one with scope `b` may touch the same path. Conservative: an empty scope, or
    /// a glob that cannot be compared (see `segments`), overlaps everything.
    static func scopesOverlap(_ a: [String], _ b: [String]) -> Bool {
        if a.isEmpty || b.isEmpty { return true }
        return a.contains { x in b.contains { globsOverlap(x, $0) } }
    }

    /// Whether some path is under both globs. `**` (a whole segment) is any number of folders, `*` any characters of
    /// one segment. A glob also covers what is under it (`Sources/App` is the folder and its files), and letters
    /// compare without case (the usual macOS volume does not tell `Docs` from `docs`): both only widen the answer.
    static func globsOverlap(_ a: String, _ b: String) -> Bool {
        guard let x = segments(a), let y = segments(b) else { return true }
        return intersects(x, y, wild: { $0 == "**" }) { s, t in intersects(Array(s), Array(t), wild: { $0 == "*" }, same: ==) }
    }

    /// `glob` in segments, lowercased, ending in `**`; nil: it cannot be compared (empty, absolute, with `..`, or with
    /// `?`, `[`, `{` or `\`, which this does not interpret).
    // ponytail: only `*` and `**` are understood; a glob with anything else just runs alone. Teach `?` and classes
    // here if scopes with them turn out to be common.
    static func segments(_ glob: String) -> [String]? {
        let g = glob.lowercased()
        guard !g.hasPrefix("/"), !g.hasPrefix("~"), !g.contains(where: { "?[]{}\\".contains($0) || $0.isNewline }) else { return nil }
        var s = g.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0 != "." }
        guard !s.isEmpty, !s.contains(""), !s.contains("..") else { return nil }
        if s.last != "**" { s.append("**") }
        return s
    }

    /// Whether two patterns match a common sequence: an element `wild` stands for any run (none included), any other
    /// matches one element `same` as it.
    private static func intersects<T>(_ a: [T], _ b: [T], wild: (T) -> Bool, same: (T, T) -> Bool) -> Bool {
        // ok[i][j]: a[i...] and b[j...] intersect
        var ok = Array(repeating: Array(repeating: false, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count, through: 0, by: -1) {
            for j in stride(from: b.count, through: 0, by: -1) {
                if i == a.count && j == b.count { ok[i][j] = true }
                else if i < a.count && wild(a[i]) { ok[i][j] = ok[i + 1][j] || (j < b.count && ok[i][j + 1]) }
                else if j < b.count && wild(b[j]) { ok[i][j] = ok[i][j + 1] || (i < a.count && ok[i + 1][j]) }
                else if i < a.count && j < b.count { ok[i][j] = same(a[i], b[j]) && ok[i + 1][j + 1] }
            }
        }
        return ok[0][0]
    }

    // MARK: `work task add --needs --scope`

    /// `a, b` → `["a", "b"]`. An empty item stays (`a,,b`), for the refusals below to see it.
    static func list(_ s: String) -> [String] {
        s.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Why the globs of `--scope` are not accepted (in Portuguese); nil: they are.
    static func scopeRefusal(_ globs: [String]) -> String? {
        if globs.isEmpty || globs.contains("") { return "glob vazio; passe globs relativos à raiz da worktree, separados por vírgula" }
        if globs.count > maxScope { return "no máximo \(maxScope) globs (vieram \(globs.count))" }
        for g in globs {
            if g.hasPrefix("/") || g.hasPrefix("~") { return "'\(g)' é um caminho absoluto; o escopo é relativo à raiz da worktree" }
            if g.split(separator: "/", omittingEmptySubsequences: false).contains("..") { return "'\(g)' tem '..'; o escopo não sai da worktree" }
            if g.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { return "o glob tem caracteres de controle" }
        }
        return nil
    }

    /// Why a task `id` with these `needs` is not accepted among `tasks` (in Portuguese); nil: it is. Every id must be
    /// a task of the work, and the graph with the new task must have no cycle.
    static func needsRefusal(id: String, needs: [String], tasks: [WorkTask]) -> String? {
        var graph = Dictionary(tasks.map { ($0.id, $0.needs ?? []) }, uniquingKeysWith: { a, _ in a })
        for n in needs {
            if n.isEmpty { return "id de tarefa vazio; passe ids separados por vírgula" }
            if n == id { return "a tarefa não pode depender dela mesma ('\(n)')" }
            if graph[n] == nil {
                return "a tarefa '\(n)' não existe neste trabalho"
                    + (tasks.isEmpty ? " (ele ainda não tem tarefas)" : "; ids: " + tasks.map(\.id).joined(separator: ", "))
            }
        }
        graph[id] = needs
        var clear: Set<String> = []
        func cycle(_ n: String, _ path: [String]) -> [String]? {
            if let i = path.firstIndex(of: n) { return Array(path[i...]) + [n] }
            if clear.contains(n) { return nil }
            for m in graph[n] ?? [] { if let c = cycle(m, path + [n]) { return c } }
            clear.insert(n)
            return nil
        }
        if let c = cycle(id, []) { return "as dependências formam um ciclo: " + c.joined(separator: " → ") }
        return nil
    }
}
