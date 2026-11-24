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
        (.landNotFactory, "cercado fábrica"), (.landGateRed, "portão"), (.landReviewVeto, "revisão limpa de cada tarefa"),
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
        let landed = stop?.code == .landed
        var l = ["# Auto-land: \(c(w.title, 120))", "",
                 "- início: \(iso.string(from: started)) · fim: \(iso.string(from: ended)) · duração: \(duration(max(0, Int(ended.timeIntervalSince(started).rounded()))))",
                 "- stopReason: " + (stop.map { "\($0.code.rawValue) (\(c($0.label, 300)))" } ?? "nenhum (laço terminou sem integrar)")]
        if let doctor { l.append("- doctor no momento: \(doctor)") }
        l += ["", landed ? "## Trabalho integrado (1)" : "## Trabalhos integrados: 0", ""]
        if landed, let al {
            l.append("- título: \(c(w.title, 120))")
            l.append("- base antes: \(al.before ?? "?") · depois: \(al.after ?? "?")")
        }
        l += ["", "### Tarefas", ""]
        for t in w.tasks where w.loop?.tasks?.contains(t.id) ?? true {
            let secs = t.evidence.map { duration($0.seconds) } ?? "?"
            l.append("- \(c(t.title, 120)) [\(t.state.rawValue)]: tentativas \(t.tries ?? 0), tempo \(secs)")
            l.append("  - aprovou: " + (t.reviewClean == true ? c(t.review ?? "sim", 300) : "ninguém (\(c(t.review ?? "sem revisão", 300)))"))
            // the loop's own failure notes of the task: the review's vetoes, "[persona] arquivo:linha ..." each
            let vetoes = w.notes.filter { $0.text.hasPrefix("[loop \(t.id)] ") }.compactMap { n -> String? in
                guard let r = n.text.split(separator: "\n").first?.range(of: "revisor recusou: ") else { return nil }
                return String(n.text.split(separator: "\n")[0][r.upperBound...])
            }
            for v in vetoes { l.append("  - vetou: \(c(v, vetoMax))") }
        }
        l += ["", "## Não feito", ""]
        if landed, let before = al?.before {
            l.append("- sem push; pronto para você revisar e dar push")
            l.append("- para reverter (texto, nunca executado): `git -C \(base ?? "<base>") reset --hard \(before)`")
        } else {
            l.append("- nada integrado; sem push")
            if let stop {
                if let i = conditions.firstIndex(where: { $0.code == stop.code }) {
                    let ok = conditions.prefix(i).map(\.name)
                    l.append("- condições que passaram: " + (ok.isEmpty ? "nenhuma" : ok.joined(separator: ", ")))
                    l.append("- parou em: \(conditions[i].name): \(c(stop.label, 300))")
                } else {
                    l.append("- parou antes do land: \(c(stop.label, 300))")
                }
            }
            let left = w.tasks.filter { $0.state != .done && $0.state != .abandoned }
            if !left.isEmpty { l.append("- tarefas não feitas: " + left.map { c($0.title, 80) }.joined(separator: "; ")) }
        }
        return l.joined(separator: "\n") + "\n"
    }

    /// `text` written as `dir/<name>`: `O_EXCL` (an existing file is never replaced: throws) and 0444.
    @discardableResult
    static func write(_ text: String, in dir: URL, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o444)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        fchmod(fd, 0o444)   // the umask cannot widen it, but make it exact
        try h.write(contentsOf: Data(text.utf8))
        return url
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
    static func ownerLine(title: String, stop: WorkLoopState.Stop?, left: Int, path: String?, error: String?) -> String {
        let what = stop?.code == .landed ? "integrou 1 trabalho"
            : stop.map { "parou em \($0.label)" } ?? "integrou 0 trabalhos (\(left) tarefa(s) não feitas)"
        let at = path.map { "Resumo: \($0)" } ?? "resumo não gravado (\(error ?? "?"))"
        return "Collie: laço \"\(title)\": \(what). \(at). Veja: \(WorkLoop.autoLandHint)"
    }
}

extension WorkLoop {
    /// A6: the run of `work` with `--auto-land` ended (`stop`, nil: finished with no land): its summary written once,
    /// its path on the loop, and one line to the owner. A loop stopped from outside keeps the reason it was given.
    func autoLandSummary(work id: UUID, started: Date, stop: WorkLoopState.Stop?, dir: URL) async {
        guard let w = try? await store.get(id), w.loop?.autoLand != nil else { return }
        let why = w.loop?.state == .running ? stop : (w.loop?.stopReason ?? stop)
        let ended = host.now()
        // ponytail: the base checkout is the main worktree (the common git dir's parent); a bare base would name its .git
        let common = await out(["rev-parse", "--path-format=absolute", "--git-common-dir"], dir)
        let base = common.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        let doctor: String? = switch FactoryDoctorReader.snapshot(root: dir) {
        case .success(let s): FactoryDoctor.score(s).layers.map { "\($0.layer.rawValue) \($0.score)/3" }.joined(separator: ", ")
        case .failure(let e): "não leu (\(e.message))"
        }
        let text = LotBoards.scrub(AutoLandSummary.text(w, started: started, ended: ended, stop: why, base: base, doctor: doctor),
                                   secrets: await host.secrets())
        var path: String?, failure: String?
        do {
            path = try AutoLandSummary.write(text, in: host.patchDir(id).appendingPathComponent(AutoLandSummary.folder),
                                             name: AutoLandSummary.fileName(ended)).path
        } catch { failure = "\(error)" }
        if let path { try? await store.update(id) { $0.loop?.autoLand?.summary = path } }
        else { await note(id, "[loop] auto-land: resumo não gravado (\(failure ?? "?"))") }
        let left = w.tasks.filter { $0.state != .done && $0.state != .abandoned }.count
        await host.notifyOwner(AutoLandSummary.ownerLine(title: RerailText.clean(w.title, max: 80), stop: why, left: left, path: path, error: failure))
    }
}
