import Foundation
import CollieCore
import CollieProtocol

/// F5: `work prd add|show` and `work plan lint|apply` (`workCommand` routes them, with its reach rules). `prd add` and
/// `plan apply` are the owner's (admin) alone; `prd show` and `plan lint` only read.
extension CommandRouter {
    /// M13.2: the check `--area` builds from the project's collie-work.json (`work task add --area`, a plan's `area:`).
    func areaCheck(_ areas: [String], for t: TerminalRecord) throws(ProtocolError) -> String {
        func invalid(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        if let empty = areas.firstIndex(where: \.isEmpty) { throw invalid("--area: o nome #\(empty + 1) está vazio") }
        let root = ProjectRoot.resolve(cwd: t.cwd, paddock: ws.paddocks.first { $0.id == t.paddockId })
        let built: String
        switch WorkConfigFile.config(root: root) {
        case .failure(let e): throw invalid("--area: " + e.message)
        case .success(nil):
            throw invalid("--area precisa de um \(ProjectWorkConfig.fileName) na raiz do projeto (\(RerailText.clean(root.path, max: 300))); não há nenhum")
        case .success(let c?):
            switch c.composeCheck(areas: areas) {
            case .failure(let e): throw invalid("--area: " + RerailText.clean(e.message, max: 1500))
            case .success(let s): built = s
            }
        }
        guard built.count <= Self.maxWorkText else {
            throw invalid("o check montado por --area tem \(built.count) caracteres; o limite de um check é \(Self.maxWorkText)")
        }
        return built
    }

    /// `work.prd.add`: the text the owner's CLI read (`content`) kept for work `w`.
    func prdAdd(_ r: Request, _ w: Work, now: Date) async throws -> JSONValue {
        guard let content = str(r, "content") else {
            throw ProtocolError(code: .invalidArgs, message: "Missing argument 'content': collie work prd add <arquivo.md> lê o arquivo e o envia")
        }
        let origin = str(r, "origin").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let dir = PrdStore.dir(root: config.paths.root, work: w.id)
        let (list, outcome) = try PrdStore.add(content, origin: origin, replace: flag(r, "replace"), dir: dir, current: w.prd ?? [], at: now)
        // ponytail: decided on the work as read; two owners adding at once is not a case
        if outcome != .same, let cur = list.last {
            try await work.update(w.id) { $0.prd = list; $0.notes.append(WorkNote(at: now, text: PrdStore.note(cur, outcome: outcome))) }
        }
        guard let cur = list.last else { throw ProtocolError(code: .internal, message: "prd: nothing kept") }
        let said = switch outcome {
        case .added: "PRD guardado"
        case .replaced: "PRD trocado (o anterior fica guardado)"
        case .same: "PRD já guardado com este conteúdo; nada mudou"
        }
        return .object(["sha256": .string(cur.sha256), "outcome": .string(outcome.rawValue),
                        "file": .string(PrdStore.file(dir, cur.sha256).path), "origin": cur.origin.map { .string($0) } ?? .null,
                        "output": .string("\(said) em \"\(RerailText.clean(w.title))\": sha256 \(cur.sha256)"
                                          + (cur.origin.map { " · origem: \(RerailText.clean($0, max: PrdStore.originMax))" } ?? ""))])
    }

    /// `work.prd.show`: work `w`'s current PRD, its text included (read only).
    func prdShow(_ w: Work) throws(ProtocolError) -> JSONValue {
        guard let cur = w.prd?.last else {
            throw ProtocolError(code: .notFound, message: "o trabalho \"\(RerailText.clean(w.title))\" não tem PRD; o dono guarda um com collie work prd add <arquivo.md>")
        }
        let url = PrdStore.file(PrdStore.dir(root: config.paths.root, work: w.id), cur.sha256)
        guard let d = PrdStore.read(url), PrdStore.sha256(d) == cur.sha256, let text = String(data: d, encoding: .utf8) else {
            throw ProtocolError(code: .internal, message: "prd: \(url.path) is missing or no longer has its hash")
        }
        let iso = ISO8601DateFormatter()
        return .object(["sha256": .string(cur.sha256), "origin": cur.origin.map { .string($0) } ?? .null,
                        "addedAt": .string(iso.string(from: cur.addedAt)), "previous": .number(Double((w.prd?.count ?? 1) - 1)),
                        "text": .string(text), "output": .string((PrdStore.line(w) ?? "") + "\n\n" + text)])
    }

    /// A plan package's folder: `dir` relative to the caller's cwd, links resolved; `confined` (an agent's call): it
    /// must lie in `t`'s project.
    func planDir(_ r: Request, _ t: TerminalRecord?, confined: Bool) async throws -> URL {
        let given = try need(r, "dir")
        let base = r.cwd ?? t?.cwd ?? FileManager.default.currentDirectoryPath
        let real = SignedAppCheck.realPath(URL(fileURLWithPath: given, relativeTo: URL(fileURLWithPath: base, isDirectory: true)))
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue else {
            throw ProtocolError(code: .invalidArgs, message: "\(given) não é uma pasta (o pacote: waves.md e tasks/*.md)")
        }
        if let t, confined || r.command == "work.plan.apply" {
            let root = try await projectRoot(of: t)
            guard ProjectRoot.contains(real, root: root) else {
                throw ProtocolError(code: .invalidArgs, message: "\(given) está fora do projeto \(root.path)")
            }
        }
        return URL(fileURLWithPath: real, isDirectory: true)
    }

    /// `work.plan.apply`: the package at `dir` made into `w`'s tasks (never starting its loop).
    func planApply(_ r: Request, _ t: TerminalRecord, _ w: Work, now: Date) async throws -> JSONValue {
        let dir = try await planDir(r, t, confined: true)
        let root = try await projectRoot(of: t)
        // the `area:` checks built here, on the actor (the project's collie-work.json), by the areas as listed
        var checks: [String: Result<String, ProtocolError>] = [:]
        for task in PlanLint.lint(dir, root: root).tasks where task.fields["check"] == nil && task.fields["area"] != nil {
            let areas = task.list("area")
            do throws(ProtocolError) { checks[areas.joined(separator: ",")] = .success(try areaCheck(areas, for: t)) }
            catch { checks[areas.joined(separator: ",")] = .failure(error) }
        }
        let built = checks
        let (plan, tasks) = try await PlanApply.apply(dir: dir, root: root, approve: try need(r, "approve"), work: w.id, store: work, now: now) { areas in
            guard let c = built[areas.joined(separator: ",")] else {
                throw ProtocolError(code: .invalidArgs, message: "o plano mudou durante o apply; rode collie work plan lint de novo")
            }
            return try c.get()
        }
        let gate = plan.gate.map { " --gate '\(RerailText.clean($0, max: 300))'" } ?? ""
        let lines = tasks.map { "  - \(RerailText.clean($0.title)) [\($0.id)]" + (($0.needs ?? []).isEmpty ? "" : " precisa de \(($0.needs ?? []).joined(separator: ", "))") }
        return .object(["tasks": .array(tasks.map { .string($0.id) }), "hash": .string(plan.hash),
                        "output": .string((["Plano aplicado em \"\(RerailText.clean(w.title))\": \(tasks.count) tarefa(s) em \(plan.waves) onda(s) (pacote \(plan.hash.prefix(12)))."]
                                           + lines + ["O laço não começou. Quando quiser: collie work run --max <N>\(gate) (o cartão no app confirma as tarefas e os limites)."]).joined(separator: "\n"))])
    }

    /// `work.run` of a work with a PRD: its plan applied, still passing the linter, with the hash the owner approved.
    /// C4a: each task of the plan still runs its own card as its `spec` (the card's content is in the hash: a spec
    /// pointing elsewhere would run text nobody approved), and every task added later (`work task add`, CLI or MCP)
    /// that the loop would take passes the linter's check rule (`PlanLint.checkRefusal`, `trivialCheck`).
    static func prdPlanRefusal(_ w: Work) -> String? {
        guard w.prd?.isEmpty == false else { return nil }
        guard let applied = w.plan else {
            return "o trabalho tem PRD: o laço roda o plano aprovado; rode collie work plan lint <pasta> e o dono, collie work plan apply <pasta> --approve <hash>"
        }
        let dir = URL(fileURLWithPath: applied.dir, isDirectory: true)
        let p = PlanLint.lint(dir)
        guard p.passed else { return "o plano do PRD (\(applied.dir)) não passa mais no linter:\n" + p.text }
        guard p.hash == applied.sha256 else {
            return "o plano do PRD (\(applied.dir)) mudou depois de aprovado (aprovado \(applied.sha256.prefix(12)), agora \(p.hash.prefix(12))); volte o pacote ao aprovado, ou aplique o novo num trabalho novo"
        }
        let planned = Set(applied.tasks)
        for t in w.tasks where planned.contains(t.id) {
            guard let card = p.tasks.first(where: { $0.id == t.id }), t.spec == SignedAppCheck.realPath(card.url) else {
                return "a tarefa \"\(RerailText.clean(t.title, max: 80))\" [\(t.id)] do plano aprovado não aponta mais para o seu cartão (\(applied.dir)/tasks/\(t.id).md): a spec que roda é a do pacote aprovado"
            }
        }
        for t in w.tasks where !planned.contains(t.id) && (t.state == .open || t.state == .inProgress) {
            let c = t.check ?? ""
            guard let why = PlanLint.checkRefusal(c) ?? PlanLint.trivialCheck(c, scope: t.scope ?? [], body: "") else { continue }
            return "a tarefa \"\(RerailText.clean(t.title, max: 80))\" [\(t.id)], adicionada depois do plano aprovado, tem um check que o linter recusa: \(why)"
        }
        return nil
    }
}
