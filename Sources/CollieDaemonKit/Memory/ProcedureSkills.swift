import Foundation
import CollieCore
import CollieProtocol

/// Procedures delivered to Claude as skills: one plugin dir per terminal, `<root>/sandbox/<id>/plugin/collie-procedures`
/// (readable inside the terminal's sandbox, never writable there; removed with the terminal by `SandboxLaunch.remove`),
/// passed with `--plugin-dir`. Never the user's config or repo. Layout from the 2T Task 1 gate (`claude plugin validate`).
enum ProcedureSkills {
    static let name = "collie-procedures"
    static let descriptionMax = 200

    static func dir(_ terminal: UUID, root: URL) -> URL {
        SandboxLaunch.dir(terminal, root: root).appendingPathComponent("plugin").appendingPathComponent(name)
    }

    /// Rebuilds `dir` from the active procedures in `procs` (anything else is ignored): `.claude-plugin/plugin.json` and one
    /// `skills/<slug>/SKILL.md` each, built beside `dir` and swapped in (a live session never reads half of it). With no
    /// procedure it is still a plugin (an empty `skills/`), so the flag never points at nothing. Dirs 0700, files 0600.
    /// Refuses a symlink at `dir`, `plugin/` or the terminal's dir. Returns the ids rendered.
    /// The text is data: the name is the subject's slug; the description one JSON-quoted line; the body only the trigger and
    /// the numbered steps, each re-cleaned to one line (no line can close the frontmatter or open another).
    static func render(_ procs: [MemoryRecord], into dir: URL) throws -> Set<UUID> {
        let fm = FileManager.default, parent = dir.deletingLastPathComponent()
        func refuseLinks() throws {
            for u in [dir, parent, parent.deletingLastPathComponent()] {
                if (try? fm.attributesOfItem(atPath: u.path))?[.type] as? FileAttributeType == .typeSymbolicLink {
                    throw ProtocolError(code: .unavailable, message: "\(u.path) is a symlink; refusing to write skills there")
                }
            }
        }
        try refuseLinks()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try refuseLinks()   // ponytail: checked again after mkdir; the dir is the daemon's, the sandbox can't write it
        let tmp = parent.appendingPathComponent(".\(name)-\(UUID().uuidString)")
        func mkdir(_ u: URL) throws { try fm.createDirectory(at: u, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        func write(_ text: String, _ u: URL) throws {
            guard fm.createFile(atPath: u.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: u.path])
            }
        }
        var ids = Set<UUID>()
        do {
            try mkdir(tmp); try mkdir(tmp.appendingPathComponent(".claude-plugin")); try mkdir(tmp.appendingPathComponent("skills"))
            try write(#"{"name":"collie-procedures","version":"1.0.0","description":"Procedimentos aprendidos pelo Collie"}"#,
                      tmp.appendingPathComponent(".claude-plugin/plugin.json"))
            var used = Set<String>()
            // newest first: it keeps the bare slug when two stores share one
            for r in procs.filter({ $0.kind == .procedure && $0.status == .active }).sorted(by: { $0.updatedAt > $1.updatedAt }) {
                let base = MemoryFile.slug(r.subject)
                var slug = base, n = 1
                while used.contains(slug) { n += 1; slug = String(base.prefix(44)) + "-\(n)" }
                guard let md = skill(r, name: slug) else { continue }
                used.insert(slug)
                let d = tmp.appendingPathComponent("skills").appendingPathComponent(slug)
                try mkdir(d); try write(md, d.appendingPathComponent("SKILL.md"))
                ids.insert(r.id)
            }
            if fm.fileExists(atPath: dir.path) {
                guard renamex_np(tmp.path, dir.path, UInt32(RENAME_SWAP)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                try? fm.removeItem(at: tmp)   // now the old one
            } else if rename(tmp.path, dir.path) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch { try? fm.removeItem(at: tmp); throw error }
        return ids
    }

    /// SKILL.md of `r`, or nil when it has no step.
    static func skill(_ r: MemoryRecord, name: String) -> String? {
        var lines = r.body.components(separatedBy: "\n")[...], when = ""
        if let f = lines.first, f.hasPrefix("Quando:") { when = String(f.dropFirst("Quando:".count)); lines = lines.dropFirst() }
        let title = CuratorOps.clean(r.title, cap: CuratorOps.titleMax, multiline: false)
        guard let body = MemoryLearning.procedureBody(when: when.isEmpty ? title : when, steps: lines.joined(separator: "\n")) else { return nil }
        let trigger = body.prefix { $0 != "\n" }
        let desc = CuratorOps.clean("\(title). \(trigger)".replacingOccurrences(of: "---", with: "—"), cap: descriptionMax, multiline: false)
        let enc = JSONEncoder(); enc.outputFormatting = .withoutEscapingSlashes
        let quoted = (try? enc.encode(desc)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        return "---\nname: \(name)\ndescription: \(quoted)\n---\n\n# \(title)\n\n\(body)\n"
    }

    private final class Cache: @unchecked Sendable {   // `lock` guards `value`
        let lock = NSLock(); var value: Bool?
    }
    private static let cache = Cache()

    /// `--plugin-dir` is in the installed claude's `--help` (tokenless; the claude on `env`'s PATH). Cached for the
    /// daemon's life. ponytail: a claude upgraded meanwhile shows up at the next daemon start
    static func supported(env: [String: String]) async -> Bool {
        if let v = cache.lock.withLock({ cache.value }) { return v }
        guard let claude = ClaudeCuratorRunner.locate(env) else { return false }   // not cached: it may be installed later
        let r = try? await BoundedProcess.run(executable: claude, args: ["--help"], in: FileManager.default.temporaryDirectory,
                                              env: env, timeout: .seconds(10), cap: 256 << 10)
        guard let r else { return false }
        let v = r.stdout.contains("--plugin-dir")
        cache.lock.withLock { cache.value = v }
        return v
    }
}

extension CommandRouter {
    /// A Claude terminal's skills dir, rendered for its launch (nil: not Claude, no `--plugin-dir` in the installed claude,
    /// or the render failed: it launches as before).
    func skillsDir(_ rec: TerminalRecord, user: [String: String]) async -> URL? {
        guard AgentLaunch.isClaude(rec), await config.claudePluginDir(ProcessInfo.processInfo.environment.merging(user) { _, b in b }) else { return nil }
        let dir = ProcedureSkills.dir(rec.id, root: config.paths.root)
        let paddock = rec.paddockId.flatMap { id in ws.paddocks.first { $0.id == id }?.name }
        return await memory.deliverSkills(rec.id, cwd: rec.cwd, paddock: paddock, lot: ws.lot(of: rec.id)?.id, into: dir) ? dir : nil
    }

    /// Re-renders the skills dirs of live terminals (`only`: one). `force` false: only a terminal whose lot changed.
    /// ponytail: every Claude terminal on any memory change (no per-store filter); a few small files each
    func refreshSkills(_ only: UUID? = nil, force: Bool = true) async {
        for t in ws.terminals where only == nil || t.id == only {
            guard await memory.hasSkills(t.id) else { continue }
            let paddock = t.paddockId.flatMap { id in ws.paddocks.first { $0.id == id }?.name }
            await memory.refreshSkills(t.id, cwd: t.cwd, paddock: paddock, lot: ws.lot(of: t.id)?.id, force: force)
        }
    }
}
