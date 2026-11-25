import Foundation
import CollieCore
import CollieProtocol

/// `work.hook` (terminal only) and the life of jobs: terminal death, silence, dead shell pids.
extension CommandRouter {
    static let silentJobSeconds: TimeInterval = 30 * 60

    /// Applies a Claude Code hook to the caller's active work, opening an implicit one on the first task or job.
    /// Never fails the agent: every error is a daemon log line (no payload contents).
    func workHook(_ r: Request, from tid: UUID) async {
        let now = Date()
        if ["precompact", "session-end"].contains(str(r, "hook") ?? ""),   // the conversation so far, before it is compacted or gone
           let tr = HookPayload.transcriptPath(stdinJSON: Data((str(r, "payload") ?? "").utf8)) {
            Task { await captureConversationNow(tid, transcript: tr) }
        }
        let events = WorkHookParser.events(hook: str(r, "hook") ?? "", json: Data((str(r, "payload") ?? "").utf8), now: now)
        guard !events.isEmpty else { return }
        do {
            var w = try await work.active(terminal: tid)
            if w == nil {
                guard events.contains(where: Self.opensWork), let me = ws.terminals.first(where: { $0.id == tid }),
                      !Self.isLoopAttempt(me.id, name: me.name, in: try await work.list(includeClosed: true)) else { return }
                w = try await implicitWork(me, now: now)
            }
            guard let w else { return }
            try await work.update(w.id) { Self.apply(events, to: &$0, now: now) }
            workStoreBroken = false
            // compaction or the session's end: what it learned becomes proposals (detached: the hook never waits on the model)
            if events.contains(where: { $0 == .compacted || $0 == .sessionEnded }) { Task { await captureProposals(w.id) } }
            await goneIfDead(tid)   // the terminal may have died or been removed while this hook ran
        } catch {
            workFailed("hook \(str(r, "hook") ?? "?")", error)
        }
    }

    /// The terminal's active work, else a new one titled "<name> — <day>" on its paddock's branch.
    func implicitWork(_ me: TerminalRecord, now: Date) async throws -> Work {
        if let w = try await work.active(terminal: me.id) { return w }
        let paddock = ws.paddocks.first { $0.id == me.paddockId }
        let day = Date.ISO8601FormatStyle(timeZone: .current).year().month().day().dateSeparator(.dash)
        do { return try await work.start(title: "\(me.name) — \(now.formatted(day))", terminal: me.id, paddockId: paddock?.id, branch: paddock?.gitBranch) }
        catch { if let w = try await work.active(terminal: me.id) { return w }; throw error }   // a concurrent call opened it first
    }

    private func goneIfDead(_ tid: UUID) async {
        if await registry.process(tid)?.isRunning != true { await jobsGone(terminal: tid) }
    }

    /// One log line per outage of the store (a corrupt work.json would otherwise log every sweep); a good read re-arms it.
    private func workFailed(_ context: String, _ error: any Error) {
        guard !workStoreBroken else { return }
        workStoreBroken = true
        workLog("\(context): \((error as? ProtocolError)?.message ?? "\(error)")")
    }

    /// M8.1: the terminal is a loop's attempt (a running `.loop` job names it, by its terminal or, before the loop marks
    /// it, its agent name). Its hooks open no implicit work: a background shell or subagent of the attempt used to open
    /// "<attempt> — <day>" with no task, and the history listed each attempt as a work.
    static func isLoopAttempt(_ id: UUID, name: String, in works: [Work]) -> Bool {
        works.contains { $0.jobs.contains { $0.kind == .loop && $0.state == .running && ($0.terminal == id || $0.id == name) } }
    }

    /// A task or a job opens an implicit work; notes and job ends alone do not.
    private static func opensWork(_ e: WorkEvent) -> Bool {
        switch e {
        case .tasks(let t): !t.isEmpty
        case .taskChanged(let t, _): !t.title.isEmpty
        case .jobStarted: true
        default: false
        }
    }

    static func apply(_ events: [WorkEvent], to w: inout Work, now: Date) {
        for e in events {
            switch e {
            case .tasks(let new): w.tasks = WorkHookParser.diff(old: w.tasks, new: new, now: now)
            case .taskChanged(let t, let hasState):
                if let i = w.tasks.firstIndex(where: { $0.id == t.id }) {
                    if !t.title.isEmpty { w.tasks[i].title = t.title }   // TaskUpdate without subject keeps the title
                    if hasState && w.tasks[i].state != t.state {   // without a status the state and reason stay
                        w.tasks[i].state = t.state; w.tasks[i].reason = nil; w.tasks[i].updatedAt = now
                    }
                } else if !t.title.isEmpty {
                    w.tasks.append(t)
                }
            case .jobStarted(let j): if !w.jobs.contains(where: { $0.id == j.id }) { w.jobs.append(j) }
            case .jobEnded(let id, let result):
                let i: Int?
                if id.isEmpty {
                    // ponytail: SubagentStop without agent_id ends the oldest running (or unknown) subagent: all running ones
                    // were started in the background (sync ones end in their own PostToolUse). Wrong when they finish out of order.
                    i = w.jobs.indices.filter { w.jobs[$0].kind == .subagent && Self.endable(w.jobs[$0]) }
                        .min { w.jobs[$0].startedAt < w.jobs[$1].startedAt }
                } else if id.hasPrefix("agent:") {   // SubagentStop: no match = a sync subagent, its job not started yet
                    let agent = String(id.dropFirst("agent:".count))
                    i = w.jobs.firstIndex { $0.kind == .subagent && $0.alias == agent && Self.endable($0) }
                } else {   // TaskOutput/TaskStop name the job id or (a background agent) its alias
                    i = w.jobs.firstIndex { ($0.id == id || $0.alias == id) && Self.endable($0) }
                }
                if let i { w.jobs[i].state = .finished; w.jobs[i].endedAt = now; w.jobs[i].result = result }
            case .compacted: w.notes.append(WorkNote(at: now, text: "Context compacted"))
            case .sessionEnded: w.notes.append(WorkNote(at: now, text: "Session ended"))
            }
        }
    }

