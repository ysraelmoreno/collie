import Foundation
import Darwin
import CollieCore
import CollieProtocol

/// `.colliebackup` (an Orq `.orqbackup` is the same format; the extension is never checked here): a zip (`ditto -c -k --norsrc`, entries at its root) of the user's Collie data — `manifest.json`
/// (`{format: 1, createdAt, collieVersion, parts, workspace}`) and the parts `design/` (figcraft server data, registries,
/// systems, exports), `artifacts/` (with `.removed/`), `memory/`, `workspaces/` (without `*/terminals`, the scrollback
/// spills), `work/`, `herds/` (with `.removed/`) `lots/` (each lot's memory and board, without `*/cache`, its index) and `comments/` (comments on pages). Machine-specific data stays out (`run/`, `hooks/`, `cache/`, `usage/`, `screens/`, `admin.token`);
/// `default-workspace` travels as the manifest's `workspace`. It holds the design files' secret links: 0600, app only.
///
/// An import is checked, extracted and staged in `<root>/.import-pending/`; collied applies it at its next start, before
/// anything is loaded (the stores keep their data in memory: a swap under a live daemon would be written over).
/// Nothing is deleted: the current parts move to `<root>/.replaced-<epochMs>/`.
public enum DataBackup {
    static let parts = ["design", "artifacts", "memory", "workspaces", "work", "herds", "lots", "comments"]
    static let pendingName = ".import-pending"
    /// Parts under the name an older backup gives them (Orq's and Collie's before the herding vocabulary).
    static let legacyParts = [LegacyOrq.partituraDir: "herds"]

    struct Manifest: Codable {
        var format: Int; var createdAt: Date; var collieVersion: String; var parts: [String]; var workspace: String?
        init(format: Int, createdAt: Date, collieVersion: String, parts: [String], workspace: String?) {
            self.format = format; self.createdAt = createdAt; self.collieVersion = collieVersion; self.parts = parts; self.workspace = workspace
        }
        private enum CodingKeys: String, CodingKey { case format, createdAt, collieVersion, parts, workspace }
        private enum Legacy: String, CodingKey { case orqVersion }
        init(from d: Decoder) throws {   // an Orq backup says `orqVersion`
            let c = try d.container(keyedBy: CodingKeys.self)
            format = try c.decode(Int.self, forKey: .format); createdAt = try c.decode(Date.self, forKey: .createdAt)
            collieVersion = try c.decodeIfPresent(String.self, forKey: .collieVersion)
                ?? d.container(keyedBy: Legacy.self).decode(String.self, forKey: .orqVersion)
            parts = try c.decode([String].self, forKey: .parts).map { DataBackup.legacyParts[$0] ?? $0 }
            workspace = try c.decodeIfPresent(String.self, forKey: .workspace)
        }
    }

    /// What a backup holds, for the app's confirmation.
    struct Summary: Equatable, Sendable {
        var designs: Int, systems: Int, artifacts: Int
        var json: [String: JSONValue] {
            ["designs": .number(Double(designs)), "systems": .number(Double(systems)), "artifacts": .number(Double(artifacts))]
        }
    }

    private static let ditto = URL(fileURLWithPath: "/usr/bin/ditto"), zipinfo = URL(fileURLWithPath: "/usr/bin/zipinfo")

    // MARK: export

    /// Writes the backup to `out` (0600, replacing a file there: the save panel asked). The figcraft server is stopped
    /// while the parts are copied (`paused` runs then: tests) and started again after, even when the copy fails. `work/`
    /// is copied while `work` and `chat` write nothing, so work.json and its archive agree, and so do the chat's files.
    static func export(root: URL, to out: URL, server: FigcraftServer, work: WorkStore? = nil, chat: ChatLog? = nil, version: String,
                       paused: @Sendable () async -> Void = {}) async throws(ProtocolError) -> Summary {
        let tmp = try await UnixSocketClient.offPool { try scratch(root, "backup") }
        let r: Result<Summary, ProtocolError>
        do { r = .success(try await export(root: root, tmp: tmp, to: out, server: server, work: work, chat: chat, version: version, paused: paused)) }
        catch { r = .failure(error) }
        _ = try? await UnixSocketClient.offPool { try? FileManager.default.removeItem(at: tmp) }
        return try r.get()
    }

