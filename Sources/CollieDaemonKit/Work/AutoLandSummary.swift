import Foundation
import CollieCore

/// A6: the summary every `work run --auto-land` leaves when it ends, whatever stopped it. Written once, in the daemon's
/// own folder of the work (`LoopHost.patchDir`, `<root>/work-loops/<work>/autoland/<AAAA-MM-DD-HHMMSS>.md`), never in
/// the agent's tree; created with `O_EXCL` and mode 0444, so nothing (the daemon included) rewrites it. Its text goes
/// through `LotBoards.scrub` with the daemon's live secrets; it holds only the registry's lines (titles, the review's
/// line, the loop's own `[loop <task>]` notes, already scrubbed when written), never an agent's raw screen.
enum AutoLandSummary {
    static let folder = "autoland"
    /// What `work summary` (and every `WorkSummary`) shows of the file, at most.
    static let shownMax = 4000
    static let vetoMax = 300

    /// The land's conditions, in the order `WorkLoop.landConditions` checks them, by the stop each one fails with.
    static let conditions: [(code: WorkLoopState.Stop.Code, name: String)] = [
        (.landNotFactory, "cercado fábrica"), (.landGateRed, "portão"), (.landReviewVeto, "revisão limpa de cada tarefa"), (.landAcceptRed, "aceite em runtime"),
        (.landCiRed, "CI local"), (.landDirty, "árvore limpa, HEAD parado e ninguém trabalhando"), (.landConflict, "land (merge)"),
    ]