    /// Running, or `unknown` after a silence: a real end signal still finishes it. Never a loop's: only the loop ends those.
    private static func endable(_ j: WorkJob) -> Bool { j.kind != .loop && (j.state == .running || j.state == .unknown) }

    /// At start (after the orphan reap): running jobs of terminals without a live process are gone.
    func jobsGoneWithoutProcess() async {
        var alive: Set<UUID> = []
        for t in ws.terminals where await registry.process(t.id)?.isRunning == true { alive.insert(t.id) }
        await sweep({ !alive.contains($0.terminalId) }) { _ in .gone }
    }

    /// The terminal's process is gone: so is every running job of its works.
    func jobsGone(terminal: UUID) async {
        await sweep({ $0.terminalId == terminal }) { _ in .gone }
    }

    /// Every 60 s: a running shell whose known pid is gone (ESRCH) is `gone`; a running job without a pid, started
    /// more than 30 min before `now`, is `unknown`. ponytail: silence is measured from `startedAt` (jobs carry no
    /// last-signal time); add one when a hook reports progress.
    func sweepJobs(now: Date) async {
        await sweep({ _ in true }) { j in
            if let pid = j.pid { return kill(pid, 0) != 0 && errno == ESRCH ? .gone : nil }
            return now.timeIntervalSince(j.startedAt) > Self.silentJobSeconds ? .unknown : nil
        }
    }

    /// Running jobs of the works matching `which` get the state `verdict` returns (nil: unchanged); only changed works are written.
    private func sweep(_ which: (Work) -> Bool, _ verdict: @escaping @Sendable (WorkJob) -> JobState?) async {
        func swept(_ w: inout Work) {
            let now = Date()
            for i in w.jobs.indices where w.jobs[i].state == .running && w.jobs[i].kind != .loop {   // the loop ends its own
                guard let s = verdict(w.jobs[i]) else { continue }
                w.jobs[i].state = s
                if s == .gone { w.jobs[i].endedAt = now }
            }
        }
        do {
            let all = try await work.list(includeClosed: true)
            workStoreBroken = false
            for w in all where which(w) && w.jobs.contains(where: { $0.state == .running && $0.kind != .loop }) {
                var copy = w; swept(&copy)
                if copy != w { try await work.update(w.id) { swept(&$0) } }
            }
        } catch {
            workFailed("job sweep", error)
        }
    }

    func startJobSweep() {
        jobSweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.sweepJobs(now: Date())
            }
        }
    }
    func stopJobSweep() { jobSweeper?.cancel(); jobSweeper = nil }
}

/// `collie work …` (all but `work.hook`): the app (admin token) acts on any terminal's work; a terminal on its own, and a
/// Shepherd also on those of the terminals it reaches by leash (`--terminal`). An unreached terminal or work answers
/// exactly like a missing one, so existence never leaks.
extension CommandRouter {
    static let maxWorkText = 2000
    /// F2 R1: the agents `work task add --agent` takes (who works on the task).
    static let taskAgents = ["claude", "cursor", "codex"]

