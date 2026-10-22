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
        let events = WorkHookParser.events(hook: str(r, "hook") ?? "", json: Data((str(r, "payload") ?? "").utf8), now: now)
        guard !events.isEmpty else { return }
        do {
            var w = try await work.active(terminal: tid)
            if w == nil {
                guard events.contains(where: Self.opensWork), let me = ws.terminals.first(where: { $0.id == tid }) else { return }
                w = try await implicitWork(me, now: now)
            }
            guard let w else { return }
            try await work.update(w.id) { Self.apply(events, to: &$0, now: now) }
            workStoreBroken = false
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
        do { return try await work.start(title: "\(me.name) — \(now.formatted(day))", terminal: me.id, paddockId: paddock?.id, branch: paddock?.branch) }
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

    /// Running, or `unknown` after a silence: a real end signal still finishes it.
    private static func endable(_ j: WorkJob) -> Bool { j.state == .running || j.state == .unknown }

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
            for i in w.jobs.indices where w.jobs[i].state == .running {
                guard let s = verdict(w.jobs[i]) else { continue }
                w.jobs[i].state = s
                if s == .gone { w.jobs[i].endedAt = now }
            }
        }
        do {
            let all = try await work.list(includeClosed: true)
            workStoreBroken = false
            for w in all where which(w) && w.jobs.contains(where: { $0.state == .running }) {
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
            let w = try await work.start(title: try text("title"), terminal: t.id, paddockId: paddock?.id, branch: branch ?? paddock?.branch)
            return .object(["id": .string(w.id.uuidString.lowercased())])

        case "work.done":   // --id: any work the caller sees, also one whose terminal was removed
            let w = if let s = str(r, "id") { try await byId(s) } else { try await active(try target()) }
            guard w.closedAt == nil else { throw invalid("work \(w.id.uuidString.lowercased()) is already closed") }
            let reason = str(r, "reason") == nil ? nil : try text("reason")
            try await work.update(w.id) {
                if let reason { $0.notes.append(WorkNote(at: now, text: "Done: \(reason)")) }
                $0.closedAt = now; $0.closedBy = by
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
            let w = try await implicitWork(t, now: now)
            let task = WorkTask(id: String(UUID().uuidString.prefix(8)).lowercased(), title: title, updatedAt: now)
            try await work.update(w.id) { $0.tasks.append(task) }
            return try isoJSON(task)

        case "work.task.done", "work.task.defer", "work.task.drop":
            let t = try target()
            let (state, reason): (TaskState, String?) = switch r.command {
            case "work.task.done": (.done, nil)
            case "work.task.defer": (.deferred, try text("reason"))
            default: (.abandoned, try text("reason"))
            }
            let w = try await active(t), key = try text("task")
            // the id first, then the title (case-insensitive)
            let hits = w.tasks.contains { $0.id == key } ? w.tasks.filter { $0.id == key }
                : w.tasks.filter { $0.title.caseInsensitiveCompare(key) == .orderedSame }
            guard hits.count <= 1 else { throw ProtocolError(code: .ambiguous, message: "Multiple tasks titled '\(key)'; use its id") }
            guard var task = hits.first else { throw missing("no task '\(key)' in the active work") }
            task.state = state; task.reason = reason; task.updatedAt = now
            let done = task
            try await work.update(w.id) { x in if let i = x.tasks.firstIndex(where: { $0.id == done.id }) { x.tasks[i] = done } }
            return try isoJSON(done)

        case "work.note":
            let t = try target(), note = WorkNote(at: now, text: try text("text"), decision: flag(r, "decision"))
            let w = try await implicitWork(t, now: now)
            try await work.update(w.id) { $0.notes.append(note) }
            return .object([:])

        case "work.status":
            let works = flag(r, "all") ? try await work.list(includeClosed: false).filter(visible)
                : try await work.active(terminal: try target().id).map { [$0] } ?? []
            return .object(["output": .string(works.isEmpty ? "No active work." : works.map(workSummary).joined(separator: "\n\n")),
                            "works": .array(try works.map(isoJSON))])

        case "work.summary":   // same reach as work.status; `--natural`: the on-device model's rewrite, the markdown always
            let w = if let s = str(r, "id") { try await byId(s) } else { try await active(try target()) }
            let sum = WorkSummary.make(w, terminalAlive: await registry.process(w.terminalId)?.isRunning == true, now: now)
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
                if let c = w.closedAt { o["closedAt"] = .string(iso.string(from: c)); o["closedBy"] = .string(w.closedBy ?? "") }
                return .object(o)
            })

        case "work.get":
            return try isoJSON(try await byId(try need(r, "id")))

        case "work.rerail":   // the app (any terminal) or a Shepherd (itself or one it reaches); never automatic
            guard caller?.isShepherd ?? true else { throw ProtocolError(code: .unauthorized, message: "'work.rerail' is for the app and Shepherds") }
            let t = try target()
            guard let w = try await work.active(terminal: t.id) else { throw invalid("no active work") }
            return try await rerail(t, w, now: now, wait: t.id != caller?.id)

        case "work.clear-history":   // the one way anything is deleted: the user's alone
            guard caller == nil else { throw ProtocolError(code: .unauthorized, message: "'work.clear-history' is admin-only") }
            try await work.clearHistory()
            return .object([:])

        default:
            throw invalid("Unknown command '\(r.command)'")
        }
    }

    /// The `work.status` text: the work, its tasks by state (done ones last, the 5 newest), live jobs, the 5 newest notes and commits.
    private func workSummary(_ w: Work) -> String {
        let who = ws.terminals.first { $0.id == w.terminalId }?.name ?? "?"
        var lines = ["\(w.title) — \(who)" + (w.branch.map { ", branch \($0)" } ?? "") + (w.closedBy.map { ", closed by \($0)" } ?? "")
                     + " [\(w.id.uuidString.lowercased())]"]
        let groups: [(TaskState, String)] = [(.inProgress, "In progress"), (.open, "Open"), (.deferred, "Deferred"),
                                             (.abandoned, "Dropped"), (.done, "Done")]
        for (state, label) in groups {
            let ts = w.tasks.filter { $0.state == state }
            guard !ts.isEmpty else { continue }
            lines.append("\(label) (\(ts.count)):")
            lines += ts.suffix(state == .done ? 5 : 50).map { "  - \($0.title)" + ($0.reason.map { " — \($0)" } ?? "") + " [\($0.id)]" }
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
            for w in try await work.list(includeClosed: false) where w.paddockId.map({ $0 == f.id }) ?? (w.branch == f.branch) {
                try await work.update(w.id) { if $0.closedAt == nil { $0.closedAt = Date(); $0.closedBy = "merge" } }
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
            try await work.update(w.id) { x in
                guard x.closedAt == nil else { return }
                x.commits += commits.filter { !x.commits.contains($0) }   // a concurrent Stop may have added them
                if merged { x.closedAt = Date(); x.closedBy = "merge" }
            }
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