    /// `AAAA-MM-DD-HHMMSS`, in the daemon's local time.
    static func fileName(_ at: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: at) + ".md"
    }

    static func duration(_ s: Int) -> String {
        let h = s / 3600, m = s % 3600 / 60, sec = s % 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m))" : m > 0 ? "\(m)min\(String(format: "%02d", sec))s" : "\(sec)s"
    }

    /// The summary's text (not yet scrubbed). `stop` nil: the loop finished with no land and no stop (a task not done).
    /// `base`: the base checkout the revert line names; `doctor`: `factory doctor`'s layers at the end.
    static func text(_ w: Work, started: Date, ended: Date, stop: WorkLoopState.Stop?, base: String?, doctor: String?) -> String {
        func c(_ s: String, _ max: Int = 200) -> String { RerailText.clean(s, max: max) }
        let iso = ISO8601DateFormatter()
        let al = w.loop?.autoLand
        // A5: a land made, whatever ended the chain after it (`queueEmpty`, `maxReached`, the daily cap...)
        let landed = al?.after != nil
        var l = ["# Auto-land: \(c(w.title, 120))", "",
                 "- início: \(iso.string(from: started)) · fim: \(iso.string(from: ended)) · duração: \(duration(max(0, Int(ended.timeIntervalSince(started).rounded()))))",
                 "- stopReason: " + (stop.map { "\($0.code.rawValue) (\(c($0.label, 300)))" } ?? "nenhum (laço terminou sem integrar)")]
        if let doctor { l.append("- doctor no momento: \(doctor)") }
        l += ["", landed ? "## Trabalho integrado (1)" : "## Trabalhos integrados: 0", ""]
        if landed, let al {
            l.append("- título: \(c(w.title, 120))")
            l.append("- base antes: \(al.before ?? "?") · depois: \(al.after ?? "?")")
        }
        // F3: a work with no `--accept` says so (the land had three conditions of the result, not four)
        if !w.tasks.contains(where: { $0.accept != nil }) { l.append("- sem aceite em runtime") }
        l += ["", "### Tarefas", ""]
        for t in w.tasks where w.loop?.tasks?.contains(t.id) ?? true {
            let secs = t.evidence.map { duration($0.seconds) } ?? "?"
            l.append("- \(c(t.title, 120)) [\(t.state.rawValue)]: tentativas \(t.tries ?? 0), tempo \(secs)")
            l.append("  - aprovou: " + (t.reviewClean == true ? c(t.review ?? "sim", 300) : "ninguém (\(c(t.review ?? "sem revisão", 300)))"))
            if t.accept != nil { l.append("  - aceite em runtime: " + c(t.acceptResult ?? "não rodou", 300)) }
            // the loop's own failure notes of the task: the review's vetoes, "[persona] arquivo:linha ..." each
            let vetoes = w.notes.filter { $0.text.hasPrefix("[loop \(t.id)] ") }.compactMap { n -> String? in
                guard let r = n.text.split(separator: "\n").first?.range(of: "revisor recusou: ") else { return nil }
                return String(n.text.split(separator: "\n")[0][r.upperBound...])
            }
            for v in vetoes { l.append("  - vetou: \(c(v, vetoMax))") }
        }
        l += ["", "## Não feito", ""]
        // C2: a land with no `before` recorded still landed: no push, and the revert line says it does not know the commit
        if landed {
            l.append("- sem push; pronto para você revisar e dar push")
            l.append("- para reverter (texto, nunca executado): `git -C \(base ?? "<base>") reset --hard \(al?.before ?? "?")`")
        } else {
            l.append("- nada integrado; sem push")
            if let stop {
                if let i = conditions.firstIndex(where: { $0.code == stop.code }) {
                    let accepts = w.tasks.contains { $0.accept != nil }
                    let ok = conditions.prefix(i).filter { $0.code != .landAcceptRed || accepts }.map(\.name)
                    l.append("- condições que passaram: " + (ok.isEmpty ? "nenhuma" : ok.joined(separator: ", ")))
                    l.append("- parou em: \(conditions[i].name): \(c(stop.label, 300))")
                } else {
                    l.append("- parou antes do land: \(c(stop.label, 300))")
                }
            }
            let left = w.tasks.filter { $0.state != .done }   // C2: a dropped task is not done (it lands nothing)
            if !left.isEmpty { l.append("- tarefas não feitas: " + left.map { c($0.title, 80) }.joined(separator: "; ")) }
        }
        // F1: the same failure in 2+ attempts, for the owner to decide on (nothing is saved to memory)
        l += TrapCandidates.section(w)
        return l.joined(separator: "\n") + "\n"
    }

    /// C2: a name taken gets `-1`, `-2` ... up to this suffix before the write gives up.
    static let maxSuffix = 20

    /// `text` written as `dir/<name>`: `O_EXCL` (an existing file is never replaced; C2: a name taken is tried again as
    /// `<stem>-1.md` ... `<stem>-20.md`, then it throws) and 0444. C2: whole or not at all: every byte is written (a short
    /// write goes on, `EINTR` is retried) and a write that fails unlinks the partial file before throwing. `put` is
    /// `write(2)` (the tests' fakes fail it).
    @discardableResult
    static func write(_ text: String, in dir: URL, name: String,
                      put: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        let bytes = Array(text.utf8)
        for n in 0...maxSuffix {
            let url = dir.appendingPathComponent(n == 0 ? name : "\(stem)-\(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o444)
            guard fd >= 0 else {
                let e = errno
                if e == EEXIST { continue }
                throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
            }
            defer { close(fd) }
            fchmod(fd, 0o444)   // the umask cannot widen it, but make it exact
            var off = 0, failure: Int32 = 0
            while off < bytes.count {
                let r = bytes.withUnsafeBytes { put(fd, $0.baseAddress! + off, bytes.count - off) }
                if r < 0 {
                    let e = errno
                    if e == EINTR { continue }
                    failure = e; break
                }
                if r == 0 { failure = EIO; break }
                off += r
            }
            guard off == bytes.count else {
                unlink(url.path)
                throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
            }
            return url
        }
        throw POSIXError(.EEXIST)
    }

    /// The file at `path` (a regular file, never through a link), its first `max` characters; nil: not readable.
    static func read(_ path: String, max: Int = shownMax) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, let d = try? h.read(upToCount: max * 4) else { return nil }
        let s = String(decoding: d, as: UTF8.self)
        return s.count > max ? String(s.prefix(max)) + "\n…" : s
    }

    /// The owner's one line at the end.
    /// A5: `landed`, the works the chain landed in all (this one's land included).
    /// C2: each stop named by its label and its code (`[maxReached]`), and the line goes through `LotBoards.scrub` with
    /// `secrets` (a stop's detail may carry a check's output).
    static func ownerLine(title: String, stop: WorkLoopState.Stop?, left: Int, path: String?, error: String?, landed: Int = 0,
                          secrets: Set<String> = []) -> String {
        func why(_ s: WorkLoopState.Stop) -> String { "\(s.label) [\(s.code.rawValue)]" }
        let what = landed > 0 ? (landed == 1 ? "integrou 1 trabalho" : "integrou \(landed) trabalhos")
                + (stop.map { $0.code == .landed ? "" : $0.finishes ? " (\(why($0)))" : "; parou em \(why($0))" } ?? "")
            : stop.map { "parou em \(why($0))" } ?? "integrou 0 trabalhos (\(left) tarefa(s) não feitas)"
        let at = path.map { "Resumo: \($0)" } ?? "resumo não gravado (\(error ?? "?"))"
        return LotBoards.scrub("Collie: laço \"\(title)\": \(what). \(at). Veja: \(WorkLoop.autoLandHint)", secrets: secrets)
    }

    /// C2: the owner's line when the registry could not be read at the end (no title, no tasks): the work's id and the stop.
    static func minimalOwnerLine(work: UUID, stop: WorkLoopState.Stop?, error: String, secrets: Set<String> = []) -> String {
        let what = stop.map { "parou em \($0.label) [\($0.code.rawValue)]" } ?? "terminou"
        return LotBoards.scrub("Collie: laço do trabalho \(work.uuidString.prefix(8).lowercased()): \(what). Resumo não gravado "
            + "(o registro não foi lido: \(RerailText.clean(error, max: 200))). Veja: \(WorkLoop.autoLandHint)", secrets: secrets)
    }
}

