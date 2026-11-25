import Foundation
import CollieCore
import CollieProtocol

/// C5c: the loop's first phase ("verificando checks que já passam"), run by the engine, never by `work run`: every open
/// task's check (not `--green-ok`) once at the paddock's HEAD, at most `preCheckParallel` at once, each under
/// `preCheckTimeout` (past it, or a check that cannot run: red, it measures something). One that passes stops the loop
/// with `checkAlreadyGreen` before any attempt; `work stop` cancels it at once.
extension WorkLoop {
    static let preCheckParallel = 4

    func greenPreCheck(_ id: UUID, _ dir: URL) async -> WorkLoopState.Stop? {
        guard let w = try? await store.get(id), let loop = w.loop else { return nil }
        let todo = w.tasks.filter { $0.state == .open && (loop.tasks?.contains($0.id) ?? true) && $0.greenOk != true && $0.check != nil }
        if stopping.contains(id) { return .init(.requested) }
        guard !todo.isEmpty else { return nil }
        let at = host.now(), started = entry(.preCheckStarted, detail: "\(todo.count) check(s)")
        try? await store.update(id) { $0.loop?.show(.preCheck, at: at); $0.record(started) }
        let host = self.host, timeout = preCheckTimeout
        // the cancel of `work stop` kills each check's process group (a check never outlives the pre-check)
        let run = Task { await BoundedProcess.$killOnCancel.withValue(true) { await Self.greens(todo, host: host, dir: dir, timeout: timeout) } }
        preChecks[id] = run
        if stopping.contains(id) { run.cancel() }
        let green = await run.value
        preChecks[id] = nil
        let done = entry(.preCheckFinished, detail: "\(green.count) de \(todo.count) já passa(m)")
        try? await store.update(id) { $0.loop?.show(nil); $0.record(done) }
        if stopping.contains(id) { return .init(.requested) }
        if Task.isCancelled { return .init(.cancelled) }
        guard !green.isEmpty else { return nil }
        let text = Self.greenText(green)
        await note(id, "[loop] " + text)
        await host.notifyOwner(LotBoards.scrub("Collie: laço \"\(RerailText.clean(w.title, max: 80))\": " + text, secrets: await host.secrets()))
        return .init(.checkAlreadyGreen, detail: Self.eventDetail(green.map(\.title).joined(separator: ", ")))
    }

    /// The tasks whose check exits 0, in their order. A cancel kills the checks running and starts no other.
    static func greens(_ tasks: [WorkTask], host: any LoopHost, dir: URL, timeout: Duration) async -> [WorkTask] {
        await withTaskGroup(of: (Int, Bool).self) { g in
            var todo = Array(tasks.enumerated()).makeIterator(), green: Set<Int> = []
            // past the ceiling `BoundedProcess` kills the check's whole group and throws `.timeout`: red
            @Sendable func passes(_ t: WorkTask) async -> Bool {
                guard !Task.isCancelled else { return false }
                return (try? await host.check(t.check ?? "false", in: dir, timeout: timeout))?.status == 0 && !Task.isCancelled
            }
            for _ in 0..<preCheckParallel { if let (i, t) = todo.next() { g.addTask { (i, await passes(t)) } } }
            for await (i, ok) in g {
                if ok { green.insert(i) }
                if !Task.isCancelled, let (j, t) = todo.next() { g.addTask { (j, await passes(t)) } }
            }
            return tasks.indices.filter(green.contains).map { tasks[$0] }
        }
    }

    /// The refusal `work run` gave before C5c, word for word: the tasks, their checks and the way out.
    static func greenText(_ green: [WorkTask]) -> String {
        "\(GreenCheck.reason): " + green.map { "\"\(RerailText.clean($0.title))\" [\($0.id)] check «\(RerailText.clean($0.check ?? "", max: 200))»" }.joined(separator: ", ")
            + ". \(GreenCheck.hint.prefix(1).uppercased() + GreenCheck.hint.dropFirst()) (collie work task add … \(GreenCheck.flag))"
    }
}