    private static func export(root: URL, tmp: URL, to out: URL, server: FigcraftServer, work: WorkStore?, chat: ChatLog?, version: String,
                               paused: @Sendable () async -> Void) async throws(ProtocolError) -> Summary {
        let data = tmp.appendingPathComponent("data")
        let present = try await UnixSocketClient.offPool { () throws -> [String] in
            let ps = parts.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
            for p in ps {   // what an import would refuse is refused here, so no backup is made that cannot be imported
                try walk(root.appendingPathComponent(p), skip: skipped(p)) { rel, st in
                    guard plain(st) else { throw odd(p, rel) }
                }
            }
            return ps
        }
        let wasUp = await server.isRunning
        await server.hold(true)   // a design command meanwhile gets "backup in progress" instead of a new server
        await server.stop()
        var failed: ProtocolError?
        do {
            for p in present {
                let src = root.appendingPathComponent(p), dst = data.appendingPathComponent(p), skip = skipped(p)
                if p == "work" {
                    let copyWork: @Sendable () async throws -> Void = {
                        if let work { _ = try await work.withPaused { try copy(p, src, to: dst, skip: skip) } }
                        else { try await UnixSocketClient.offPool { try copy(p, src, to: dst, skip: skip) } }
                    }
                    if let chat { try await chat.withPaused(copyWork) } else { try await copyWork() }
                } else {
                    try await UnixSocketClient.offPool { try copy(p, src, to: dst, skip: skip) }
                }
            }
            await paused()
        } catch { failed = (error as? ProtocolError) ?? ProtocolError(code: .internal, message: "backup: \(error)") }
        await server.hold(false)
        if wasUp { _ = try? await server.ensureRunning() }   // the Design panels reconnect as after a crash
        if let failed { throw failed }

        let counted = try await UnixSocketClient.offPool { () throws -> Summary in
            let wsId = (try? String(contentsOf: root.appendingPathComponent("default-workspace"), encoding: .utf8))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap(UUID.init(uuidString:))
            let m = Manifest(format: 1, createdAt: Date(), collieVersion: version, parts: present, workspace: wsId?.uuidString)
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try DesignService.writePrivate(try enc.encode(m), to: data.appendingPathComponent("manifest.json"))
            return summary(data)
        }
        let zip = tmp.appendingPathComponent("out.zip")
        try await run(ditto, ["-c", "-k", "--norsrc", data.path, zip.path], code: .internal)
        // copied next to `out` (it may be on another volume) under a name of ours alone, checked, then renamed over it
        try await UnixSocketClient.offPool {
            let fm = FileManager.default
            let partial = out.deletingLastPathComponent().appendingPathComponent(".\(out.lastPathComponent).\(UUID().uuidString.lowercased()).partial")
            func fail(_ why: String) -> ProtocolError {
                try? fm.removeItem(at: partial)
                return ProtocolError(code: .invalidArgs, message: "backup: cannot write \(out.path): \(why)")
            }
            guard chmod(zip.path, 0o600) == 0 else { throw ProtocolError(code: .internal, message: "backup: cannot protect \(zip.path)") }
            do { try fm.copyItem(at: zip, to: partial) } catch { throw fail(error.localizedDescription) }
            var a = stat(), b = stat()
            guard chmod(partial.path, 0o600) == 0, lstat(zip.path, &a) == 0, lstat(partial.path, &b) == 0,
                  b.st_mode & S_IFMT == S_IFREG, b.st_mode & 0o777 == 0o600, a.st_size == b.st_size else { throw fail("copy incomplete") }
            guard rename(partial.path, out.path) == 0 else { throw fail(String(cString: strerror(errno))) }
        }
        return counted
    }