    func workCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        let caller = try await principal(r, peer: peer)   // nil = admin (the user / app)
        func invalid(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        func missing(_ m: String) -> ProtocolError { ProtocolError(code: .notFound, message: m) }
        let seen: Set<UUID>? = caller.map { me in
            Set([me.id] + (me.isShepherd ? ConnectionGraph.reachable(from: me.id, in: ws).map(\.id) : []))
        }
        func visible(_ w: Work) -> Bool { seen?.contains(w.terminalId) ?? true }
        func target() throws(ProtocolError) -> TerminalRecord {
            guard let name = str(r, "terminal") else {
                guard let caller else { throw invalid("--terminal is required") }
                return caller
            }
            let hits = ws.terminals.filter { (seen?.contains($0.id) ?? true) && $0.name.caseInsensitiveCompare(name) == .orderedSame }
            guard hits.count <= 1 else { throw ProtocolError(code: .ambiguous, message: "Multiple terminals named '\(name)'") }
            guard let t = hits.first else { throw missing("Terminal '\(name)' not found") }
            return t
        }
        /// Required, trimmed, bounded free text.
        func text(_ k: String) throws(ProtocolError) -> String {
            let v = (str(r, k) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { throw invalid("Missing argument '\(k)'") }
            guard v.count <= Self.maxWorkText else { throw invalid("'\(k)' is longer than \(Self.maxWorkText) characters") }
            return v
        }
        /// M3b.6: a comma-separated string (the CLI's repeated flag) or a JSON array of strings (an MCP client); nil:
        /// absent. Any other type is refused: a value dropped in silence would let a task start before its `needs`.
        func strings(_ k: String) throws(ProtocolError) -> [String]? {
            switch r.args[k] {
            case nil, .null?: return nil
            case .string(let s)?: return TaskScheduler.list(s)
            case .array(let a)?:
                let items = a.compactMap { if case .string(let s) = $0 { s } else { nil } }
                guard items.count == a.count else { throw invalid("--\(k) must be a string or an array of strings") }
                return TaskScheduler.list(items.joined(separator: ","))
            default: throw invalid("--\(k) must be a string or an array of strings")
            }
        }
        func active(_ t: TerminalRecord) async throws -> Work {
            guard let w = try await work.active(terminal: t.id) else {
                throw missing("no active work for '\(t.name)'; start one with collie work start <title>")
            }
            return w
        }
        func byId(_ s: String) async throws -> Work {
            guard let id = UUID(uuidString: s), let w = try await work.get(id), visible(w) else { throw missing("no work \(s)") }
            return w
        }
        let now = Date(), by = caller.map { "agent:\($0.name)" } ?? "app"

        switch r.command {
        case "work.start":
            let t = try target()
            let branch = str(r, "branch").flatMap { $0.isEmpty ? nil : $0 }
            if let b = branch, !(await Self.validBranch(b, in: URL(fileURLWithPath: t.cwd))) { throw invalid("invalid branch '\(b)'") }   // git arg
            let paddock = ws.paddocks.first { $0.id == t.paddockId }
            let w = try await work.start(title: try text("title"), terminal: t.id, paddockId: paddock?.id, branch: branch ?? paddock?.gitBranch)
            return .object(["id": .string(w.id.uuidString.lowercased())])

        case "work.done":   // --id: any work the caller sees, also one whose terminal was removed
            let w = if let s = str(r, "id") { try await byId(s) } else { try await active(try target()) }
            guard w.closedAt == nil else { throw invalid("work \(w.id.uuidString.lowercased()) is already closed") }
            let reason = str(r, "reason") == nil ? nil : try text("reason")
            let lot = ws.lot(of: w.terminalId)?.id
            try await work.update(w.id) {
                if let reason { $0.notes.append(WorkNote(at: now, text: "Done: \(reason)")) }
                $0.closedAt = now; $0.closedBy = by; $0.lotId = lot
            }
            Task {
                await captureConversationNow(w.terminalId)
                await captureProposals(w.id)   // its learnings become proposals (the model may take seconds)
                // and the repo's new review files feed its pitfall classes
                // (not a lot member's close: lot findings never reach the project but by promote)
                if let t = ws.terminals.first(where: { $0.id == w.terminalId }), ws.lot(of: t.id) == nil {
                    await ingestReviews(repo: await memory.repo(for: t.cwd))
                }
            }
            return .object(["id": .string(w.id.uuidString.lowercased())])

        case "work.reopen":
            let w: Work
            if let s = str(r, "id") { w = try await byId(s) } else {
                let t = try target()
                let closed = try await work.list(includeClosed: true).filter { $0.terminalId == t.id && $0.closedAt != nil }
                guard let last = closed.max(by: { $0.closedAt! < $1.closedAt! }) else { throw missing("no closed work for '\(t.name)'") }
                w = last
            }
            try await work.reopen(w.id)
            return .object(["id": .string(w.id.uuidString.lowercased())])

        case "work.task.add":
            let t = try target(), title = try text("title")
            var check = str(r, "check") == nil ? nil : try text("check")
            // M13.2: --area builds the check from the project's collie-work.json; the task keeps the built command
            let areas = try strings("area")
            if let areas {
                guard check == nil else { throw invalid("--area e --check não andam juntos: --area monta o check a partir do collie-work.json; use um ou outro") }
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
                check = built
            }
            let evidence = str(r, "evidence")
            if let evidence, let why = EvidenceFiles.refusal(evidence) { throw invalid("--evidence \(why)") }
            var spec: String?
            if let given = str(r, "spec") {   // only the path is kept: the loop reads the file when an attempt starts
                let real = SignedAppCheck.realPath(URL(fileURLWithPath: given, relativeTo: URL(fileURLWithPath: r.cwd ?? t.cwd, isDirectory: true)))
                guard (try? FileManager.default.attributesOfItem(atPath: real)[.type] as? FileAttributeType) == .typeRegular else {
                    throw invalid("--spec \(given) is not a file")
                }
                let root = try await projectRoot(of: t)
                guard ProjectRoot.contains(real, root: root) else { throw invalid("--spec \(given) is outside the project \(root.path)") }
                spec = real
            }
            // M3.1: the graph is checked on the way in (before a work is opened for a task that is refused)
            let id = String(UUID().uuidString.prefix(8)).lowercased()
            let needs = try strings("needs"), scope = try strings("scope")
            if let scope, let why = TaskScheduler.scopeRefusal(scope) { throw invalid("--scope: \(why)") }
            if let needs, let why = TaskScheduler.needsRefusal(id: id, needs: needs, tasks: try await work.active(terminal: t.id)?.tasks ?? []) {
                throw invalid("--needs: \(why)")
            }
            let agent = str(r, "agent"), model = str(r, "model")
            if let agent, !Self.taskAgents.contains(agent) { throw invalid("--agent must be \(Self.taskAgents.joined(separator: "|"))") }
            if let model { try ClaudeModel.validate(model) }
            let w = try await implicitWork(t, now: now)
            var task = WorkTask(id: id, title: title, updatedAt: now, spec: spec, check: check, evidenceGlob: evidence, needs: needs, scope: scope,
                            greenOk: flag(r, "green-ok") ? true : nil)
            task.agent = agent; task.model = model
            try await work.update(w.id) { $0.tasks.append(task) }
            guard let areas, let check, case .object(var o) = try isoJSON(task) else { return try isoJSON(task) }
            o["output"] = .string("Tarefa \"\(RerailText.clean(title))\" [\(id)] adicionada; check montado pelas áreas "
                                  + "\(RerailText.clean(areas.joined(separator: ", "))): \(RerailText.clean(check, max: Self.maxWorkText + 10))")
            return .object(o)

        case "work.task.done", "work.task.defer", "work.task.drop", "work.task.reopen":
            let t = try target()
            let (state, reason): (TaskState, String?) = switch r.command {
            case "work.task.done": (.done, nil)
            case "work.task.defer": (.deferred, try text("reason"))
            case "work.task.drop": (.abandoned, try text("reason"))
            default: (.open, nil)
            }
            let w = try await active(t), key = try text("task")
            // the id first, then the title (case-insensitive)
            let hits = w.tasks.contains { $0.id == key } ? w.tasks.filter { $0.id == key }
                : w.tasks.filter { $0.title.caseInsensitiveCompare(key) == .orderedSame }
            guard hits.count <= 1 else { throw ProtocolError(code: .ambiguous, message: "Multiple tasks titled '\(key)'; use its id") }
            if r.command == "work.task.reopen" {
                guard let hit = hits.first, let re = try await work.reopenTask(w.id, task: hit.id, keepTries: flag(r, "keep-tries"), at: now) else {
                    throw missing("no task '\(key)' in the active work")
                }
                switch re.from {
                case .deferred, .abandoned: break
                case .done: throw invalid("a tarefa já está feita; use `work task defer` antes se quer refazê-la")
                case .open: throw invalid("a tarefa já está aberta; não há o que reabrir")
                case .inProgress:
                    throw invalid("a tarefa está em andamento" + (w.loop?.state == .running ? " num laço rodando" : "") + "; só se reabre uma adiada ou abandonada")
                }
                guard case .object(var o) = try isoJSON(re.task) else { throw ProtocolError(code: .internal, message: "task encoding") }
                o["output"] = .string("Tarefa \"\(re.task.title)\" reaberta [\(re.task.id)]: de volta à fila, na mesma posição. "
                    + (re.loopTakes ? "O laço em curso a pega de novo: ela está entre as que ele aprovou."
                       : "Ela espera o próximo `work run`, como uma tarefa adicionada depois: um laço só pega as tarefas aprovadas quando começou."))
                return .object(o)
            }
            guard let hit = hits.first, let done = try await work.setTask(w.id, task: hit.id, state: state, reason: reason, at: now) else {
                throw missing("no task '\(key)' in the active work")
            }
            return try isoJSON(done)

        case "work.note":
            let t = try target(), note = WorkNote(at: now, text: try text("text"), decision: flag(r, "decision"))
            let w = try await implicitWork(t, now: now)
            try await work.update(w.id) { $0.notes.append(note) }
            return .object([:])

        case "work.status":
            let all = flag(r, "all"), t = all ? nil : try target()
            let works = if let t { try await work.active(terminal: t.id).map { [$0] } ?? [] }
                else { try await work.list(includeClosed: false).filter(visible) }
            // M3c.2: a status of its own work is a wait too (the loop's integrator does not count the starter for it)
            let own = t.flatMap { t in caller?.id == t.id ? works.first.map { (t.id, $0.id) } : nil }
            let token = own.map { ownWaitBegan($0.0, on: $0.1, pid: peer) }
            defer { if let own, let token { ownWaitEnded(own.0, token) } }
            // `--events [N]`: each loop's journal after its work's status, and in `events` (by work id) for the panel and MCP
            // (MCP/JSON: `events: true` is the bare flag, `events: false` is no journal, as if absent)
            let last: Int? = if case .bool(false)? = r.args["events"] { nil }
                else { try flag(r, "events") ? Self.loopEventsDefault : num(r, "events", max: Double(WorkLoopState.eventsMax)).map { Int($0) } }
            return .object(try workStatus(works, events: last, now: now))

        case "work.wait":   // the caller's active work (or a leashed terminal's): answers when it changed past --since
            let t = try target(), w = try await active(t)
            // M3c.2: the caller blocked on its own work's change is not working in its worktree (`loopAnyoneWorking`)
            let own = caller?.id == t.id
            // M3d.1: the socket cancels this request when its client goes (UnixSocket `cancelsOnHangup`)
            let token = own ? ownWaitBegan(t.id, on: w.id, pid: peer) : nil
            defer { if let token { ownWaitEnded(t.id, token) } }
            let timeout = try num(r, "timeout", max: Self.workWaitMax) ?? Self.workWaitDefault
            let since: Int?
            switch r.args["since"] {   // a version: 0 is one (a work no counting store wrote yet), so not `num` (1...)
            case nil, .null?: since = nil
            case .number(let n)? where n >= 0 && n <= 1e15 && n == n.rounded(): since = Int(n)
            case .string(let s)? where Int(s).map({ $0 >= 0 }) ?? false: since = Int(s)
            default: throw invalid("--since must be a version (an integer, 0 or more)")
            }
            // no --since: the state as it is, with the version to wait from; a loop that ended never waits
            if let since, w.loop.map({ $0.state == .running }) ?? true { _ = try await workChanged(w.id, since: since, timeout: timeout) }
            guard let cur = try await work.get(w.id), visible(cur) else { throw missing("no active work for '\(t.name)'") }
            let version = cur.version ?? 0, ended = cur.loop.map { $0.state != .running } ?? false
            let timedOut = since.map { version <= $0 && !ended } ?? false
            var o = try workStatus([cur], events: nil, now: Date())
            o["version"] = .number(Double(version)); o["ended"] = .bool(ended); o["timedOut"] = .bool(timedOut)
            o["output"] = .string(WorkStatusText.waitLine(cur, version: version, timedOut: timedOut, now: Date()))
            return .object(o)

        case "work.summary":   // same reach as work.status; `--natural`: the on-device model's rewrite, the markdown always
            let w = if let s = str(r, "id") { try await byId(s) } else { try await active(try target()) }
            var sum = WorkSummary.make(w, terminalAlive: await registry.process(w.terminalId)?.isRunning == true, now: now)
            // reverts: only here, where the summary is asked for (git calls); the work's paddock, or its terminal's folder
            if sum.loop != nil, let dir = ws.paddocks.first(where: { $0.id == w.paddockId })?.path
                ?? ws.terminals.first(where: { $0.id == w.terminalId })?.cwd {
                sum.loop = await LoopStats.counted(work: w, git: LoopRevertGit(dir: URL(fileURLWithPath: dir)))
            }
            var o: [String: JSONValue] = ["summary": try isoJSON(sum), "markdown": .string(sum.markdown()), "natural": .bool(false)]
            if flag(r, "natural") {
                let (text, reason) = await assistant.rewrite(sum, workId: w.id)
                if let text { o["natural"] = .bool(true); o["text"] = .string(text) } else if let reason { o["reason"] = .string(reason) }
            }
            return .object(o)

        case "work.assistant.status":
            if case .unavailable(let why) = await assistant.status() { return .object(["available": .bool(false), "reason": .string(why)]) }
            return .object(["available": .bool(true)])

        case "work.list":
            let iso = ISO8601DateFormatter()
            return .array(try await work.list(includeClosed: flag(r, "closed")).filter(visible).map { w in
                var o: [String: JSONValue] = [
                    "id": .string(w.id.uuidString.lowercased()), "title": .string(w.title), "openedAt": .string(iso.string(from: w.openedAt)),
                    "terminal": .string(ws.terminals.first { $0.id == w.terminalId }?.name ?? ""),
                    "openTasks": .number(Double(w.tasks.filter { $0.state == .open || $0.state == .inProgress }.count))]
                if let b = w.branch { o["branch"] = .string(b) }
                if let l = WorkStatusText.loopLine(w) { o["loop"] = .string(l) }
                if let c = w.closedAt { o["closedAt"] = .string(iso.string(from: c)); o["closedBy"] = .string(w.closedBy ?? "") }
                return .object(o)
            })

        case "work.get":
            return try isoJSON(try await byId(try need(r, "id")))

        case "work.history":   // T6.1: the caller's paddock's closed works only (the app: the paddock it names; none: the pasture)
            let limit = Int(try num(r, "limit", max: Double(Self.historyMax)) ?? Double(Self.historyDefault))
            let scope: String?
            if let caller { scope = caller.paddockId?.uuidString.lowercased() }
            else if let name = str(r, "paddock"), !name.isEmpty {
                guard let p = ws.paddocks.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id.uuidString.lowercased() == name.lowercased() })
                else { throw missing("Paddock '\(name)' not found") }
                scope = p.id.uuidString.lowercased()
            } else { scope = nil }
            let anyPaddock = caller == nil && str(r, "paddock") == nil && str(r, "id") != nil   // the app reading one by id
            let all = try await work.history { anyPaddock || $0.paddockId == scope }
            if let id = str(r, "id") {
                guard let a = all.first(where: { $0.id == id.lowercased() }) else { throw missing("no closed work \(id)") }
                return try isoJSON(a)
            }
            let rows = all.filter(\.listed).prefix(limit)   // M8.1: an empty work stays readable by id, never listed
            let iso = ISO8601DateFormatter()
            return .object(["history": .array(rows.map { a in
                var o: [String: JSONValue] = ["id": .string(a.id), "title": .string(a.title), "done": .number(Double(a.done)),
                                              "total": .number(Double(a.tasks.count)), "deferred": .number(Double(a.deferred)),
                                              "durationSeconds": .number(Double(a.durationSeconds))]
                if let d = a.openedAt { o["openedAt"] = .string(iso.string(from: d)) }
                if let d = a.closedAt { o["closedAt"] = .string(iso.string(from: d)) }
                if let s = a.stopReason { o["stopReason"] = .string(s) }
                if a.reconstructed { o["reconstructed"] = .bool(true) }
                return .object(o)
            }), "output": .string(rows.isEmpty ? "Nenhum trabalho fechado neste cercado." : rows.map { a in
                "\(RerailText.clean(a.title)) [\(a.id)] · \(a.done)/\(a.tasks.count) feitas · \(a.deferred) "
                    + (a.deferred == 1 ? "adiada" : "adiadas") + (a.stopReason.map { " · parou: \($0)" } ?? "")
                    + (a.reconstructed ? " · reconstruído" : "")
            }.joined(separator: "\n"))])

        case "work.handoff":   // M10.1: the caller's paddock's handoff file (the app: the paddock it names)
            let pid: UUID?
            if let caller { pid = caller.paddockId }
            else if let name = str(r, "paddock"), !name.isEmpty {
                guard let p = ws.paddocks.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id.uuidString.lowercased() == name.lowercased() })
                else { throw missing("Paddock '\(name)' not found") }
                pid = p.id
            } else { pid = nil }
            let text = pid.flatMap { id in
                (try? Data(contentsOf: Handoff.file(root: config.paths.root, paddock: id))).flatMap { $0.count <= 2 * Handoff.maxBytes ? String(data: $0, encoding: .utf8) : nil }
            }
            return .object(["output": .string(text ?? Handoff.none), "exists": .bool(text != nil)])

        case "work.usage":   // M5.4: the caller's paddock's newest works with their token counts only; M10.3: a closed
            // one from its summary (`work.history`'s files, the same paddock scope), an open one from the registry
            let t = try target(), limit = Int(try num(r, "limit", max: 100) ?? 10)
            let scope = (caller?.paddockId ?? t.paddockId)?.uuidString.lowercased(), only = str(r, "id")?.lowercased()   // closed: the caller's own paddock, as work.history
            let open = try await work.list(includeClosed: false).filter { visible($0) && $0.paddockId == t.paddockId }.map { w in
                var a = WorkArchive.make(w, paddock: nil, terminal: nil, loopSummary: ""); a.closedAt = nil; return a
            }
            let closed = try await work.history { $0.paddockId == scope }
            let openIds = Set(open.map(\.id))
            let all: [WorkArchive] = open + closed.filter { !openIds.contains($0.id) }
            let picked: [WorkArchive] = all.filter { (a: WorkArchive) -> Bool in only.map { a.id.hasPrefix($0) } ?? true }
            let works = picked.sorted { ($0.openedAt ?? .distantPast) > ($1.openedAt ?? .distantPast) }.prefix(limit)
            if let only, works.isEmpty { throw missing("no work \(only) in this paddock") }
            func row(_ c: TokenCount?) -> [String: JSONValue] {
                c.map { ["tokens": (try? isoJSON($0)) ?? .null, "index": .number($0.index)] } ?? [:]
            }
            return .object(["works": .array(works.map { w in
                var o: [String: JSONValue] = ["id": .string(w.id), "title": .string(RerailText.clean(w.title)),
                                              "closed": .bool(w.closedAt != nil),
                                              "tasks": .array(w.tasks.filter { $0.tokens != nil }.map { t in
                                                  var to: [String: JSONValue] = ["id": .string(t.id), "title": .string(RerailText.clean(t.title))]
                                                  to.merge(row(t.tokens)) { a, _ in a }
                                                  if let at = t.attempts, !at.isEmpty { to["attempts"] = (try? isoJSON(at)) ?? .null }
                                                  return .object(to)
                                              })]
                o.merge(row(w.tokens)) { a, _ in a }
                return .object(o)
            }), "output": .string(WorkStatusText.usage(Array(works)))])

        case "work.rerail":   // the app (any terminal) or a Shepherd (itself or one it reaches); never automatic
            guard caller?.isShepherd ?? true else { throw ProtocolError(code: .unauthorized, message: "'work.rerail' is for the app and Shepherds") }
            let t = try target()
            guard let w = try await work.active(terminal: t.id) else { throw invalid("no active work") }
            return try await rerail(t, w, now: now, wait: t.id != caller?.id)

        case "work.run": return try await workRun(r, caller: caller, starter: try target())
        case "work.stop": return try await workStop(try target())

        case "work.config": return try workConfig(try target())   // M13.1: read only, runs nothing
        case "factory.doctor":   // U3: routed here for the same reach rules; read only, runs nothing
            return try factoryDoctor(try target(), min: Int(try num(r, "min", min: 0, max: 3) ?? 1))
        case "factory.bait.list", "factory.bait.report":   // U4: read only, runs nothing
            return try factoryBait(try target(), report: r.command == "factory.bait.report")
        case "factory.ratchet.check", "factory.ratchet.update", "factory.ratchet.raise":   // U5: runs the ratchet's measure once
            let action = FactoryRatchet.Action(rawValue: String(r.command.dropFirst("factory.ratchet.".count)))!
            return try await factoryRatchet(try target(), action, name: try text("name"), reason: str(r, "reason"))

        case "work.clear-history":   // the one way anything is deleted: the user's alone
            guard caller == nil else { throw ProtocolError(code: .unauthorized, message: "'work.clear-history' is admin-only") }
            try await work.clearHistory()
            return .object([:])

        default:
            throw invalid("Unknown command '\(r.command)'")
        }
    }

    /// `work history --limit`: its default and the most it takes.
    static let historyDefault = 20, historyMax = 50

    /// T6.1: what a work's summary names: its paddock and its terminal (nil: gone, or none).
    func archiveNames(_ w: Work) -> (paddock: String?, terminal: String?) {
        (ws.paddocks.first { $0.id == w.paddockId }?.name, ws.terminals.first { $0.id == w.terminalId }?.name)
    }

    /// `work status --events` with no number.
    static let loopEventsDefault = 20
    /// `work wait --timeout`: its default and the most it takes (seconds).
    static let workWaitDefault: Double = 600, workWaitMax: Double = 3600

    /// What `work.status` answers for `works` (`work.wait` answers the same, plus its own keys): `works`, the text in
    /// `output` and, with `events` (the last N of each loop's journal), `events` by work id.
    private func workStatus(_ works: [Work], events last: Int?, now: Date) throws -> [String: JSONValue] {
        var o: [String: JSONValue] = ["works": .array(try works.map(isoJSON))]
        o["output"] = .string(works.isEmpty ? "No active work." : works.map { w in
            let journal = last.flatMap { n in w.loop.map { WorkStatusText.events($0, last: n) } } ?? ""
            return workSummary(w, now: now) + (journal.isEmpty ? "" : "\nDiário do laço:\n" + journal)
        }.joined(separator: "\n\n"))
        if let last {
            o["events"] = .object(Dictionary(uniqueKeysWithValues: try works.filter { $0.loop != nil }.map {
                ($0.id.uuidString.lowercased(), try isoJSON(Array(($0.loop?.events ?? []).suffix(last))))
            }))
        }
        return o
    }

    /// `work.wait`'s wait: until the store writes a change of the work past `since`, or `timeout` seconds pass (a
    /// one-shot timer cancels the wait: no polling), or this request's task is cancelled.
    private func workChanged(_ id: UUID, since: Int, timeout: Double) async throws -> Int? {
        let store = work
        let wait = Task { try await store.changed(id, since: since) }
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { wait.cancel() }
        timer.resume()
        defer { timer.cancel() }
        return try await withTaskCancellationHandler { try await wait.value } onCancel: { wait.cancel() }
    }

    /// The `work.status` text: the work, its tasks by state (done ones last, the 5 newest), live jobs, the 5 newest notes and commits.
    private func workSummary(_ w: Work, now: Date) -> String {
        let who = ws.terminals.first { $0.id == w.terminalId }?.name ?? "?"
        var lines = ["\(w.title) — \(who)" + (w.branch.map { ", branch \($0)" } ?? "") + (w.closedBy.map { ", closed by \($0)" } ?? "")
                     + " [\(w.id.uuidString.lowercased())]"]
        if let l = WorkStatusText.loopLine(w, now: now) { lines.append(l) }
        lines += WorkStatusText.laneLines(w, now: now)   // M3.6: none without lanes
        if let g = WorkStatusText.gateLine(w) { lines.append(g) }
        if let n = WorkStatusText.notifyLine(w) { lines.append(n) }
        if let n = WorkStatusText.modelLine(w) { lines.append(n) }   // M5.6
        if let n = WorkStatusText.reviewLine(w) { lines.append(n) }   // F2 R1
        lines += WorkStatusText.originLines(w)   // A1: none without a factory profile
        if let n = WorkStatusText.statsLine(w) { lines.append(n) }
        if let n = WorkStatusText.tokensLine(w) { lines.append(n) }   // M5.4
        let groups: [(TaskState, String)] = [(.inProgress, "In progress"), (.open, "Open"), (.deferred, "Deferred"),
                                             (.abandoned, "Dropped"), (.done, "Done")]
        for (state, label) in groups {
            let ts = w.tasks.filter { $0.state == state }
            guard !ts.isEmpty else { continue }
            lines.append("\(label) (\(ts.count)):")
            lines += ts.suffix(state == .done ? 5 : 50).map { "  - " + (WorkStatusText.doneLine($0) ?? $0.title + ($0.reason.map { " — \($0)" } ?? "")) + WorkStatusText.workerLabel($0) + " [\($0.id)]" }
        }
        let jobs = w.jobs.filter { $0.state == .running || $0.state == .unknown }
        if !jobs.isEmpty { lines.append("Jobs:"); lines += jobs.map { "  - \($0.kind.rawValue) \($0.label) (\($0.state.rawValue))" } }
        if !w.notes.isEmpty { lines.append("Notes:"); lines += w.notes.suffix(5).map { "  - " + ($0.decision ? "decision: " : "") + $0.text } }
        if !w.commits.isEmpty { lines.append("Commits:"); lines += w.commits.suffix(5).map { "  - \($0)" } }
        return lines.joined(separator: "\n")
    }

    /// A branch name git accepts for a new branch (`check-ref-format --branch`, which also resolves `@{-1}`: refused), not `HEAD`.
    static func validBranch(_ b: String, in dir: URL) async -> Bool {
        guard b != "HEAD", !b.hasPrefix("-") else { return false }
        let cwd = FileManager.default.fileExists(atPath: dir.path) ? dir : URL(fileURLWithPath: "/")
        guard let r = try? await GitRunner.run(["check-ref-format", "--branch", b], in: cwd, timeout: .seconds(10)) else { return false }
        return r.status == 0 && r.stdout.trimmingCharacters(in: .newlines) == b
    }

    /// The terminal was removed for good: its active work closes (`removed`; `work.reopen --id` undoes it). Never fails.
    func closeRemoved(terminal: UUID, cwd: String? = nil) async {
        do {
            if let w = try await work.active(terminal: terminal) {
                closeCwd[w.id] = cwd   // the terminal is already gone from `ws`: the summary needs its repo
                try await work.close(w.id, by: "removed")
            }
            workStoreBroken = false
        } catch { workFailed("remove close", error) }
    }

    /// After a land: the active works of the paddock (by branch only for works without a paddock) are closed by the merge.
    /// Never fails the land.
    func closeMerged(_ f: Paddock) async {
        do {
            for w in try await work.list(includeClosed: false) where w.paddockId.map({ $0 == f.id }) ?? (w.branch == f.gitBranch) {
                let lot = ws.lot(of: w.terminalId)?.id
                try await work.update(w.id) { if $0.closedAt == nil { $0.closedAt = Date(); $0.closedBy = "merge"; $0.lotId = lot } }
            }
            workStoreBroken = false
        } catch { workFailed("land close", error) }
    }

    /// On `Stop`: the active work takes its branch's new commits (those not in its destination: the paddock's base branch,
    /// else the pasture's current branch; at most 20 a time) and, once the newest of them is in the destination, it closes
    /// by merge. A work without a branch never closes by itself.
    func workTurnEnded(_ tid: UUID) async {
        guard let me = ws.terminals.first(where: { $0.id == tid }) else { return }
        do {
            guard let w = try await work.active(terminal: tid) else { workStoreBroken = false; return }
            workStoreBroken = false
            let base = ws.paddocks.first { $0.id == w.paddockId }?.baseBranch
            let (commits, merged) = await Self.gitTurn(w, dir: URL(fileURLWithPath: me.cwd), base: base)
            guard !commits.isEmpty || merged else { return }
            let lot = ws.lot(of: tid)?.id
            try await work.update(w.id) { x in
                guard x.closedAt == nil else { return }
                x.commits += commits.filter { !x.commits.contains($0) }   // a concurrent Stop may have added them
                if merged { x.closedAt = Date(); x.closedBy = "merge"; x.lotId = lot }
            }
            if merged { await captureConversationNow(tid) }
        } catch { workFailed("turn end", error) }
    }

    /// Git for `workTurnEnded`, bounded (10 s a call); a failure (not a repo, unknown branch) is no commits / not merged.
    private static func gitTurn(_ w: Work, dir: URL, base: String?) async -> (commits: [String], merged: Bool) {
        func git(_ a: [String]) async -> String? {
            do {
                let r = try await GitRunner.run(a, in: dir, timeout: .seconds(10))
                return r.status == 0 && !r.truncated ? r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            } catch { workLog("git \(a.first ?? ""): \(error.message)"); return nil }
        }
        // ponytail: a work without a branch records no commits: its destination would be the current branch, so
        // `dest..HEAD` is empty, and what lands there is not known to be its own. Give it a branch to track commits.
        guard let branch = w.branch else { return ([], false) }
        var dest = base
        if dest == nil { dest = await git(["symbolic-ref", "--short", "-q", "HEAD"]) }
        guard let dest, !dest.isEmpty, dest != branch else { return ([], false) }
        // only the branch's own commits: a branch merely synced with the destination has none, so it never looks merged
        let sha = { (c: String) in String(c.split(separator: " ").first ?? "") }
        let stored = w.commits.map(sha)
        func known(_ c: String) -> Bool { let h = sha(c); return stored.contains { $0.hasPrefix(h) || h.hasPrefix($0) } }   // %h may grow
        let out = await git(["log", "--no-show-signature", "-n", "20", "--reverse", "--format=%h %s", "\(dest)..\(branch)", "--"])
        let commits = (out ?? "").split(separator: "\n").map { String($0.prefix(200)) }.filter { !known($0) }
        guard let newest = (w.commits + commits).last.map(sha), !newest.isEmpty,
              await git(["merge-base", "--is-ancestor", newest, dest]) != nil else { return (commits, false) }
        return (commits, true)
    }
}

func workLog(_ m: String) { FileHandle.standardError.write(Data("collied: work: \(m)\n".utf8)) }