/// C5c: an `--auto-land` loop that stops on a land that did not integrate leaves none of the work's commits on the
/// paddock: they would go into the next land, of another work. The paddock (never the base) goes back to the commit
/// the work began on (`AutoLand.startHead`); the commits dropped are kept as one patch (`git format-patch`) in the
/// daemon's folder of the work (`work-loops/<work>/discarded/`, out of the agent's tree), named in a note with how to
/// get them back. A dirty tree, another agent busy or a HEAD that is not past the start: nothing is touched, and the
/// note and the owner's line say so.
extension WorkLoop {
    static let discards: Set<WorkLoopState.Stop.Code> = [.landGateRed, .landReviewVeto, .landCiRed, .landDirty, .landConflict, .landBaseMoved,
                                                         .landAcceptRed, .landDailyCap, .landDoctorRegressed, .landTasksNotDone, .landNothing,
                                                         .landNotFactory]
    static let discardedFolder = "discarded", discardCap = 64 << 20

    /// What was done, for the owner's line (nil: nothing to discard).
    func discardLand(_ id: UUID, _ dir: URL) async -> String? {
        guard let start = (try? await store.get(id))?.loop?.autoLand?.startHead, let head = await out(["rev-parse", "HEAD"], dir), head != start else { return nil }
        func keep(_ why: String) async -> String {
            let line = "[loop] auto-land: commits da tentativa NÃO descartados (\(why)); o cercado segue em \(head.prefix(12)); "
                + "descarte à mão (git reset --hard \(start.prefix(12)) no cercado) antes do próximo land"
            await note(id, LotBoards.scrub(String(line.prefix(Self.noteChars))))
            return line
        }
        guard let status = await out(["status", "--porcelain"], dir) else { return await keep("git status falhou") }
        guard status.isEmpty else { return await keep("árvore do cercado suja") }
        if let who = await host.othersWorking() { return await keep("'\(who)' trabalhando no cercado") }
        guard (try? await host.git(["merge-base", "--is-ancestor", start, head], in: dir))?.status == 0 else {
            return await keep("o HEAD não descende do commit inicial \(start.prefix(12))")
        }
        // never a commit the base already has (a stale start from before a land would undo it)
        let base: String?
        do { base = try await host.baseHead() } catch { return await keep("a base não pôde ser lida") }
        if let base, let all = await out(["rev-list", "--count", "\(start)..\(head)"], dir),
           all != (await out(["rev-list", "--count", "\(start)..\(head)", "^\(base)"], dir)) {
            return await keep("há commits entre \(start.prefix(12)) e o HEAD que já estão na base")
        }
        let commits = await out(["log", "--format=%h %s", "\(start)..\(head)"], dir) ?? ""
        let files = (await out(["diff", "--name-only", start, head], dir) ?? "").split(separator: "\n").joined(separator: ", ")
        let patch = try? await host.laneGit(["format-patch", "--stdout", "--binary", "\(start)..\(head)"], stdin: nil, timeout: .seconds(120),
                                            cap: Self.discardCap, in: dir)
        guard let patch, patch.status == 0, !patch.truncated, !patch.stdoutData.isEmpty else { return await keep("o patch não pôde ser gerado") }
        let folder = host.patchDir(id).appendingPathComponent(Self.discardedFolder)
        let file = folder.appendingPathComponent("\(AutoLandSummary.fileName(host.now()).dropLast(3))-\(head.prefix(12)).patch")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try patch.stdoutData.write(to: file, options: .withoutOverwriting)
        } catch { return await keep("o patch não foi gravado: \(error.localizedDescription)") }
        guard (try? await host.git(["reset", "-q", "--hard", start], in: dir))?.status == 0 else { return await keep("git reset falhou") }
        try? await store.update(id) { $0.loop?.autoLand?.startHead = nil }   // back on it: nothing left to carry
        let line = "[loop] auto-land: nada integrado, então descartei do cercado os commits da tentativa (\(start.prefix(12))..\(head.prefix(12))): "
            + commits.split(separator: "\n").joined(separator: "; ") + ". Arquivos: \(files). O cercado voltou a \(start.prefix(12)). "
            + "Patch: \(file.path). Para recuperar, no cercado: git am \(file.path)"
        await note(id, LotBoards.scrub(String(line.prefix(Self.noteChars))))
        return "Descartei do cercado \(commits.split(separator: "\n").count) commit(s) da tentativa; patch: \(file.path) (git am)"
    }
}