    /// What the backup leaves out of part `p` (paths relative to it): the scrollback spills, `workspaces/*/terminals`, and
    /// the lots' memory indexes, `lots/*/cache` (rebuilt from the memory files; may be mid-write).
    // ponytail: board appends aren't held during the copy (the chat's are); a post landing then may end up half a line,
    // which reads as skipped. Hold `LotBoards` like `chat.withPaused` if that matters.
    private static func skipped(_ p: String) -> @Sendable (String) -> Bool {
        let dir = p == "workspaces" ? "/terminals" : p == "lots" ? "/cache" : nil
        return { rel in dir.map { rel.split(separator: "/").count == 2 && rel.hasSuffix($0) } ?? false }
    }

    private static func plain(_ st: stat) -> Bool {
        let kind = st.st_mode & S_IFMT
        return kind == S_IFDIR || (kind == S_IFREG && st.st_nlink == 1)
    }
    private static func odd(_ p: String, _ rel: String) -> ProtocolError {
        ProtocolError(code: .invalidArgs, message: "cannot back up \(p)/\(rel): not a plain file or folder")
    }

    /// Each entry under `dir` (relative path, lstat; links not followed) but those `skip` names (a folder: with all in it)
    /// and `.*.tmp` (an atomic write in flight). An entry gone meanwhile (a spill rotated, a write renamed) is left out.
    private static func walk(_ dir: URL, skip: (String) -> Bool, _ body: (String, stat) throws -> Void) throws {
        guard let e = FileManager.default.enumerator(atPath: dir.path) else { return }
        var st = stat()
        while let rel = e.nextObject() as? String {
            let name = (rel as NSString).lastPathComponent
            if skip(rel) { e.skipDescendants(); continue }
            // skipDescendants after a file would also skip the rest of its folder: a write in flight is just passed over
            if name.hasPrefix(".") && name.hasSuffix(".tmp") { continue }
            guard lstat(dir.appendingPathComponent(rel).path, &st) == 0 else {
                if errno == ENOENT { continue }
                throw ProtocolError(code: .invalidArgs, message: "cannot back up \(dir.lastPathComponent)/\(rel): \(String(cString: strerror(errno)))")
            }
            try body(rel, st)
        }
    }

