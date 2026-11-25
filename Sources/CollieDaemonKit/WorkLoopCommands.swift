import Foundation
import CryptoKit
import os
import CollieCore
import CollieProtocol

/// `collie work run` / `collie work stop`: the caller's active work run by a `WorkLoop` in the daemon.
extension CommandRouter {
    /// Hard ceilings (the owner may raise them later): attempts per task, attempts in all (`--max`, required), a turn,
    /// and the time budget of all turns and checks.
    static let loopTriesMax = 10.0, loopMaxMax = 30.0, loopTimeoutMax = 14_400.0, loopBudgetMax = 43_200.0
    static let loopBudgetDefault = 14_400.0, loopCardMax = 1500

    /// `starter`: the terminal whose active work runs (the caller, or `--terminal` from the app); it must be a Shepherd,
    /// since the loop summons agents as it. Returns at once; the starter gets one line when the loop ends.
    func workRun(_ r: Request, caller: TerminalRecord?, starter t: TerminalRecord) async throws -> JSONValue {
        func invalid(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        guard caller?.isShepherd ?? true, t.isShepherd else {
            throw ProtocolError(code: .notShepherd, message: "'work.run' is for Shepherds (and the app, on a Shepherd's work): a loop summons agents")
        }
        // a terminal sandbox in force (`sandboxHome`): the loop never acts for a terminal that runs without one
        guard config.sandboxHome == nil || sandboxed(t) else {
            throw invalid("'\(t.name)' runs without a sandbox: a loop's agents, check and git all run sandboxed; start it from a sandboxed Shepherd")
        }
        guard let pid = t.paddockId, let paddock = ws.paddocks.first(where: { $0.id == pid }), !paddock.isFolder else {
            throw invalid("'\(t.name)' is not in a paddock: a loop resets its worktree between attempts; ask the owner for a paddock")
        }
        // A5: `--queue` runs nothing now: it only waits, approved, for a chain (no reservation, no idle paddock needed)
        let queue = flag(r, "queue")
        if queue, !flag(r, "auto-land") { throw invalid("--queue needs --auto-land: only an auto-land chain runs a queued work") }
        if r.args["auto-land-max"] != nil, !flag(r, "auto-land") { throw invalid("--auto-land-max needs --auto-land") }
        let landMax = try num(r, "auto-land-max", max: Double(WorkLoopState.AutoLand.maxMax)).map(Int.init)
        // reserved before the first await: a concurrent work.run (actor reentrancy) finds it taken
        guard queue || !loopPaddocks.contains(pid) else {
            throw invalid("a loop is already running in paddock '\(paddock.name)'; collie work status shows it; collie work stop, from the terminal that started it, ends it")
        }
        if !queue { loopPaddocks.insert(pid) }
        var started = false
        defer { if !started && !queue { loopPaddocks.remove(pid) } }
        guard let max = try num(r, "max", max: Self.loopMaxMax).map(Int.init) else {
            throw invalid("--max is required: the attempts the loop may use in all (1-\(Int(Self.loopMaxMax)))")
        }
        guard let w = try await work.active(terminal: t.id) else {
            throw invalid("no active work for '\(t.name)'; start one: collie work start <title>")
        }
        guard w.paddockId == pid else {
            throw invalid("work '\(w.title)' is not in a paddock: a loop resets its worktree between attempts; ask the owner for a paddock")
        }
        let open = w.tasks.filter { $0.state == .open }
        guard !open.isEmpty else { throw invalid("no open task in '\(w.title)'; add some: collie work task add <title> --spec <file> --check <command>") }
        let unchecked = w.tasks.filter { ($0.state == .open || $0.state == .inProgress) && $0.check == nil }
        guard unchecked.isEmpty else {
            throw invalid("every open task needs a --check; these have none: " + unchecked.map { "\"\($0.title)\" [\($0.id)]" }.joined(separator: ", "))
        }
        // F5: a work with a PRD runs the plan the owner approved, still passing the linter
        if let why = Self.prdPlanRefusal(w) { throw invalid(why) }
        // M7.2 (A2): a closed work's loop may still run (M6.4: it ends at its next wake, after its lanes): it holds the paddock too
        let others = try await work.list(includeClosed: true).filter { $0.paddockId == paddock.id }
        if workLoops[w.id] != nil || (!queue && others.contains(where: { $0.loop?.state == .running })) {
            throw invalid("a loop is already running in paddock '\(paddock.name)'; collie work status shows it; collie work stop, from the terminal that started it, ends it")
        }
        for o in ws.terminals where !queue && o.paddockId == paddock.id && o.id != t.id && !o.isShepherd && Self.loopSharesWorktree(o, URL(fileURLWithPath: paddock.path)) {
            if await targetBusy(o.id) {
                throw invalid("'\(o.name)' is working in paddock '\(paddock.name)': the loop needs the worktree to itself; wait for it, or run the loop in its own paddock")
            }
        }
        let dir = URL(fileURLWithPath: paddock.path)
        let st = try await GitRunner.run(["status", "--porcelain", "--untracked-files=no"], in: dir, timeout: .seconds(30))
        guard st.status == 0 else { throw invalid("'\(paddock.path)' is not a git worktree") }
        let dirty = st.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard queue || dirty.isEmpty else { throw invalid("tracked files are dirty in paddock '\(paddock.name)'; commit or discard them first:\n\(dirty.prefix(500))") }

        // the summon's own checks run again per attempt; these only save three failed attempts
        if let p = str(r, "preset") { _ = try Preset.parse(p) }
        if let m = str(r, "model") { try ClaudeModel.validate(m) }
        let escalate = try Self.parseEscalate(str(r, "escalate"), excludes: ["preset", "model", "command"].filter { str(r, $0) != nil })
        // absent: no gate; given: a command (an empty one is a mistake, never "no gate")
        let gateFlag = str(r, "gate")
        if let gateFlag, gateFlag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw invalid("--gate is empty: give the command that runs after every task's check, or leave --gate out")
        }
        // M10.2: the same for the pre-check (absent: none, the loop as before)
        let precheckFlag = str(r, "precheck")
        if let precheckFlag, precheckFlag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw invalid("--precheck is empty: give the command that runs at the end of each turn, before the check, or leave --precheck out")
        }
        // M13.2: a flag left out takes the paddock's collie-work.json; no file or an invalid one: today's defaults (none),
        // and an invalid one a one-line warning in the reply, never a refusal. M13.3: the file as committed at HEAD now
        // (the loop's base), never the tree's: an agent's edit, committed or not, never picks the gate
        // A1: read always now (the `factory` block applies whatever the flags); its warnings only when a flag was left out,
        // as before. An invalid `factory` is the one refusal, before the card.
        // B1: its warnings always now (a file ignored drops the review, budget and tries too, flags or not)
        let file = await Self.loopFileDefaults(dir)
        if let refusal = file.refusal { throw invalid(refusal) }
        let fileConfig = file.config, factory = file.config?.factory
        let gate = gateFlag ?? fileConfig?.gate, precheck = precheckFlag ?? fileConfig?.precheck
        let from = (gate: gateFlag == nil && gate != nil, precheck: precheckFlag == nil && precheck != nil)
        // M3.5: absent is 1 (the loop as always); more runs tasks in lanes, which exist only sandboxed and are named by
        // the task's id
        let parallel = try num(r, "parallel", max: Double(TaskScheduler.maxParallel)).map { Int($0) }
        if let parallel, parallel > 1 {
            guard config.sandboxHome != nil else { throw invalid("--parallel needs the terminal sandbox: a lane's agent, check and git run only sandboxed") }
            for t in open { try LaneWorktree.validate(task: t.id) }
        }
        let notify = try Self.loopNotify(str(r, "notify"))
        // A1: an explicit flag wins over the profile, the profile over the engine's default
        let reviewFlag = flag(r, "review"), noReview = flag(r, "no-review")
        if reviewFlag && noReview { throw invalid("--review and --no-review together: choose one") }
        let fromProfile = factory != nil && file.reviewPresent && !reviewFlag && !noReview
        let review = try await Self.loopReview(review: reviewFlag || fromProfile, personas: str(r, "personas"), reviewerModel: str(r, "reviewer-model"), dir: dir,
                                               fromProfile: fromProfile, only: fromProfile ? factory?.personas ?? [] : [])
        let triesFlag = try num(r, "tries", max: Self.loopTriesMax), budgetFlag = try num(r, "budget", max: Self.loopBudgetMax)
        // ponytail: the profile allows a budget up to 86400 s, the engine's ceiling is lower: capped, not refused
        let profileBudget = factory?.budgetSeconds.map { min(Double($0), Self.loopBudgetMax) }
        // C5a: an agent with no end of turn (a shell, given or the Shepherd's) would hold the paddock until the turn's timeout
        if escalate == nil, Self.loopAgentRefused(preset: str(r, "preset"), command: str(r, "command"), shepherd: t) { throw invalid(Self.loopAgentRefusal) }
        var loop = WorkLoopState(state: .running, tries: Int(triesFlag ?? factory?.maxTries.map(Double.init) ?? 3),
                                 timeout: Int(try num(r, "timeout", max: Self.loopTimeoutMax) ?? 3600),
                                 preset: str(r, "preset"),
                                 model: escalate != nil ? nil : Self.loopModel(given: str(r, "model"), preference: CollieSettings.load(config.paths.root).loopModel,
                                                       preset: str(r, "preset"), command: str(r, "command"), shepherd: t),
                                 command: str(r, "command"),
                                 max: max, used: 0, budget: Int(budgetFlag ?? profileBudget ?? Self.loopBudgetDefault),
                                 spent: 0, tasks: open.map(\.id), gate: gate, startedAt: Date(), parallel: parallel, notify: notify, precheck: precheck,
                                 review: review.on ? true : nil, personas: review.personas, reviewerModel: review.reviewerModel,
                                 escalate: escalate)
        var warning = file.warning
        // B1: the profile asks for a review the flag turned off: the card and the trusted notice say so
        let profileReviewOff = factory != nil && file.reviewPresent && noReview
        if let factory {
            func origin(_ flag: Bool, _ profile: Bool) -> String { flag ? "flag" : profile ? "perfil" : "padrão" }
            loop.origins = ["review": origin(reviewFlag || noReview, file.reviewPresent), "budget": origin(budgetFlag != nil, profileBudget != nil),
                            "tries": origin(triesFlag != nil, factory.maxTries != nil)]
            if review.on, file.reviewPresent, review.personas == nil, !factory.personas.isEmpty { loop.reviewOnly = factory.personas }
            // C1 (B1-a): the profile's persona names are checked whenever it is read, not only when they pick the review
            // (`loopReview` refuses those): an unknown one off the review is a warning, here and in `work status`
            if !fromProfile, !factory.personas.isEmpty {
                let known = await Self.committedPersonas(dir), bad = factory.personas.filter { !known.contains($0) }
                if !bad.isEmpty {
                    let names = bad.map { RerailText.clean($0, max: 60) }.joined(separator: ", ")
                    loop.origins?["unknownPersonas"] = names
                    warning = [warning, WorkStatusText.unknownPersonasLine(names)].compactMap { $0 }.joined(separator: "; ")
                }
            }
            if review.on, file.reviewPresent { loop.reviewThreshold = factory.threshold.rawValue }
            if !factory.destructive.isEmpty { loop.destructive = factory.destructive.count }
            // nit (B1): the engine's ceiling cuts the profile's budget; `work status` says so
            if let b = factory.budgetSeconds, Double(b) > Self.loopBudgetMax, budgetFlag == nil { loop.origins?["budgetCut"] = String(b) }
            // A4: auto-land only by --auto-land; the profile's land alone only warns
            if factory.land == .factoryPaddock, !flag(r, "auto-land") {
                let w = paddock.factory ? "aviso: factory.guardrails.land é 'factory-paddock'; o auto-land só liga com work run --auto-land; segue manual"
                    : "aviso: factory.guardrails.land é 'factory-paddock', mas o cercado não tem a marca de fábrica; o laço segue como 'manual'"
                warning = [warning, w].compactMap { $0 }.joined(separator: "; ")
            }
        }
        // A4: `--auto-land`, refused unless the paddock is a factory's, the committed profile has a gate and the review is on
        if flag(r, "auto-land") {
            loop.autoLand = try Self.loopAutoLand(factory: paddock.factory, config: fileConfig, review: review.on, noReview: noReview, max: landMax)
            // C3b: the base the work's last attempt began on stays the reference until a new attempt takes its own
            loop.autoLand?.baseHead = w.loop?.autoLand?.baseHead
        }
        if queue { loop.state = .queued }
        // the owner approves the tasks, their checks, the gate and the limits on a card; until then nothing runs
        guard let text = Self.loopCardText(w, open, loop, paddock: paddock.name, fromFile: from, profileReviewOff: profileReviewOff) else {
            throw invalid("the owner's approval card would not fit (\(Self.loopCardMax) characters) all \(open.count) tasks, their checks and the gate; "
                          + "shorten the checks (a script in the repo: --check 'scripts/check-x.sh') or split the work into smaller loops")
        }
        // C2: a check that already passes at the cercado's HEAD measures nothing: refused before anything reaches the card
        if let why = await alreadyGreen(open, work: w.id, paddock: paddock, starter: t.id, dir: dir) { throw invalid(why) }
        let id = w.id, starter = t.id, title = w.title
        // a paddock the owner trusts for loops (read now, after the awaits): no card. Everything above held all the same
        // (the limits, the sandbox, the idle paddock, the clean tree, the text that fits a card); the Shepherd gets a notice.
        if ws.paddocks.first(where: { $0.id == pid })?.trustLoops == true {
            if queue {
                var l = loop; l.autoLand?.approvedAt = Date()   // C3b: the trusted paddock's run is the approval
                try await work.update(id) { $0.loop = l }
                return Self.runReply(["id": .string(w.id.uuidString.lowercased()), "tasks": .number(Double(open.count)), "state": .string("queued")], warning)
            }
            guard await startLoop(id, loop, paddock: paddock, starter: starter, dir: dir) else {
                throw ProtocolError(code: .unavailable, message: "the loop did not start")
            }
            started = true   // the reservation now belongs to the loop
            let notice = WorkStatusText.loopTrusted(paddock: paddock.name, open, loop, gateFromFile: from.gate, profileReviewOff: profileReviewOff)
            Task { [weak self] in try? await self?.asks.inject(to: starter, prompt: notice, afterQuiet: true) }
            return Self.runReply(["id": .string(w.id.uuidString.lowercased()), "tasks": .number(Double(open.count)), "state": .string("running")], warning)
        }
        let card = AppCard(kind: .confirm, paddock: pid, paddockName: paddock.name, app: "work-loop", name: "Laço autônomo",
                           base: nil, call: text, command: "run", by: t.id)
        started = true   // the reservation now belongs to the approval
        loopCards[id] = card.id
        Task { [weak self] in
            guard let self else { return }
            let allowed = await self.confirmCard(card, wait: self.config.loopCardWait)
            let withdrawn = await self.takeLoopCard(id)
            guard allowed, !withdrawn else {
                await self.loopDenied(paddock: queue ? nil : pid, starter: starter, title: title, withdrawn: withdrawn)
                return
            }
            // C3b: the queue's order is the card's answer (`approvedAt`), not the run's `startedAt`
            if queue { var l = loop; l.autoLand?.approvedAt = Date(); try? await self.work.update(id) { $0.loop = l }; return }
            await self.startLoop(id, loop, paddock: paddock, starter: starter, dir: dir)
        }
        return Self.runReply(["id": .string(w.id.uuidString.lowercased()), "tasks": .number(Double(open.count)), "state": .string("awaiting approval")], warning)
    }

    /// A4: `--auto-land`'s settings from the profile committed at the base (`config`), or why it is refused.
    static func loopAutoLand(factory: Bool, config: ProjectWorkConfig?, review: Bool, noReview: Bool, max: Int? = nil) throws(ProtocolError) -> WorkLoopState.AutoLand {
        func invalid(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        guard factory else { throw invalid("--auto-land: o cercado não está marcado como fábrica (só o dono liga: collie paddock factory <nome> on)") }
        guard let gate = config?.gate else { throw invalid("--auto-land: o \(ProjectWorkConfig.fileName) commitado não tem 'gate'; o auto-land exige portão") }
        guard review, !noReview else { throw invalid("--auto-land exige revisão: tire --no-review ou ligue factory.review no perfil (ou use --review)") }
        return WorkLoopState.AutoLand(gate: gate, ci: config?.factory?.autolandCI ?? WorkLoopState.AutoLand.defaultCI,
                                      timeout: config?.factory?.autolandTimeout ?? WorkLoopState.AutoLand.defaultTimeout,
                                      max: max, perDay: config?.factory?.autoLandPerDay)
    }

    /// C2: the open tasks (not `--green-ok`) whose check exits 0 at the paddock's HEAD as it is now (the tree is clean: `work run`
    /// refused a dirty one), run as the loop runs it (its sandbox, its env, its timeout). nil: none; else the refusal naming them.
    /// A check that fails, times out or cannot run counts as red: it goes on.
    private func alreadyGreen(_ tasks: [WorkTask], work id: UUID, paddock: Paddock, starter: UUID, dir: URL) async -> String? {
        let todo = tasks.filter { $0.greenOk != true }
        guard !todo.isEmpty else { return nil }
        // the loop's own profile (made again by `startLoop`); removed when done, so a refusal leaves nothing behind
        if config.sandboxHome != nil { _ = try? prepareLoopSandbox(id, paddock: paddock) }
        defer { if config.sandboxHome != nil { SandboxLaunch.remove(id, root: config.paths.root) } }
        let host = RouterLoopHost(router: self, starter: starter, root: config.paths.root, work: id, paddock: paddock.id, dir: dir,
                                  sandbox: config.sandboxHome.map { (home: $0, shell: config.shell) })
        var green: [WorkTask] = []
        for task in todo {
            // ponytail: serial, the loop's own check timeout; a slow suite of checks delays `work run`, add parallelism if it bites
            if let res = try? await host.check(task.check ?? "false", in: dir, timeout: WorkLoop.defaultCheckTimeout), res.status == 0 { green.append(task) }
        }
        guard !green.isEmpty else { return nil }
        return "\(GreenCheck.reason): " + green.map { "\"\(RerailText.clean($0.title))\" [\($0.id)] check «\(RerailText.clean($0.check ?? "", max: 200))»" }.joined(separator: ", ")
            + ". \(GreenCheck.hint.prefix(1).uppercased() + GreenCheck.hint.dropFirst()) (collie work task add … \(GreenCheck.flag))"
    }

    /// M13.2: the paddock's `collie-work.json` for `work run`'s defaults. An absent file is nil with no warning, a refused or
    /// invalid one nil with its one-line warning (B1: always, flags or not). M13.3: read from the commit at
    /// HEAD (by its sha), never from the working tree. A1: read always; an invalid `factory` is `refusal` (the strict
    /// reader's line), never a warning; `reviewPresent`: the base's `factory` has a `review` key.
    static func loopFileDefaults(_ dir: URL) async -> (config: ProjectWorkConfig?, warning: String?, refusal: String?, reviewPresent: Bool) {
        let base = (try? await GitRunner.run(["rev-parse", "--verify", "-q", "HEAD^{commit}"], in: dir, timeout: .seconds(30)))?
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // review A2: the loop reads the commit, so an edit or a new file the owner has not committed is not what runs
        let dirty = (try? await GitRunner.run(["--literal-pathspecs", "status", "--porcelain", "--untracked-files=all", "--", ProjectWorkConfig.fileName],
                                              in: dir, timeout: .seconds(30)))?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let uncommitted = dirty.isEmpty ? nil : "aviso: \(ProjectWorkConfig.fileName) tem mudanças não commitadas; o laço usa a versão do commit (HEAD), sem elas"
        func ignored(_ m: String) -> String? {
            [uncommitted, "aviso: \(ProjectWorkConfig.fileName) ignorado, o laço usa os padrões (sem portão, pré-check, revisão, orçamento nem tentativas "
                + "vindos do arquivo): " + RerailText.clean(m, max: 300).replacingOccurrences(of: "\n", with: " ")].compactMap { $0 }.joined(separator: "; ")
        }
        switch await WorkConfigFile.read(base: base, dir: dir) {
        case .absent: return (nil, uncommitted, nil, false)
        case .refused(let m): return (nil, ignored(m), nil, false)
        case .loaded(let d):
            switch ProjectWorkConfig.parse(d) {
            case .success(let ok):
                let f = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["factory"] as? [String: Any]
                return (ok.config, uncommitted, nil, f?["review"] != nil)
            case .failure(.invalidFactory(let e)): return (nil, nil, RerailText.clean(e.message, max: 300).replacingOccurrences(of: "\n", with: " "), false)
            case .failure(let e): return (nil, ignored(e.message), nil, false)
            }
        }
    }

    private static func runReply(_ o: [String: JSONValue], _ warning: String?) -> JSONValue {
        var o = o
        if let warning { o["warning"] = .string(warning) }
        return .object(o)
    }

    /// C3: `--escalate a:m,b:m`: each entry `claude|cursor` + `:` + a model name (as `summon --model`), at most 10; nil: not given.
    /// `excludes`: the flags given beside it (`--preset/--model/--command`), which it replaces.
    static func parseEscalate(_ s: String?, excludes: [String]) throws -> [String]? {
        func bad(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        guard let s else { return nil }
        guard excludes.isEmpty else { throw bad("--escalate replaces --\(excludes.joined(separator: "/--")): give the agent and model in each entry (cursor:composer-2.5,claude:sonnet)") }
        let entries = s.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !entries.isEmpty, entries.count <= Int(loopTriesMax) else { throw bad("--escalate takes 1-\(Int(loopTriesMax)) entries agent:model") }
        for e in entries {
            let p = e.split(separator: ":", maxSplits: 1).map(String.init)
            guard p.count == 2, ["claude", "cursor"].contains(p[0]) else {
                throw bad("--escalate entry '\(e)' must be claude:<model> or cursor:<model>")
            }
            do { try ClaudeModel.validate(p[1]) } catch { throw bad(error.message) }
        }
        return entries
    }

    /// M5.6: `--model` given always wins; absent, the daemon's `loopModel`, but only for agents that run Claude (summon
    /// refuses `--model` for any other: a preference must never fail every attempt of a codex or shell loop); else nil,
    /// the Shepherd's model as before. The agent is the summon's: `--preset`, else the Shepherd's (with its command).
    static func loopModel(given: String?, preference: String?, preset: String?, command: String?, shepherd t: TerminalRecord) -> String? {
        if let given { return given }
        guard let preference, let p = preset.map({ Preset(rawValue: $0) }) ?? t.preset else { return nil }
        let probe = TerminalRecord(id: UUID(), name: "loop", preset: p, command: command ?? (preset == nil ? t.command : nil), cwd: "/", isShepherd: false)
        return p == .claude || AgentLaunch.isClaude(probe) ? preference : nil
    }

    /// C5a: why a loop's agent must end its turns.
    static let loopAgentRefusal = "o laço precisa de um agente com fim de turno (claude, codex ou cursor); passe --preset claude"

    /// C5a: the attempt's agent, as the summon resolves it (`--preset`, else the Shepherd's, with its command), would be a
    /// shell or a custom preset with no command: nothing that ends a turn. A command given (or the Shepherd's) is a
    /// program the owner named: it passes (decision: `--command` is the agent, whatever the preset).
    static func loopAgentRefused(preset: String?, command: String?, shepherd t: TerminalRecord) -> Bool {
        let p = preset.map { Preset(rawValue: $0) ?? .custom } ?? t.preset
        let c = command ?? (preset == nil ? t.command : nil)
        return (p == .shell || p == .custom) && (c ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// C5a: `loopAgentRefused` for a loop's summon as `starter` (gone: not refused here, the summon refuses).
    func loopAgentRefused(_ r: Request, as starter: UUID) -> Bool {
        guard let me = ws.terminals.first(where: { $0.id == starter }) else { return false }
        return Self.loopAgentRefused(preset: str(r, "preset"), command: str(r, "command"), shepherd: me)
    }

    /// `admin.loop-model` (app only): nil reads; "" clears; else a model id (`CollieSettings.isLoopModel`), saved.
    func setLoopModel(_ v: String?) throws -> JSONValue {
        var s = CollieSettings.load(config.paths.root)
        if let v {
            let m = v.trimmingCharacters(in: .whitespaces)
            guard m.isEmpty || CollieSettings.isLoopModel(m) else {
                throw ProtocolError(code: .invalidArgs, message: "model must be a model id (letters, digits, . _ : -, up to 64), or empty for the Shepherd's")
            }
            s.loopModel = m.isEmpty ? nil : m
            do { try s.save(config.paths.root) } catch { throw ProtocolError(code: .internal, message: "preferences.json: \(error)") }
        }
        return .object(["model": s.loopModel.map(JSONValue.string) ?? .null])
    }

    /// M5.1: `--notify` absent is `end` for a new loop (a loop already running keeps what its state says: nil, `task`);
    /// anything but task|end is refused (M3c.4).
    static func loopNotify(_ v: String?) throws(ProtocolError) -> WorkLoopState.Notify {
        guard let v else { return .end }
        guard let n = WorkLoopState.Notify(rawValue: v) else { throw ProtocolError(code: .invalidArgs, message: "--notify must be task|end") }
        return n
    }

    /// F2 R1: `--review` with `--personas auto|a,b,c` and `--reviewer-model`. F2 X4: `--review` with no persona committed
    /// at HEAD is refused. Either without `--review`, a persona whose
    /// name is no file in `docs/fabrica/personas/` AS COMMITTED AT HEAD (the loop's base: the worktree's edits never pick
    /// who judges), or a model that is no model name: invalidArgs. `personas` nil: auto.
    /// B1: `fromProfile`: the profile's `factory.review` turned it on (its refusal says so); `only`: its persona names,
    /// checked against the catalog at HEAD like `--personas`.
    static func loopReview(review: Bool, personas: String?, reviewerModel: String?, dir: URL,
                           fromProfile: Bool = false, only: [String] = []) async throws(ProtocolError)
        -> (on: Bool, personas: [String]?, reviewerModel: String?) {
        func invalid(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        guard review else {
            if personas != nil || reviewerModel != nil { throw invalid("--personas and --reviewer-model go with --review only") }
            return (false, nil, nil)
        }
        if let reviewerModel { try ClaudeModel.validate(reviewerModel) }
        // F2 X4: no catalog at HEAD is refused now, not after an agent's whole turn
        let known = await committedPersonas(dir)
        guard !known.isEmpty else {
            throw invalid(fromProfile ? "factory.review do \(ProjectWorkConfig.fileName) liga a revisão, mas não há personas em HEAD (docs/fabrica/personas)"
                          : "--review: sem personas em docs/fabrica/personas no HEAD")
        }
        if let bad = only.first(where: { !known.contains($0) }) {
            throw invalid("factory.review.personas do \(ProjectWorkConfig.fileName): persona desconhecida '\(RerailText.clean(bad, max: 60))'; "
                          + "conhecidas (\(personasDir), em HEAD): " + known.sorted().joined(separator: ", "))
        }
        guard let personas, personas != "auto" else { return (true, nil, reviewerModel) }
        let names = TaskScheduler.list(personas)
        if let bad = names.first(where: { !known.contains($0) }) {
            throw invalid("unknown persona '\(RerailText.clean(bad, max: 60))'; known (\(personasDir), at HEAD): " + known.sorted().joined(separator: ", "))
        }
        return (true, names, reviewerModel)
    }
    static let personasDir = "docs/fabrica/personas/"

    // F2 A3: no strict-mode requirement. The review is an opinion that never approves (`reviewAdvisory`): a judged
    // agent that sways its reviewer at most silences it, which equals no `--review`; the check and the gate decide.

    /// F2 Z2: what a strict loop agent writes under the home besides caches (`WorkLoop.strictWritable`): its write
    /// grants (any terminal's: fail closed) and each paddock's folder with its lanes (the paddock's parent).
    func loopStrictWrites() -> (home: URL, paths: [String]) {
        (sandboxHomeDir, sandboxGrants.filter { $0.access == .write }.map(\.path)
            + ws.paddocks.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path })
    }
    /// The persona names (`<name>.md`) in `personasDir` at HEAD; none: no such folder, or no git.
    static func committedPersonas(_ dir: URL) async -> Set<String> {
        let out = (try? await GitRunner.run(["ls-tree", "--name-only", "HEAD", "--", personasDir], in: dir, timeout: .seconds(30)))
        guard let out, out.status == 0 else { return [] }
        return Set(out.stdout.split(separator: "\n").compactMap { line in
            let name = (line as Substring).split(separator: "/").last.map(String.init) ?? ""
            return name.hasSuffix(".md") ? String(name.dropLast(3)) : nil
        })
    }

    /// The card was answered or expired: forget it. True when `work.stop` had withdrawn it first.
    private func takeLoopCard(_ work: UUID) -> Bool { loopCards.removeValue(forKey: work) == nil }

    private func loopDenied(paddock: UUID?, starter: UUID, title: String, withdrawn: Bool) async {
        if let paddock { loopPaddocks.remove(paddock) }
        let t = RerailText.clean(title)
        let line = withdrawn ? "[collie] O laço de \"\(t)\" foi cancelado antes da aprovação; nada rodou."
            : "[collie] O dono não aprovou o laço de \"\(t)\"; nada rodou."
        try? await asks.inject(to: starter, prompt: line, afterQuiet: true)
    }

    /// After the owner's Permitir (or at once, in a paddock trusted for loops): the loop's sandbox, its state, the engine.
    /// False: it did not start, and the paddock is free again.
    @discardableResult
    private func startLoop(_ id: UUID, _ loop: WorkLoopState, paddock: Paddock, starter: UUID, dir: URL) async -> Bool {
        // the loop's own profile (the paddock's, strict), made now: it outlives every terminal of the loop
        if config.sandboxHome != nil {
            do { _ = try prepareLoopSandbox(id, paddock: paddock) } catch {
                loopPaddocks.remove(paddock.id)
                try? await asks.inject(to: starter, prompt: "[collie] O laço não começou: o sandbox dele não pôde ser preparado.", afterQuiet: true)
                return false
            }
        }
        do { try await work.update(id) { $0.loop = loop } } catch { loopPaddocks.remove(paddock.id); return false }
        runEngine(id, paddock: paddock.id, starter: starter, dir: dir)
        return true
    }

    /// The engine of `id`'s loop, registered in `workLoops` before this returns (no await in between). `ready` (A5, a
    /// chained work): the engine runs only once it yields true, after the router made the loop `running`; false: it
    /// never runs (the caller undoes the entry).
    private func runEngine(_ id: UUID, paddock pid: UUID, starter: UUID, dir: URL, ready: AsyncStream<Bool>? = nil) {
        let host = RouterLoopHost(router: self, starter: starter, root: config.paths.root, work: id, paddock: pid, dir: dir,
                                  sandbox: config.sandboxHome.map { (home: $0, shell: config.shell) })
        let engine = WorkLoop(store: work, host: host)
        let task = Task { [weak self] in
            if let ready {
                var go = false
                for await v in ready { go = v; break }
                guard go else { return }
            }
            _ = await engine.run(work: id, dir: dir)
            let next = await engine.takeNext(after: id)
            await self?.loopEnded(id, starter: starter, paddock: pid, next: next)
        }
        workLoops[id] = (engine, task, false)
    }

    /// A5: the queued work an auto-land chain picked (`c.next`), run by a new engine of its own with the chain's starter,
    /// on the reservation of the paddock the chain already holds (the caller frees it when this is false). The engine is
    /// in `workLoops` before the loop turns `running` (`WorkLoop.activate`), so a `work stop` reaches it from the first
    /// instant and no `running` loop is ever left with no engine. False: nothing started and the work stays `queued`
    /// (the paddock gone, the sandbox not made, the work no longer queued).
    /// C3a: and only while the paddock still carries the factory mark and its doctor at HEAD passes, checked before
    /// any agent of the next work runs. Returns nil when it started, else why not.
    func chainLoop(_ c: WorkLoop.Chain, paddock pid: UUID, starter: UUID) async -> String? {
        let id = c.next
        let notStarted = "o trabalho não pôde começar"
        guard workLoops[id] == nil, let p = ws.paddocks.first(where: { $0.id == pid }), !p.isFolder else { return notStarted }
        guard p.factory else { return "o cercado não está mais marcado como fábrica" }
        if let why = await FactoryDoctorReader.headRefusal(dir: URL(fileURLWithPath: p.path)) {
            return "o factory doctor do cercado não passa mais o mínimo (\(why))"
        }
        // the doctor's read awaited: the work may have been started (or the paddock changed) meanwhile
        guard workLoops[id] == nil, ws.paddocks.first(where: { $0.id == pid })?.factory == true else { return notStarted }
        if config.sandboxHome != nil {
            do { _ = try prepareLoopSandbox(id, paddock: p) } catch { return notStarted }
        }
        // C3b: the base after the land before it, read before the engine is registered (no await between that and activate)
        let base = (try? await loopBaseHead(pid)) ?? nil
        guard workLoops[id] == nil else { return notStarted }
        let (ready, go) = AsyncStream<Bool>.makeStream()
        runEngine(id, paddock: pid, starter: starter, dir: URL(fileURLWithPath: p.path), ready: ready)
        let at = Date()
        try? await work.update(id) { _ = WorkLoop.activate(&$0, c, at: at, base: base) }
        let ok = (try? await work.get(id))?.loop.map { $0.state == .running && $0.startedAt == at } ?? false
        go.yield(ok); go.finish()
        if !ok {
            workLoops[id] = nil
            SandboxLaunch.remove(id, root: config.paths.root)
        }
        return ok ? nil : notStarted
    }

    /// `admin.paddock.trust-loops` (app only: no agent command sets it): `--on` trusts the paddock for loops, without it
    /// the card is back. Replies with the state.
    func trustLoops(_ r: Request) async throws -> JSONValue {
        guard let i = ws.paddocks.firstIndex(where: { $0.id.uuidString.caseInsensitiveCompare(str(r, "paddock") ?? "") == .orderedSame }) else {
            throw ProtocolError(code: .notFound, message: "Paddock '\(str(r, "paddock") ?? "")' not found")
        }
        let f = try await setTrustLoops(ws.paddocks[i].id, flag(r, "on")) ?? ws.paddocks[i]
        return .object(["paddock": .string(f.id.uuidString), "name": .string(f.name), "trustLoops": .bool(f.trustLoops == true)])
    }

    /// Trust (or stop trusting) a paddock for loops, saved and told to the app; nil: no such paddock. Also the loop
    /// card's "Sempre neste cercado" (`admin.app.answer --allow --always`).
    @discardableResult
    func setTrustLoops(_ id: UUID, _ on: Bool) async throws -> Paddock? {
        guard let i = ws.paddocks.firstIndex(where: { $0.id == id }) else { return nil }
        ws.paddocks[i].trustLoops = on ? true : nil
        try await persist()
        let f = ws.paddocks[i]
        await hub.emit(.paddock(f))
        return f
    }

    /// The card's one line (the card shows no line breaks): where, the limits, `--parallel` (over 1 only), the gate (once),
    /// then every task, its check, its evidence glob, its `scope` and its `needs` (those it has), each in «…», which none
    /// may hold (agent text: a title must not pass for another entry). nil: it does not fit the card,
    /// and nothing the owner would not see is ever approved.
    /// `fromFile`: the gate / pre-check came from `collie-work.json` (M13.2), not from the flag: the card says so.
    static func loopCardText(_ w: Work, _ tasks: [WorkTask], _ l: WorkLoopState, paddock: String,
                             fromFile: (gate: Bool, precheck: Bool) = (false, false), profileReviewOff: Bool = false) -> String? {
        let file = " (\(ProjectWorkConfig.fileName))"
        func quoted(_ x: String) -> String {
            "«" + x.replacingOccurrences(of: "«", with: "‹").replacingOccurrences(of: "»", with: "›") + "»"
        }
        var review = ""
        if l.review == true {
            let who: String = l.personas.map { $0.map(quoted).joined(separator: " ") } ?? "auto"
            let only: String = l.reviewOnly.map { " (só " + $0.map(quoted).joined(separator: " ") + ")" } ?? ""
            let veto: String = l.reviewThreshold == "blocker" ? ", veto só por blocker" + file : ""
            let model: String = l.reviewerModel.map { ", revisor " + quoted($0) } ?? ""
            review = "revisão por personas: " + who + only + veto + model + ". "
        } else if profileReviewOff {
            review = "sem revisão: --no-review desliga a do perfil" + file + ". "
        }
        var s = "rodar sem supervisão \(quoted(w.title)) no cercado \(quoted(paddock)): até \(l.max ?? 0) tentativas no total "
            + "(\(l.tries) por tarefa), turno de até \(l.timeout) s, orçamento de \(l.budget ?? 0) s. "
            + (l.parallel.flatMap { $0 > 1 ? "até \($0) tarefas ao mesmo tempo, cada uma na sua faixa (--parallel \($0)). " : nil } ?? "")
            + (l.gate.map { "portão\(fromFile.gate ? file : "") depois de cada check: \(quoted($0)). " } ?? "")
            + (l.escalate.map { "escalada de modelo por tentativa: \(quoted($0.joined(separator: ", "))). " } ?? "")
            + (l.precheck.map { "pré-check\(fromFile.precheck ? file : "") no fim de cada turno: \(quoted($0)). " } ?? "")
            + (l.notify == .end ? "avisos: só no fim (--notify end). " : "")
            + review
            + (l.autoLand.map { "AUTO-LAND no fim: portão \(quoted($0.gate)), CI \(quoted($0.ci)) (até \($0.timeout) s), então paddock land por merge local, sem push. " } ?? "")
            // A5: the chain's limits, and a queued work's wait
            + (l.autoLand.map { "Até \($0.max ?? 1) trabalho(s) nesta execução, \($0.perDay ?? WorkLoopState.AutoLand.defaultPerDay) por dia no cercado. " } ?? "")
            + (l.state == .queued ? "NA FILA: nada roda agora; uma corrente do auto-land roda este trabalho depois de um land do cercado. " : "")
            + "\(tasks.count) \(tasks.count == 1 ? "tarefa" : "tarefas"), cada uma com o seu check:"
        // M3.6: each glob and each id in its own «…» (a glob with a comma never passes for two)
        func list(_ label: String, _ xs: [String]?) -> String {
            xs.flatMap { $0.isEmpty ? nil : " \(label) " + $0.map(quoted).joined(separator: " ") } ?? ""
        }
        for (i, t) in tasks.enumerated() { s += " #\(i + 1) \(quoted(t.title)) check \(quoted(t.check ?? ""))" + (t.greenOk == true ? " \(GreenCheck.flag)" : "")
                + (t.accept.map { " aceite \(quoted($0))" + (t.acceptTimeout.map { " até \($0) s" } ?? "") } ?? "")
                + (t.evidenceGlob.map { " evidência \(quoted($0))" } ?? "") + list("escopo", t.scope) + list("depende de", t.needs)
                + (i < tasks.count - 1 ? ";" : ".")
        }
        return s.count <= Self.loopCardMax ? s : nil
    }

    /// Ends the loop after the current attempt's verdict (the engine records `requested` when it does stop); a loop still waiting for the owner's card: withdraws the card.
    /// M9.2 (B5): a closed work of `t`'s whose loop still runs (M6.4: it ends at its next wake) is reached too.
    /// C5a: `now`: the attempt in course is dropped at once (`WorkLoop.stop(now:)`); a plain stop already asked may be
    /// turned into it.
    func workStop(_ t: TerminalRecord, now: Bool = false) async throws -> JSONValue {
        let active = try await work.active(terminal: t.id)
        if let w = active, let card = loopCards.removeValue(forKey: w.id) {
            appWaiters.removeValue(forKey: card)?.resume(returning: false)   // the approval task frees the paddock and tells the starter
            await dropAppCard(card)
            return .object(["state": .string("cancelled")])
        }
        // C3b: an approved work waiting in the auto-land queue has no engine: it leaves the queue (still `queued`, not
        // terminal, `dequeuedAt` set: no chain activates it), still approved; its next `work run` puts it back
        if let w = active, w.loop?.state == .queued, w.loop?.autoLand?.dequeuedAt == nil, workLoops[w.id] == nil {
            let now = Date()
            try await work.update(w.id) { x in
                guard x.loop?.state == .queued, x.loop?.autoLand?.dequeuedAt == nil else { return }
                x.loop?.autoLand?.dequeuedAt = now
                x.notes.append(WorkNote(at: now, text: "[loop] auto-land: tirado da fila (work stop): segue aprovado, fora da fila; "
                    + "a corrente não o roda; um novo work run o põe de volta"))
            }
            // the state as it is now: a chain that activated it during the update is a running loop, stopped below
            if try await work.get(w.id)?.loop?.autoLand?.dequeuedAt == now { return .object(["state": .string("dequeued")]) }
        }
        var id = active.flatMap { workLoops[$0.id] == nil ? nil : $0.id }
        if id == nil {
            for k in Array(workLoops.keys) {
                if try await work.get(k)?.terminalId == t.id { id = k; break }
                // A5: a work an auto-land chain runs is the chain starter's to stop too
                if let l = workLoops[k], (l.engine.host as? RouterLoopHost)?.starter == t.id { id = k; break }
            }
        }
        guard let id, let l = workLoops[id], !l.stopping || now else {
            throw ProtocolError(code: .invalidArgs, message: "no loop is running on '\(t.name)'s work")
        }
        workLoops[id]?.stopping = true
        await l.engine.stop(work: id, now: now)
        return .object(["state": .string("stopped")])
    }

    /// M3.6: the lanes the engine left (it removes its own: none, but for a fall in between) go before the loop's profile does.
    /// A5: `next`, the work the auto-land chain picked: it starts first, on this loop's reservation of the paddock (never
    /// freed and taken again), before this loop's notice (whose quiet wait can hold for 30 min). A `work stop` that
    /// came after the engine's end, or the daemon's cancel, ends the chain here: the work stays `queued`.
    func loopEnded(_ id: UUID, starter: UUID, paddock: UUID, next: WorkLoop.Chain? = nil) async {
        let halted = workLoops[id]?.stopping == true || Task.isCancelled
        workLoops[id] = nil
        var chained = false, refused: String?
        if let next, !halted { refused = await chainLoop(next, paddock: paddock, starter: starter); chained = refused == nil }
        if !chained { loopPaddocks.remove(paddock) }
        // the engine left the owner's line to the chain's next work: it did not start, so this loop tells, counting its lands
        if let next, !chained, let w = try? await work.get(id) {
            let title = RerailText.clean((try? await work.get(next.next))?.title ?? "?", max: 80)
            let why = halted ? "a corrente foi parada (work stop)" : refused ?? "o trabalho não pôde começar"
            try? await work.update(id) { $0.notes.append(WorkNote(at: Date(), text: "[loop] auto-land: \(why); \"\(title)\" segue na fila")) }
            let line = AutoLandSummary.ownerLine(title: RerailText.clean(w.title, max: 80), stop: halted ? .init(.requested) : w.loop?.stopReason,
                                                 left: 0, path: w.loop?.autoLand?.summary, error: nil, landed: next.chained)
            // C2: the whole line through the scrub, as the engine's own (`AutoLandSummary.ownerLine`)
            let all = LotBoards.scrub(line + " Próximo da fila: \"\(title)\" não começou (\(why)) e segue na fila.", secrets: await auth.secrets())
            await hub.emit(.notify(starter, message: String(all.prefix(2000))))
        }
        if let w = try? await work.get(id) {
            await removeLanes(of: w)
            if w.loop?.lanes != nil { try? await work.update(id) { $0.loop?.lanes = nil } }
        }
        SandboxLaunch.remove(id, root: config.paths.root)
        guard let w = try? await work.get(id) else { return }
        await writeHandoff(w, paddock: paddock)   // M10.1: before the notice, so the starter can read it at once
        try? await asks.inject(to: starter, prompt: WorkStatusText.loopEnded(w), afterQuiet: true)
    }

    /// M3.6: what is left on disk of the lanes of `w`'s loop goes: worktree, branch and the lane's sandbox files.
    /// Idempotent. A loop that never had a lane (no `--parallel` over 1, none on record) costs no git: it ends exactly
    /// as before lanes.
    /// M3b.1: the same git as the lanes' birth (`laneGit`: the daemon's, outside the loop's profile), at the loop's end
    /// and in the start sweep alike: no profile is needed, or made, to remove a lane.
    /// M3b.5: only `w`'s own lanes (never another work's, on record or not), and of those only the ones this daemon
    /// marked (`LaneWorktree.sweep`); one without the mark stays, with a note on `w`.
    func removeLanes(of w: Work) async {
        guard (w.loop?.parallel ?? 1) > 1 || w.loop?.lanes?.isEmpty == false,
              let p = ws.paddocks.first(where: { $0.id == w.paddockId }), !p.isFolder else { return }
        let host = laneSweepHost(p, work: w.id, starter: w.terminalId)
        let id = w.id
        let s = await LaneWorktree.sweep(await LaneWorktree.lanes(of: id, repoRoot: URL(fileURLWithPath: p.repoRoot), host: host), host: host) { $0 == id }
        for lane in s.removed { await host.laneGone(lane) }
        guard let note = Self.sparedNote(s) else { return }
        try? await work.update(w.id) { x in if x.notes.last?.text != note { x.notes.append(WorkNote(at: Date(), text: note)) } }
    }

    /// M3b.5: at start, the lanes of no work on record (one removed while its loop ran) that this daemon marked go
    /// too; the others stay, with a line in the daemon's log. One `for-each-ref` per repository with a paddock.
    /// ponytail: such a lane's sandbox files stay (`laneGone` needs its work's id); harmless, they only take space.
    func sweepOrphanLanes() async {
        guard let all = try? await work.list(includeClosed: true) else { return }
        let known = Set(all.map(\.id))
        var seen: Set<String> = []
        for p in ws.paddocks where !p.isFolder && seen.insert(p.repoRoot).inserted {
            let host = laneSweepHost(p, work: UUID(), starter: UUID())
            let s = await LaneWorktree.sweep(await LaneWorktree.orphans(repoRoot: URL(fileURLWithPath: p.repoRoot), knownWork: known, host: host), host: host) { !known.contains($0) }
            if let note = Self.sparedNote(s) { FileHandle.standardError.write(Data("collied: \(note)\n".utf8)) }
        }
    }

    private func laneSweepHost(_ p: Paddock, work: UUID, starter: UUID) -> RouterLoopHost {
        RouterLoopHost(router: self, starter: starter, root: config.paths.root, work: work, paddock: p.id,
                       dir: URL(fileURLWithPath: p.path), sandbox: config.sandboxHome.map { (home: $0, shell: config.shell) })
    }

    /// M3c.3: the lanes already noted by this daemon (repository and branch). A spared lane stays until someone removes
    /// it; one note per daemon says so, not one at every end of its work's loop.
    private static let notedLanes = OSAllocatedUnfairLock(initialState: Set<String>())

    /// The note for what `s` left behind that this daemon has not noted yet; nil when there is none.
    static func sparedNote(_ s: LaneWorktree.Swept) -> String? {
        func fresh(_ ls: [Lane]) -> String {
            ls.filter { l in notedLanes.withLock { $0.insert(l.repoRoot.path + " " + l.branch).inserted } }.map(\.branch).joined(separator: ", ")
        }
        let spared = fresh(s.spared), refused = fresh(s.refused)
        let parts = [spared.isEmpty ? nil : "faixa não removida (sem a marca deste daemon: de outro daemon ou do dono): " + spared,
                     refused.isEmpty ? nil : "faixa marcada não removida (a pasta não é a da faixa: movida ou trocada por symlink): " + refused]
            .compactMap { $0 }
        return parts.isEmpty ? nil : "[loop] " + parts.joined(separator: "; ")
    }


    /// At start: a loop a previous daemon left `running` is `stopped` (its task back to open, its attempt's job gone):
    /// `collie work run` again continues from the next open task. M3.6: its lanes go first (no orphan lane is left
    /// behind), the tasks that ran in them are open again and `lanes` is empty.
    func stopLoopsLeftRunning() async {
        // F2 Y1: no reviewer of this daemon exists yet: every folder a fallen one left goes, and their parent
        let reviewRoot = WorkLoop.reviewRoot(of: config.paths.root)
        try? FileManager.default.removeItem(at: reviewRoot)
        guard let all = try? await work.list(includeClosed: true) else { return }
        let now = Date()
        for w in all where w.loop?.state == .running {
            await removeLanes(of: w)
            SandboxLaunch.remove(w.id, root: config.paths.root)
            // its agents' records (the processes died with the daemon)
            for t in Self.loopAgents(of: w, in: ws.terminals, reviewRoot: reviewRoot) { try? await remove(t) }
            try? await work.update(w.id) { Self.sweepLeftRunning(&$0, now: now) }
        }
        await sweepOrphanLanes()
    }

    /// M3.8: the terminals of `w`'s loop attempts, in its paddock: those whose id is on a loop job (`WorkJob.terminal`),
    /// whatever they are called. A job with no terminal on record (a work written before the field, or a daemon that
    /// fell between the summon and its write) still finds its agent by the job's id, the name it was summoned with.
    /// Called only at the daemon's start, when no reviewer of this daemon exists yet.
    static func loopAgents(of w: Work, in terminals: [TerminalRecord], reviewRoot: URL) -> [TerminalRecord] {
        let jobs = w.jobs.filter { $0.kind == .loop }
        let ids = Set(jobs.compactMap(\.terminal)), named = Set(jobs.filter { $0.terminal == nil }.map(\.id))
        // F2 X4: and every reviewer in the paddock (`AgentNaming.isReviewer`): a daemon that fell mid-review left it,
        // and `loopReviewers` (memory only) no longer knows it, so it would count as someone working
        return terminals.filter { $0.paddockId == w.paddockId
            && (ids.contains($0.id) || named.contains($0.name) || AgentNaming.isReviewer(name: $0.name, cwd: $0.cwd, reviewRoot: reviewRoot)) }
    }

    /// What the start sweep writes on a work whose loop a previous daemon left `running`: stopped by `daemonRestart`,
    /// with its note. M3.6: the tasks that ran in lanes are open again too, and no lane stays on record.
    static func sweepLeftRunning(_ x: inout Work, now: Date) {
        let inLanes = Set(x.loop?.lanes?.map(\.task) ?? [])
        for i in x.tasks.indices where x.tasks[i].state == .inProgress && (x.tasks[i].id == x.loop?.task || inLanes.contains(x.tasks[i].id)) {
            x.tasks[i].state = .open
            // a lane's commits went with the lane: nothing of it is ever adopted (in the paddock's worktree, what
            // came after `resumeFrom` is other lanes' merges)
            if inLanes.contains(x.tasks[i].id) { x.tasks[i].forgetResume(); continue }
            // M2b.1: the latest the fallen attempt can have committed: a commit made after this is never adopted.
            // ponytail: the sweep's time, not the fall's (nobody saw it): what the owner commits between a crash and
            // this start can still be adopted, and a failed adoption deletes nothing. A heartbeat if that gap matters.
            // M2c: an adoption that fell keeps the `resumeAt` of the first fall (never moved forward)
            if x.tasks[i].resumeFrom != nil, x.tasks[i].resumeAt == nil { x.tasks[i].resumeAt = now }
        }
        for j in x.jobs.indices where x.jobs[j].kind == .loop && x.jobs[j].state == .running {
            x.jobs[j].state = .gone; x.jobs[j].endedAt = now
        }
        let why = WorkLoopState.Stop(.daemonRestart)
        x.loop?.state = .stopped; x.loop?.endedAt = now; x.loop?.task = nil; x.loop?.stopReason = why; x.loop?.lanes = nil
        x.record(LoopEvent(at: now, kind: .stopped, detail: why.label))
        x.notes.append(WorkNote(at: now, text: why.note))
    }

    /// How long the daemon's stop waits, in all, for its cancelled loops to write their end.
    static let loopCancelWait = Duration.seconds(2)

    /// Daemon stop: the loops end with it, and it waits (`wait` in all) for each engine to write `cancelled`.
    /// One still busy after that (a check that ignores the cancel) stays `running` until the next start's sweep
    /// (`daemonRestart`). `wait` is a parameter for the tests (M2b.2); the daemon always passes the default.
    /// M3.6: then the lanes still on disk go (a loop that ended in time already removed its own: nothing to do).
    /// M3b.6: only a loop that ended: one still busy may be integrating in a lane (its cancelled gate unwinding), and its
    /// lanes stay for the next start's sweep (`daemonRestart`), never removed under a merge.
    func cancelLoops(wait: Duration = CommandRouter.loopCancelWait) async {
        let loops = workLoops.map { (id: $0.key, task: $0.value.task) }
        workLoops = [:]; loopPaddocks = []
        guard !loops.isEmpty else { return }
        for l in loops { l.task.cancel() }
        // the event is the tasks' own end; the clock only bounds it (a daemon's stop never hangs on a loop)
        let (ended, signal) = AsyncStream<UUID>.makeStream()
        Task {
            await withTaskGroup(of: Void.self) { g in for l in loops { g.addTask { await l.task.value; signal.yield(l.id) } } }
            signal.finish()
        }
        let limit = Task { try? await Task.sleep(for: wait); signal.finish() }
        var done: [UUID] = []
        for await id in ended { done.append(id) }
        limit.cancel()
        for id in done { if let w = try? await work.get(id) { await removeLanes(of: w) } }
    }

    // MARK: what RouterLoopHost needs from the router

    /// `lane` (M3.3): the agent is born in the work's paddock (no `--paddock`) with the lane as its folder and project.
    /// `scratch` (F2 X1): a reviewer, born in that empty folder the loop made, as its folder and project.
    func loopSummon(_ r: Request, as starter: UUID, lane: URL? = nil, scratch: URL? = nil) async throws(ProtocolError) -> UUID {
        let v: JSONValue
        do {
            if lane != nil || scratch != nil {
                guard let me = ws.terminals.first(where: { $0.id == starter }), me.isShepherd else {
                    throw ProtocolError(code: .notShepherd, message: "a loop's agent is summoned as the loop's Shepherd")
                }
                v = try await summon(r, by: me, lane: lane, scratch: scratch)
            } else { v = try await shepherd(r, from: starter) }
        } catch {
            throw (error as? ProtocolError) ?? ProtocolError(code: .internal, message: "\(error)")
        }
        guard case .object(let o) = v, case .string(let s)? = o["id"], let id = UUID(uuidString: s) else {
            throw ProtocolError(code: .internal, message: "summon returned no terminal id")
        }
        return id
    }

    /// Any terminal of the paddock in a turn but the starter (Shepherds too: the loop's reset would take their edits).
    /// M3.3: `dir` is the host's own tree: a lane's host counts only what reaches its lane.
    /// M3b.2: `starter` nil counts the starter too (`anyoneWorking`).
    func loopOthersWorking(paddock: UUID, starter: UUID?, dir: URL) async -> String? {
        for t in Self.loopReaching(ws.terminals, paddock: paddock, starter: starter, dir: dir, reviewers: loopReviewers) {
            if await targetBusy(t.id) { return t.name }
        }
        return nil
    }

    /// M3c.2: who is in a turn in `dir`, the starter included, unless all the starter has open in the daemon is its
    /// `work.wait`/`work.status` of `work` (the recommended flow: the Shepherd blocked in `collie work wait`). Any other
    /// request of the starter's (an `ask`, another command) counts it, as do the paddock's other terminals.
    /// M3d.1: a wait counts only while its client lives (`work.wait` is cancelled when its client closes the socket; a
    /// pid gone is not a wait) and no tool call of the terminal came after it began (a wait in the background).
    /// ponytail: an edit beside a background wait is seen through Claude's PostToolUse only (no hook, no stamp); the
    /// integrator's diff of the tracked files still keeps such an edit.
    func loopAnyoneWorking(paddock: UUID, starter: UUID, work: UUID, dir: URL) async -> String? {
        await loopOthersWorking(paddock: paddock, starter: loopStarterOnlyWaits(starter, work: work) ? starter : nil, dir: dir)
    }

    /// M3d.1: the starter's open requests are all live waits on `work` (and there is one).
    func loopStarterOnlyWaits(_ starter: UUID, work: UUID) -> Bool {
        let live = Self.liveWaits(ownWaits[starter]?.values.map { $0 } ?? [], on: work, lastToolCall: lastToolCall[starter])
        return Self.loopStarterWaits(open: openRequests[starter] ?? 0, waitsOnWork: live)
    }

    /// M3c.2: every request the starter has open is a wait on the loop's work (and there is one).
    static func loopStarterWaits(open: Int, waitsOnWork: Int) -> Bool { waitsOnWork > 0 && open == waitsOnWork }

    /// One `work.wait`/`work.status` of a terminal on its own work: `pid` its client, `seq` when it began.
    struct OwnWait: Sendable { let work: UUID, pid: pid_t, seq: Int }

    /// M3d.1: the waits on `work` that still stand for a terminal only waiting: the client alive, no tool call since.
    static func liveWaits(_ waits: [OwnWait], on work: UUID, lastToolCall: Int?, alive: (pid_t) -> Bool = clientAlive) -> Int {
        waits.filter { $0.work == work && (lastToolCall ?? -1) < $0.seq && alive($0.pid) }.count
    }
    /// ponytail: a pid reused by another process reads as alive; the socket's EOF (the handler cancelled) covers a closed client.
    static func clientAlive(_ pid: pid_t) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }

    /// The waits counted by work (what M3c.2 kept): diagnostics and tests.
    var ownWorkWaits: [UUID: [UUID: Int]] {
        ownWaits.mapValues { Dictionary($0.values.map { ($0.work, 1) }, uniquingKeysWith: +) }
    }

    func requestBegan(_ t: UUID) { openRequests[t, default: 0] += 1 }
    func requestEnded(_ t: UUID) {
        openRequests[t, default: 1] -= 1
        if openRequests[t] ?? 0 <= 0 { openRequests[t] = nil }
    }
    /// A wait began: its token, for `ownWaitEnded`.
    func ownWaitBegan(_ t: UUID, on work: UUID, pid: pid_t) -> UUID {
        let token = UUID()
        activitySeq += 1
        ownWaits[t, default: [:]][token] = OwnWait(work: work, pid: pid, seq: activitySeq)
        return token
    }
    func ownWaitEnded(_ t: UUID, _ token: UUID) {
        ownWaits[t]?[token] = nil
        if ownWaits[t]?.isEmpty == true { ownWaits[t] = nil }
    }
    /// Claude's PostToolUse of `t`: a turn of its own, beside any wait it began before.
    func toolCalled(_ t: UUID) {
        activitySeq += 1
        lastToolCall[t] = activitySeq   // ponytail: one Int per terminal ever seen, not dropped with the terminal
    }

    /// The paddock's terminals, but the starter, that can edit the tree `dir` (the paddock's worktree, or one lane).
    /// For a lane: not the other lanes' agents, nor a terminal in the paddock's worktree (that tree is the integrator's, M3.4).
    /// F2 R4: a loop's reviewer (`reviewers`) only reads the text it was given: it never reaches the tree.
    static func loopReaching(_ terminals: [TerminalRecord], paddock: UUID, starter: UUID?, dir: URL, reviewers: Set<UUID> = []) -> [TerminalRecord] {
        terminals.filter { $0.paddockId == paddock && $0.id != starter && !reviewers.contains($0.id) && loopSharesWorktree($0, dir) }
    }

    /// A terminal can edit the loop's worktree only when its folder is inside it (or cannot be told): one working
    /// elsewhere in the paddock never blocks the reset. Wrongly counting one is safe; wrongly ignoring one is not.
    static func loopSharesWorktree(_ t: TerminalRecord, _ dir: URL) -> Bool {
        guard !t.cwd.isEmpty else { return true }
        let root = dir.resolvingSymlinksInPath().standardizedFileURL.path
        let there = URL(fileURLWithPath: t.cwd).resolvingSymlinksInPath().standardizedFileURL.path
        return there == root || there.hasPrefix(root + "/") || root.hasPrefix(there + "/")
    }

    /// M3.5: the sandbox profile of one lane of the loop (`prepareLoopSandbox`), made when the lane is.
    func loopLaneSandbox(_ work: UUID, paddock: UUID, lane: Lane) throws(ProtocolError) {
        guard let p = ws.paddocks.first(where: { $0.id == paddock }) else {
            throw ProtocolError(code: .notFound, message: "the loop's paddock is gone")
        }
        do { _ = try prepareLoopSandbox(work, paddock: p, lane: lane) } catch {
            throw (error as? ProtocolError) ?? ProtocolError(code: .unavailable, message: "the lane's sandbox could not be prepared: \(error)")
        }
    }

    /// M3.8: the names a summon would refuse: the terminals', the panels' and those being launched.
    func loopNamesTaken() -> Set<String> {
        Set(ws.terminals.map { $0.name.lowercased() } + ws.panels.map { $0.name.lowercased() }).union(launching)
    }

    func loopTerminalExists(_ id: UUID) -> Bool { ws.terminals.contains { $0.id == id } }

    /// A4: the paddock carries the factory mark (A2) now.
    func loopFactory(_ paddock: UUID) -> Bool { ws.paddocks.first { $0.id == paddock }?.factory == true }

    /// C3a: the paddock's auto-lands (`Paddock.autoLands`), the daily cap's count.
    func loopAutoLands(_ paddock: UUID) -> [Date] { ws.paddocks.first { $0.id == paddock }?.autoLands ?? [] }

    /// C3b: the commit of the paddock's base branch in its repository, now (nil: a folder paddock, no base). A throw:
    /// the paddock is gone or git could not read the branch.
    func loopBaseHead(_ paddock: UUID) async throws(ProtocolError) -> String? {
        guard let f = ws.paddocks.first(where: { $0.id == paddock }) else { throw ProtocolError(code: .notFound, message: "the loop's paddock is gone") }
        guard f.kind == .worktree, !f.baseBranch.isEmpty else { return nil }
        let r = try? await GitRunner.run(["rev-parse", "--verify", "-q", "refs/heads/\(f.baseBranch)^{commit}"], in: URL(fileURLWithPath: f.repoRoot), timeout: .seconds(30))
        guard let r, r.status == 0 else { throw ProtocolError(code: .internal, message: "git rev-parse \(f.baseBranch) failed") }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A4, `work run --auto-land`: `paddock land` of the loop's paddock by the command's own path (`landPaddock`), only
    /// `merge` (never a push nor a PR), only while it is a factory's. The base branch's commit before and after.
    /// C3b: `base`, the base's commit the land was judged on: another one under the claim, right before the merge, throws
    /// `.conflict` and merges nothing.
    func loopLand(_ paddock: UUID, mode: LandMode, message: String, base: String? = nil) async throws(ProtocolError) -> (before: String, after: String, late: String?, unrecorded: String?) {
        guard mode == .merge else { throw ProtocolError(code: .invalidArgs, message: "auto-land lands only by merge, never \(mode.rawValue)") }
        guard var f = ws.paddocks.first(where: { $0.id == paddock }) else { throw ProtocolError(code: .notFound, message: "the loop's paddock is gone") }
        guard f.factory else { throw ProtocolError(code: .invalidArgs, message: "paddock '\(f.name)' is not a factory's") }
        // C4a: the base before, for a throw that comes after the merge (inside `PaddockManager.land`): it counts too
        // ponytail: read before the land's claim; another paddock landing on the same base in between counts here as
        // well (the cap errs toward stopping)
        let start = try? await loopBaseHead(paddock)
        do {
            // C2: a failure after the merge (the save) comes back as `late`, never as a throw: the base moved
            let (res, late) = try await landPaddockKeepingLate(&f, mode: .merge, message: message, base: base)
            // C3a: `before` is the base's HEAD read under the land's claim right before the merge (another paddock landing
            // on the same base before it is in it); equal to `after`: the merge made no commit, nothing is counted
            guard let after = res.commit, let before = res.before else { throw ProtocolError(code: .internal, message: "the land gave no commit") }
            let unrecorded = before == after ? nil : await recordAutoLand(paddock)
            return (before, after, late.map { ($0 as? ProtocolError)?.message ?? "\($0)" }, unrecorded)
        } catch {
            let e = (error as? ProtocolError) ?? ProtocolError(code: .internal, message: "\(error)")
            // C4a: the merge happened (the base moved) before the throw: a land all the same, in the cap
            if e.code != .conflict, let start, let now = try? await loopBaseHead(paddock), now != start { _ = await recordAutoLand(paddock) }
            throw e
        }
    }

    /// C4a: a land of `paddock` now, in its daily record (`Paddock.autoLands`), persisted. nil: recorded; else why it
    /// could not be written (the record stays in memory, so this daemon still counts it).
    func recordAutoLand(_ paddock: UUID) async -> String? {
        guard let i = ws.paddocks.firstIndex(where: { $0.id == paddock }) else { return "o cercado sumiu" }
        let now = Date()
        ws.paddocks[i].autoLands = (ws.paddocks[i].autoLands ?? []).filter { $0 > now.addingTimeInterval(-86_400) } + [now]
        do {
            if landRecordFails { throw ProtocolError(code: .internal, message: "a gravação do registro falhou (teste)") }
            try await persist()
            return nil
        } catch { return (error as? ProtocolError)?.message ?? "\(error)" }
    }

    func loopDismiss(_ id: UUID) async {
        if let t = ws.terminals.first(where: { $0.id == id }) { try? await remove(t) }
        loopReviewers.remove(id)
    }

    /// F2 Z3b: `loopDismiss`, then what is left of the terminal's process group killed. Its PTY's process leads its own
    /// session (`setsid`), so its pid is the group's id, read before the dismiss forgets it.
    /// F2 W2: and every descendant (each Bash of Claude Code is a group of its own), swept before the dismiss and again
    /// after (`WorkLoop.reap`). The pid is read only while its process runs: a reaped pid may be reused.
    func loopDismissReaping(_ id: UUID) async {
        let p = await registry.process(id)
        let running = p?.isRunning == true, leader = running ? p?.pid : nil
        let known = leader.map { WorkLoop.descendants(of: [$0]) } ?? []
        await loopDismiss(id)
        WorkLoop.reap(leader: leader, running: running, known: known)
    }

    /// The loop's sandbox: the paddock's profile, as an app service gets (strict whatever the workspace's mode: never
    /// wider than a strict terminal of the paddock), under the work's id. Removed when the loop ends.
    /// `lane` (M3.3): that lane's own profile, under `laneSandboxId`: the same strict profile with the lane as the
    /// project, closed (read and write) to the paddock's worktree and to every other lane. A lane that is not a
    /// worktree of the paddock's repository throws: no profile is guessed.
    func prepareLoopSandbox(_ work: UUID, paddock: Paddock, lane: Lane? = nil) throws -> URL {
        let project = try lane.map { try Self.vetLane($0.path, paddock: paddock) } ?? URL(fileURLWithPath: paddock.path)
        let git = SandboxInput.gitDirs(of: project)
        var input = SandboxInput(terminal: lane.map { Self.laneSandboxId(work, $0) } ?? work, project: project, mainGitDir: git.common, worktreeGitDir: git.worktree,
                                 paddockWorktrees: closedPaddocks(project), home: config.sandboxHome ?? URL(fileURLWithPath: NSHomeDirectory()),
                                 collieRoot: config.paths.root, ownFiles: [],
                                 terminalDir: SandboxLaunch.dir(work, root: config.paths.root), socket: config.paths.socket,
                                 agent: .shell, command: nil, grants: [],
                                 appBundle: SandboxInput.appBundle(of: config.collieExecutable), mode: .strict)
        if lane != nil {
            input.terminalDir = SandboxLaunch.dir(input.terminal, root: config.paths.root)
            input.lanePaddock = URL(fileURLWithPath: paddock.path)
        }
        return try SandboxLaunch.prepare(input, root: config.paths.root, collie: config.collieExecutable)
    }

    /// The id a lane's profile and files live under (`<root>/sandbox/<id>`): from the work and the lane's branch, so
    /// whoever knows the lane (the loop's end, the start sweep: M3.6) finds them again with nothing stored.
    static func laneSandboxId(_ work: UUID, _ lane: Lane) -> UUID {
        let h = Array(SHA256.hash(data: Data("\(work.uuidString.lowercased())/\(lane.branch)".utf8)).prefix(16))
        return NSUUID(uuidBytes: h) as UUID
    }

    /// The user's env (their toolchain's PATH), before the allow-list.
    func loopUserEnv() async -> [String: String] {
        UserEnvironment.merge(user: await userEnv.current(), collie: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"],
                              collieBin: config.collieExecutable.deletingLastPathComponent().path)
    }

    /// With a terminal sandbox in force, an attempt's agent must run in one too (a free one is dismissed, the attempt fails).
    /// A lane's agent (M3.3) also when no terminal is sandboxed (then never): sandboxed, strict, the lane its project.
    /// F2 A5 (`strict`: a reviewer): it must have started strict (the launch forces it), whatever the workspace's mode.
    func loopAgentSandboxed(_ id: UUID, lane: URL? = nil, strict: Bool = false) -> Bool {
        let t = ws.terminals.first { $0.id == id }
        if let lane {
            guard let t, sandboxed(t), t.startMode == .strict, lanePaddock(of: t) != nil else { return false }
            return t.projectRoot == SignedAppCheck.realPath(lane)
        }
        guard config.sandboxHome != nil else { return true }
        return t.map { sandboxed($0) && (!strict || $0.startMode == .strict) } ?? false
    }

    /// F2 V2 (f2fix9): the terminal `id` started open or free of the sandbox; none of that id: false.
    func loopAgentStartedOpen(_ id: UUID) -> Bool {
        ws.terminals.first { $0.id == id }.map { $0.sandbox != .sandboxed || $0.startMode == .open } ?? false
    }

    /// The spec, read again at the attempt: a regular file (no symlink, one link) still inside the starter's project.
    func loopSpec(_ path: String, starter: UUID) async -> String? {
        guard let t = ws.terminals.first(where: { $0.id == starter }), let root = try? await projectRoot(of: t),
              let data = try? Self.readBodyFile(path, allowed: { ProjectRoot.contains($0, root: root) }) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// `LoopHost` over the daemon: summons as the starter (a Shepherd), asks with the daemon's own end of turn, and runs
/// git and the check under the loop's own profile (`<root>/sandbox/<work id>.sb`). `sandbox` nil: the daemon sandboxes no
/// terminal (`--no-terminal-sandbox`, the test daemons), so neither does the loop; else a missing profile throws.
/// Git for a summary's reverts count, with the loop's care (`loopGit`: the repo's own filters off), under the
/// request's sandbox when it has one.
struct LoopRevertGit: RevertGit {
    let dir: URL
    func out(_ args: [String]) async -> String? {
        guard let r = try? await RouterLoopHost.loopGit(args, in: dir, profile: GitRunner.sandbox), r.status == 0, !r.truncated else { return nil }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// M3b.1: git for the lanes' birth and removal: (args, dir, sandbox profile or nil).
typealias LaneGit = @Sendable (_ args: [String], _ dir: URL, _ profile: URL?, _ stdin: Data?, _ timeout: Duration, _ cap: Int) async throws(ProtocolError) -> ProcessResult

struct RouterLoopHost: LoopHost {
    let router: CommandRouter, starter: UUID, root: URL, work: UUID, paddock: UUID, dir: URL
    let sandbox: (home: URL, shell: String)?
    /// M3.3. nil: the paddock's host (`dir` its worktree), exactly as before lanes. A lane's host (`forLane`): `dir` is
    /// the lane, git and the check run under the lane's own profile, its agent is born in the lane, and it refuses to
    /// run anything when the daemon sandboxes no terminal.
    var lane: Lane? = nil
    /// M3b.1: what runs the lanes' own git (`laneGit`), with the profile it is given: always none. A test's fake
    /// records that profile.
    var laneRunner: LaneGit = RouterLoopHost.loopGit

    /// This host for one lane of the loop: cheap, one per lane.
    func forLane(_ lane: Lane) -> RouterLoopHost {
        RouterLoopHost(router: router, starter: starter, root: root, work: work, paddock: paddock, dir: lane.path, sandbox: sandbox, lane: lane)
    }

    /// M3.5: the lane's host, its profile made first. Without a terminal sandbox there is none to make, and `profile`
    /// refuses everything the lane would run.
    func laneHost(_ lane: Lane) async throws(ProtocolError) -> any LoopHost {
        if sandbox != nil { try await router.loopLaneSandbox(work, paddock: paddock, lane: lane) }
        return forLane(lane)
    }
    func laneGone(_ lane: Lane) async { SandboxLaunch.remove(CommandRouter.laneSandboxId(work, lane), root: root) }

    /// What the profile and its shims live under: the work, or the lane's own id.
    var sandboxId: UUID { lane.map { CommandRouter.laneSandboxId(work, $0) } ?? work }

    /// The only keys a check gets from the user's env: the toolchain's, never a token or an agent socket (GH_TOKEN,
    /// SSH_AUTH_SOCK, COLLIE_*). ponytail: a fixed list; a toolchain that needs another key fails its check, add it here.
    static let checkEnvKeys: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR",
                                            "DEVELOPER_DIR", "SDKROOT", "JAVA_HOME", "ANDROID_HOME", "ANDROID_SDK_ROOT", "GOPATH", "GOROOT",
                                            "CARGO_HOME", "RUSTUP_HOME", "NVM_DIR", "PYENV_ROOT", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME"]

    /// The summon the loop sends as its starter. No --paddock: the starter stands in the work's paddock (work.start took it from there).
    func summonRequest(_ name: String, _ loop: WorkLoopState) -> Request {
        var args: [String: JSONValue] = ["name": .string(name)]
        if let p = loop.preset { args["preset"] = .string(p) }
        if let m = loop.model { args["model"] = .string(m) }
        if let c = loop.command { args["command"] = .string(c) }
        return Request(id: "loop", terminalId: starter.uuidString, command: "summon", args: args)
    }

    func summon(name: String, for work: Work, loop: WorkLoopState) async throws(ProtocolError) -> UUID {
        let request = summonRequest(name, loop)
        if await router.loopAgentRefused(request, as: starter) { throw ProtocolError(code: .invalidArgs, message: CommandRouter.loopAgentRefusal) }
        let id = try await router.loopSummon(request, as: starter, lane: lane?.path)
        guard await router.loopAgentSandboxed(id, lane: lane?.path) else {
            await router.loopDismiss(id)
            throw ProtocolError(code: .unauthorized, message: "'\(name)' started without a sandbox")
        }
        return id
    }

    func ask(_ terminal: UUID, prompt: String, timeout: Duration) async throws(ProtocolError) -> AskResult.Source {
        try await router.asks.ask(from: starter, to: terminal, prompt: prompt, raw: false, timeout: timeout).source
    }
    /// F2 R4/X4: marked as a reviewer inside the summon, before its terminal is launched (`summon(scratch:)`): never a
    /// moment in the paddock unmarked.
    /// F2 X1: born in `cwd` (the loop's empty `reviewScratch`), never in the worktree or a lane: its project, so its
    /// sandbox profile writes there and not in the worktree nor the repository's git dir (`cwd` is no repo). F2 Y1:
    /// `cwd` is inside Collie's closed dir (`reviewRoot`); the profile opens that folder alone again. The limit:
    /// the strict profile still writes the temp dirs and the write grants of the reviewer's lot; a worktree under one
    /// of those stays writable, and the tree's recheck after the review (`reviewTree`) is what catches that.
    // F2 X4: a daemon that falls mid-review leaves the reviewer terminals; the start sweep removes them (`loopAgents`)
    func summonReviewer(name: String, for work: Work, loop: WorkLoopState, cwd: URL) async throws(ProtocolError) -> UUID {
        let id = try await router.loopSummon(summonRequest(name, loop), as: starter, scratch: cwd)
        guard await router.loopAgentSandboxed(id, strict: true) else {
            await router.loopDismiss(id)
            throw ProtocolError(code: .unauthorized, message: "'\(name)' started without a sandbox")
        }
        return id
    }
    func strictWrites() async -> (home: URL, paths: [String]) { await router.loopStrictWrites() }
    func trustReviewers() async -> String? { WorkLoop.trustReviewRoot(home: await globalConfigHome(), reviewRoot: reviewRoot) }
    /// F2 A5/V2: by the judged agent's own start mode, never the workspace's now (a lane's agent is strict in an open
    /// workspace; the mode may change after its summon), by id (a name freed by the dismiss may be another's).
    func startedOpen(_ agent: UUID) async -> Bool { await router.loopAgentStartedOpen(agent) }
    func askText(_ terminal: UUID, prompt: String, timeout: Duration) async throws(ProtocolError) -> String {
        try await router.asks.ask(from: starter, to: terminal, prompt: prompt, raw: false, timeout: timeout).output
    }
    func resubmitted(_ terminal: UUID) async -> Bool { await router.asks.submitRetried(terminal) }

    func working(_ terminal: UUID) async -> Bool { await router.targetBusy(terminal) }
    func usageLimit(_ terminal: UUID) async -> String? {
        guard let s = await router.asks.screen(terminal, quiet: .seconds(10)) else { return nil }
        return UsageLimit.detect(s.lines, quiet: s.quiet)
    }
    func screen(_ terminal: UUID) async -> [String]? { await router.asks.screen(terminal, quiet: .seconds(10))?.lines }
    func secrets() async -> Set<String> { await router.auth.secrets() }
    func tokens(_ terminal: UUID) async -> TokenCount? { await router.attemptTokens(terminal) }
    func othersWorking() async -> String? { await router.loopOthersWorking(paddock: paddock, starter: starter, dir: dir) }
    func anyoneWorking() async -> String? { await router.loopAnyoneWorking(paddock: paddock, starter: starter, work: work, dir: dir) }
    func starterAlive() async -> Bool { await router.loopTerminalExists(starter) }
    func namesTaken() async -> Set<String> { await router.loopNamesTaken() }
    func dismiss(_ terminal: UUID) async { await router.loopDismiss(terminal) }
    func dismissReaping(_ terminal: UUID) async { await router.loopDismissReaping(terminal) }
    func taskEnded(_ line: String) async { try? await router.asks.inject(to: starter, prompt: line, afterQuiet: true) }
    func factoryPaddock() async -> Bool { await router.loopFactory(paddock) }
    func land(mode: LandMode, message: String, base: String?) async throws(ProtocolError) -> (before: String, after: String, late: String?, unrecorded: String?) {
        try await router.loopLand(paddock, mode: mode, message: message, base: base)
    }
    func notifyOwner(_ line: String) async { await router.hub.emit(.notify(starter, message: String(line.prefix(2000)))) }
    /// C3a: read at the paddock's HEAD, never from the tree the agent edits.
    func doctorRefusal() async -> String? { await FactoryDoctorReader.headRefusal(dir: dir) }
    func autoLands() async -> [Date] { await router.loopAutoLands(paddock) }
    func baseHead() async throws(ProtocolError) -> String? { try await router.loopBaseHead(paddock) }

    /// The loop's profile; nil only when no terminal is sandboxed. Never nil because it went missing.
    func profile() throws(ProtocolError) -> URL? {
        guard sandbox != nil else {
            // the paddock's host follows the daemon (no terminal sandbox, none here); a lane never runs without its profile
            if lane != nil { throw ProtocolError(code: .unavailable, message: "a lane runs only sandboxed, and this daemon sandboxes no terminal") }
            return nil
        }
        let f = SandboxLaunch.profileFile(sandboxId, root: root)
        guard FileManager.default.fileExists(atPath: f.path) else {
            throw ProtocolError(code: .unavailable, message: "the loop's sandbox profile is gone; nothing of the loop runs unsandboxed")
        }
        return f
    }

    func git(_ args: [String], in dir: URL) async throws(ProtocolError) -> ProcessResult {
        try await Self.loopGit(args, in: dir, profile: try profile())
    }

    /// M3b.1: the daemon's own git, as `PaddockManager` runs for a paddock's worktree: no profile (the loop's cannot
    /// write a lane), with `loopGit`'s care (hooks, fsmonitor and the repo's own filters off: `worktree add` checks out).
    func laneGit(_ args: [String], in dir: URL) async throws(ProtocolError) -> ProcessResult {
        try await laneRunner(args, dir, nil, nil, .seconds(120), 1 << 20)
    }
    func laneGit(_ args: [String], stdin: Data?, timeout: Duration, cap: Int, in dir: URL) async throws(ProtocolError) -> ProcessResult {
        try await laneRunner(args, dir, nil, stdin, timeout, cap)
    }
    /// M3b.5: the install id (`remote/install-id` of this daemon's root): a dev daemon and the installed one differ.
    func laneOwner() async -> String { (try? await router.remoteInstallId()) ?? "" }

    /// Git for the loop, in an agent-writable repo: under `profile`, hooks and fsmonitor off (GitRunner), and the filter
    /// drivers the repo's own config defines (local/worktree scope: what an agent can plant), external diffs and textconv off.
    /// The user's global drivers (git-lfs) stay.
    static func loopGit(_ args: [String], in dir: URL, profile: URL?, stdin: Data? = nil,
                        timeout: Duration = .seconds(120), cap: Int = 1 << 20) async throws(ProtocolError) -> ProcessResult {
        do {
            return try await GitRunner.$sandbox.withValue(profile) {
                var off = [("diff.external", "")]
                let cfg = try await GitRunner.run(["config", "--show-scope", "-z", "--name-only", "--get-regexp", #"^filter\."#], in: dir, timeout: .seconds(30))
                let f = cfg.stdout.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
                var names: Set<String> = []
                for i in stride(from: 0, to: f.count - 1, by: 2) where !["global", "system"].contains(f[i]) {
                    let key = f[i + 1]   // filter.<name>.<var>; the name may hold dots and spaces
                    guard key.hasPrefix("filter."), let dot = key.lastIndex(of: "."), dot > key.index(key.startIndex, offsetBy: 6) else { continue }
                    names.insert(String(key[key.index(key.startIndex, offsetBy: 7)..<dot]))
                }
                for n in names.sorted() {
                    off += [("filter.\(n).clean", ""), ("filter.\(n).smudge", ""), ("filter.\(n).process", ""), ("filter.\(n).required", "false")]
                }
                var a = args
                if a.first == "diff" { a.insert(contentsOf: ["--no-ext-diff", "--no-textconv"], at: 1) }
                // by env, not `-c`: a driver name may hold `=`
                // T2 f2fix8: 1 MiB, as GitRunner's; only the reviewer's copy asks more (`reviewSnapshotCap`)
                return try await GitRunner.run(a, in: dir, timeout: timeout, config: off, cap: cap, stdin: stdin)
            }
        } catch { throw (error as? ProtocolError) ?? ProtocolError(code: .internal, message: "\(error)") }
    }

    func check(_ command: String, in dir: URL, timeout: Duration) async throws(ProtocolError) -> ProcessResult {
        let profile = try profile()
        let env = Self.checkEnv(await router.loopUserEnv(), sandbox: sandbox.map { (sandboxId, root, $0.shell, $0.home) })
        return try await Self.runCheck(command, in: dir, profile: profile, env: env, timeout: timeout)
    }

    /// The allow-listed user env; sandboxed, the loop's shims first on PATH (SwiftPM and xcodebuild can't nest a sandbox)
    /// and HOME the sandbox's. Never a COLLIE_ key.
    static func checkEnv(_ user: [String: String], sandbox: (id: UUID, root: URL, shell: String, home: URL)?) -> [String: String] {
        var e = user.filter { checkEnvKeys.contains($0.key) }
        if let s = sandbox { e = SandboxLaunch.environment(e, id: s.id, root: s.root, shell: s.shell, home: s.home) }
        return e.filter { !$0.key.hasPrefix("COLLIE_") }
    }

    /// `/bin/bash -c command` in `dir`, wrapped in `sandbox-exec -f profile` when there is one.
    static func runCheck(_ command: String, in dir: URL, profile: URL?, env: [String: String], timeout: Duration) async throws(ProtocolError) -> ProcessResult {
        let bash = ["/bin/bash", "-c", command]
        if let profile {
            return try await BoundedProcess.run(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"), args: ["-f", profile.path] + bash,
                                                in: dir, env: env, timeout: timeout)
        }
        return try await BoundedProcess.run(executable: URL(fileURLWithPath: bash[0]), args: Array(bash.dropFirst()), in: dir, env: env, timeout: timeout)
    }

    func readSpec(_ path: String) async -> String? { await router.loopSpec(path, starter: starter) }
    func exists(_ path: String, in dir: URL) async -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path, isDirectory: &isDir) && !isDir.boolValue
    }
    /// A lane's patches (and evidence) in its own subfolder, `lanes/<the lane's folder name>`: never mixed with another lane's.
    var reviewRoot: URL { WorkLoop.reviewRoot(of: root) }
    func patchDir(_ work: UUID) -> URL {
        let d = root.appendingPathComponent("work-loops").appendingPathComponent(work.uuidString.lowercased())
        return lane.map { d.appendingPathComponent("lanes").appendingPathComponent($0.path.lastPathComponent) } ?? d
    }
    func now() -> Date { Date() }
}