extension WorkLoop {
    /// A6: the run of `work` with `--auto-land` ended (`stop`, nil: finished with no land): its summary written once,
    /// its path on the loop, and one line to the owner (A5: `notify` false, a work the chain goes on from: none; the
    /// chain's last work tells, counting every land). A loop stopped from outside keeps the reason it was given.
    /// C2: `landing`, the run started with `--auto-land`: a registry that cannot be read at the end still tells the owner
    /// (`minimalOwnerLine`), since no summary can be written.
    func autoLandSummary(work id: UUID, started: Date, stop: WorkLoopState.Stop?, dir: URL, notify: Bool = true, landing: Bool = false) async {
        let read: Work?
        do { read = try await store.get(id) } catch {
            if notify && landing { await host.notifyOwner(AutoLandSummary.minimalOwnerLine(work: id, stop: stop, error: "\(error)", secrets: await host.secrets())) }
            return
        }
        guard let w = read, w.loop?.autoLand != nil else { return }
        let why = w.loop?.state == .running ? stop : (w.loop?.stopReason ?? stop)
        let ended = host.now()
        // ponytail: the base checkout is the main worktree (the common git dir's parent); a bare base would name its .git
        let common = await out(["rev-parse", "--path-format=absolute", "--git-common-dir"], dir)
        let base = common.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        // C3a: the doctor of the paddock's HEAD, never of the tree the agent edits
        let doctor: String? = switch await FactoryDoctorReader.headSnapshot(dir: dir) {
        case .success(let s): FactoryDoctor.score(s).layers.map { "\($0.layer.rawValue) \($0.score)/3" }.joined(separator: ", ")
        case .failure(let e): "não leu (\(e.message))"
        }
        let secrets = await host.secrets()
        let text = LotBoards.scrub(AutoLandSummary.text(w, started: started, ended: ended, stop: why, base: base, doctor: doctor),
                                   secrets: secrets)
        var path: String?, failure: String?
        do {
            path = try AutoLandSummary.write(text, in: host.patchDir(id).appendingPathComponent(AutoLandSummary.folder),
                                             name: AutoLandSummary.fileName(ended)).path
        } catch { failure = "\(error)" }
        if let path { try? await store.update(id) { $0.loop?.autoLand?.summary = path } }
        else { await note(id, "[loop] auto-land: resumo não gravado (\(failure ?? "?"))") }
        guard notify else { return }
        let left = w.tasks.filter { $0.state != .done }.count
        let landed = (w.loop?.autoLand?.chained ?? 0) + (w.loop?.autoLand?.after != nil ? 1 : 0)
        await host.notifyOwner(AutoLandSummary.ownerLine(title: RerailText.clean(w.title, max: 80), stop: why, left: left, path: path, error: failure,
                                                         landed: landed, secrets: secrets))
    }
}