    /// Part `p` at `src` copied to `dst` as `walk` sees it: plain folders (0700) and files (data and mode); a file gone
    /// before it is copied is left out. Synchronous: off the pool.
    private static func copy(_ p: String, _ src: URL, to dst: URL, skip: (String) -> Bool) throws {
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try walk(src, skip: skip) { rel, st in
            let to = dst.appendingPathComponent(rel).path
            guard plain(st) else { throw odd(p, rel) }
            if st.st_mode & S_IFMT == S_IFDIR {
                guard mkdir(to, 0o700) == 0 || errno == EEXIST else { throw cannot(p, rel) }
            } else if copyfile(src.appendingPathComponent(rel).path, to, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_STAT | COPYFILE_NOFOLLOW)) != 0 {
                guard errno == ENOENT else { throw cannot(p, rel) }
            }
        }
    }
    private static func cannot(_ p: String, _ rel: String) -> ProtocolError {
        ProtocolError(code: .internal, message: "backup: cannot copy \(p)/\(rel): \(String(cString: strerror(errno)))")
    }

    // MARK: import

    /// Checks `from` and returns what it holds; unless `dryRun`, stages it for the next daemon start (a staged import
    /// not yet applied is replaced). Refused (`.invalidArgs`, nothing touched): no `manifest.json` of format 1, a part
    /// not known, an entry outside the listed parts, an absolute or `..` path, a symlink or a hard link.
    static func stage(root: URL, from: URL, dryRun: Bool) async throws(ProtocolError) -> Summary {
        guard FileManager.default.fileExists(atPath: from.path) else {
            throw ProtocolError(code: .invalidArgs, message: "no backup at \(from.path)")
        }
        // The lstat walk after extracting (`check`) is the gate. This listing only keeps ditto from writing through a
        // symlinked folder (or stripping `..`) while it extracts.
        let names = try await run(zipinfo, ["-1", from.path], code: .invalidArgs)
        for n in names.split(separator: "\n").map(String.init) where !n.isEmpty {
            let comps = n.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !n.hasPrefix("/"), !comps.contains(".."), comps[0] == "manifest.json" || parts.contains(comps[0]) || legacyParts[comps[0]] != nil else {
                throw bad("entry '\(n)' is outside the backup's parts")
            }
        }
        let long = try await run(zipinfo, [from.path], code: .invalidArgs)
        if long.split(separator: "\n").contains(where: { $0.hasPrefix("l") && $0.dropFirst().prefix(9).allSatisfy { "rwxsStT-".contains($0) } }) {
            throw bad("it holds a symbolic link")
        }
        let tmp = try await UnixSocketClient.offPool { try scratch(root, "import") }
        do {
            let data = tmp.appendingPathComponent("data")
            try await run(ditto, ["-x", "-k", "--norsrc", from.path, data.path], code: .invalidArgs)
            let s = try await UnixSocketClient.offPool { () throws -> Summary in
                for (old, new) in legacyParts where FileManager.default.fileExists(atPath: data.appendingPathComponent(old).path) {
                    guard rename(data.appendingPathComponent(old).path, data.appendingPathComponent(new).path) == 0 else {
                        throw bad("it holds both \(old)/ and \(new)/")
                    }
                }
                try check(data)
                guard !dryRun else { return summary(data) }
                let pending = root.appendingPathComponent(pendingName)
                try? FileManager.default.removeItem(at: pending)   // an earlier staged import: our own scratch
                guard rename(tmp.path, pending.path) == 0 else {
                    throw ProtocolError(code: .internal, message: "backup: cannot stage the import (\(String(cString: strerror(errno))))")
                }
                return summary(pending.appendingPathComponent("data"))
            }
            if dryRun { _ = try? await UnixSocketClient.offPool { try? FileManager.default.removeItem(at: tmp) } }
            return s
        } catch {
            _ = try? await UnixSocketClient.offPool { try? FileManager.default.removeItem(at: tmp) }
            throw error
        }
    }

    /// The extracted tree, walked without following links: the manifest, then only plain folders and single-link
    /// files inside the parts it lists. Returns the manifest.
    @discardableResult private static func check(_ data: URL) throws(ProtocolError) -> Manifest {
        let mf = data.appendingPathComponent("manifest.json")
        var st = stat()
        guard lstat(mf.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, let m = manifest(mf) else { throw bad("no readable manifest.json") }
        guard m.format == 1 else { throw bad("format \(m.format) is not supported (1)") }
        guard Set(m.parts).isSubset(of: parts), Set(m.parts).count == m.parts.count else { throw bad("unknown parts \(m.parts)") }
        guard m.workspace.map({ UUID(uuidString: $0) != nil }) ?? true else { throw bad("workspace is not an id") }
        let e = FileManager.default.enumerator(atPath: data.path)
        while let rel = e?.nextObject() as? String {
            guard lstat(data.appendingPathComponent(rel).path, &st) == 0 else { throw bad("cannot read '\(rel)'") }
            let top = String(rel.split(separator: "/").first ?? "")
            let kind = st.st_mode & S_IFMT
            if rel == "manifest.json" { continue }
            guard m.parts.contains(top) else { throw bad("entry '\(rel)' is outside the listed parts") }
            guard kind == S_IFDIR || (kind == S_IFREG && st.st_nlink == 1) else { throw bad("'\(rel)' is not a plain file or folder") }
        }
        return m
    }

    /// Applies a staged import (collied, before it reads `default-workspace`): each part moves to `.replaced-<epochMs>/`
    /// and the backup's takes its place (a part the backup lacks is left empty: the backup is the whole state).
    /// Skipped while a daemon answers on the socket; the staged tree is checked again first (it sat on disk since).
    /// Resumable: a listed part no longer staged was applied by an earlier, interrupted start and is left as it is;
    /// `.import-pending` goes only once every part is in place. true: applied.
    @discardableResult public static func applyPending(_ paths: Paths) -> Bool {
        let root = paths.root, pending = root.appendingPathComponent(pendingName), data = pending.appendingPathComponent("data")
        let fm = FileManager.default
        guard fm.fileExists(atPath: data.appendingPathComponent("manifest.json").path), !daemonAlive(paths.socket) else { return false }
        let m: Manifest
        do { m = try check(data) } catch { log("collied: staged import refused (\(error.message)); left in \(pending.path)"); return false }
        let old = root.appendingPathComponent(".replaced-\(Int(Date().timeIntervalSince1970 * 1000))")
        func move(_ a: URL, _ b: URL) -> Bool {
            try? fm.createDirectory(at: old, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard rename(a.path, b.path) == 0 else { log("collied: import: cannot move \(a.path): \(String(cString: strerror(errno)))"); return false }
            return true
        }
        for p in parts {
            let cur = root.appendingPathComponent(p), new = data.appendingPathComponent(p)
            let staged = fm.fileExists(atPath: new.path)
            if m.parts.contains(p) && !staged { continue }   // applied by an interrupted start: keep it
            if fm.fileExists(atPath: cur.path), !move(cur, old.appendingPathComponent(p)) { return false }
            if staged, !move(new, cur) { return false }
        }
        if let w = m.workspace {
            let f = root.appendingPathComponent("default-workspace")
            let now = (try? String(contentsOf: f, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            if now != w {
                if now != nil, !move(f, old.appendingPathComponent("default-workspace")) { return false }
                do { try DesignService.writePrivate(Data(w.utf8), to: f) } catch { log("collied: import: \(error.message)"); return false }
            }
        }
        try? fm.removeItem(at: pending)
        return true
    }

    // MARK: helpers

    private static func bad(_ why: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: "not a valid Collie backup: \(why)") }

    static func manifest(_ f: URL) -> Manifest? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: f)).flatMap { try? dec.decode(Manifest.self, from: $0) }
    }

    private static func summary(_ data: URL) -> Summary {
        func count(_ rel: String) -> Int {
            ((try? Data(contentsOf: data.appendingPathComponent(rel))).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [Any])?.count ?? 0
        }
        return Summary(designs: count("design/files.json"), systems: count("design/systems.json"), artifacts: count("artifacts/artifacts.json"))
    }

    /// A new 0700 folder of ours under the data root (never a shared /tmp).
    private static func scratch(_ root: URL, _ kind: String) throws -> URL {
        let d = root.appendingPathComponent(".\(kind)-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(d.path, 0o700)
        return d
    }

    @discardableResult
    private static func run(_ exe: URL, _ args: [String], code: ErrorCode) async throws(ProtocolError) -> String {
        let r = try await BoundedProcess.run(executable: exe, args: args, in: URL(fileURLWithPath: "/"), env: ["PATH": "/usr/bin:/bin"],
                                             timeout: .seconds(600), cap: 16 << 20)
        guard r.status == 0, !r.truncated else {
            throw ProtocolError(code: code, message: "\(exe.lastPathComponent) failed: \(r.stderr.prefix(300))")
        }
        return r.stdout
    }

    /// Same probe as the server's bind: a connect that is not refused is a live daemon (an odd error counts as one).
    private static func daemonAlive(_ socket: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: socket.path) else { return false }
        let fd = makeSocket(); defer { close(fd) }
        guard let rc = try? withAddr(socket.path, { connect(fd, $0, $1) }) else { return true }
        return rc == 0 || errno != ECONNREFUSED
    }

    private static func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
}
