import Foundation
import CollieCore
import CollieProtocol

/// F5, `collie work plan apply <dir> --approve <sha256>` (the owner's): the work's tasks made from a plan package, only
/// once it passes `PlanLint` and only with the hash the owner approved (what they saw is what runs). A task of a wave
/// needs every task of the wave before it. It never starts the loop: `work run` stays the owner's next step.
enum PlanApply {
    /// The tasks `p` makes for a work that has `existing` ones. `areaCheck` builds a check from `area:` (the project's
    /// collie-work.json, as `work task add --area`). Throws the refusal.
    /// C4a: `root`, the project: no task's `spec` (its card, links resolved) may lie outside it.
    static func tasks(_ p: PlanLint.Plan, approve: String, existing: [WorkTask], now: Date, root: URL? = nil,
                      areaCheck: ([String]) throws -> String) throws -> [WorkTask] {
        func invalid(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        guard p.passed else {
            throw invalid("o plano não passa no linter (\(p.findings.count) problema(s)); nada foi criado:\n" + p.text)
        }
        let given = approve.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard given == p.hash else {
            throw invalid("--approve \(RerailText.clean(given, max: 80)) não é o hash do pacote agora (\(p.hash)): ele mudou depois que você o viu, "
                          + "ou o hash está errado; nada foi criado. Rode collie work plan lint \(p.dir.path) e aprove o que ele mostrar")
        }
        let taken = Set(existing.map(\.id))
        if let dup = p.tasks.first(where: { taken.contains($0.id) }) {
            throw invalid("o trabalho já tem uma tarefa '\(dup.id)': este plano já foi aplicado? nada foi criado")
        }
        return try p.tasks.map { t in
            func bad(_ field: String, _ why: String) -> ProtocolError {
                invalid("\(t.file):\(t.fields[field]?.line ?? 1): \(field) \(why); nada foi criado")
            }
            guard t.title.count <= CommandRouter.maxWorkText else { throw bad("title", "tem mais de \(CommandRouter.maxWorkText) caracteres") }
            let check: String
            if let c = t.fields["check"]?.value { check = c } else { check = try areaCheck(t.list("area")) }
            guard check.count <= CommandRouter.maxWorkText else { throw bad("check", "tem mais de \(CommandRouter.maxWorkText) caracteres") }
            let spec = SignedAppCheck.realPath(t.url)
            if let root, !ProjectRoot.contains(spec, root: root) { throw bad("spec", "aponta para fora do projeto (\(RerailText.clean(spec, max: 200)))") }
            var task = WorkTask(id: t.id, title: t.title, updatedAt: now, spec: spec, check: check,
                                evidenceGlob: t.fields["evidence"]?.value, needs: t.needs.isEmpty ? nil : t.needs,
                                scope: t.fields["scope"] == nil ? nil : t.list("scope"))
            if let e = task.evidenceGlob, let why = EvidenceFiles.refusal(e) { throw bad("evidence", why) }
            if let s = task.scope, let why = TaskScheduler.scopeRefusal(s) { throw bad("scope", why) }
            if let a = t.fields["accept"]?.value {
                if let why = CommandRouter.acceptRefusal(a) { throw bad("accept", why) }
                task.accept = a
            }
            if let s = t.fields["accept-timeout"]?.value {
                guard task.accept != nil else { throw bad("accept-timeout", "precisa de accept") }
                guard let n = Int(s), n >= 1, n <= WorkTask.acceptTimeoutMax else { throw bad("accept-timeout", "deve ser de 1 a \(WorkTask.acceptTimeoutMax) segundos") }
                task.acceptTimeout = n
            }
            if let a = t.fields["agent"]?.value {
                guard CommandRouter.taskAgents.contains(a) else { throw bad("agent", "deve ser \(CommandRouter.taskAgents.joined(separator: "|"))") }
                task.agent = a
            }
            if let m = t.fields["model"]?.value { try ClaudeModel.validate(m); task.model = m }
            return task
        }
    }

    /// `dir` linted and applied to work `id` in `store`: its tasks appended, the plan and an audit note recorded. The
    /// loop is never touched (a running or queued one refuses: its approved tasks are not changed under it).
    static func apply(dir: URL, root: URL? = nil, approve: String, work id: UUID, store: WorkStore, now: Date,
                      areaCheck: @Sendable ([String]) throws -> String) async throws -> (plan: PlanLint.Plan, tasks: [WorkTask]) {
        let plan = PlanLint.lint(dir, root: root)
        guard let w = try await store.get(id) else { throw ProtocolError(code: .notFound, message: "no work \(id.uuidString.lowercased())") }
        if let s = w.loop?.state, s == .running || s == .queued {
            throw ProtocolError(code: .invalidArgs, message: "o laço deste trabalho está \(s == .running ? "rodando" : "na fila"): o plano não muda as tarefas que ele aprovou; espere-o terminar")
        }
        let built = try tasks(plan, approve: approve, existing: w.tasks, now: now, root: root, areaCheck: areaCheck)
        // ponytail: built from the work read above; a task added between the read and this write could share an id
        try await store.update(id) { x in
            x.tasks += built
            x.plan = WorkPlan(dir: dir.path, sha256: plan.hash, appliedAt: now, tasks: built.map(\.id))
            x.notes.append(WorkNote(at: now, text: "[plano] pacote sha256 \(plan.hash) aplicado de \(dir.path): \(built.count) tarefa(s) em \(plan.waves) onda(s); o laço não começou", decision: true))
        }
        return (plan, built)
    }
}
