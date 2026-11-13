import Foundation
import CollieCore
import CollieProtocol

extension CommandRouter {
    /// `artifact.export`: agent page `id` as an editable .pptx (the app's deck snapshot, built here) or a PDF (the app's),
    /// always at `<artifact>/.export/deck.<ext>` (temp file + rename); `out` then gets a copy (a terminal: under its cwd).
    func exportDeck(_ id: UUID, format: String, out: String?, caller: TerminalRecord?, cwd: String?) async throws -> JSONValue {
        let a = try await artifacts.get(id)
        guard a.kind != .export else { throw ProtocolError(code: .invalidArgs, message: "design exports have no slides") }
        guard format == "pptx" || format == "pdf" else { throw ProtocolError(code: .invalidArgs, message: "format must be pptx|pdf") }
        // checked before the app is asked: a refused --out costs no export
        let dst = try out.map { try exportTarget($0, format: format, caller: caller, cwd: cwd) }
        // the url is built here from the record, never taken from a caller
        let args: [String: JSONValue] = ["id": .string(a.id.uuidString.lowercased()),
                                         "url": .string("collie-artifact://app/\(a.source ?? "\(a.folder)/source.html")")]
        let dir = artifacts.dir.appendingPathComponent("\(a.folder)/.export")
        var slides = 0, warnings: [String] = []
        do {
            if format == "pptx" {
                _ = try await host.callApp(command: "deck.snapshot", args: args, timeout: .seconds(50))
                let (deck, payloads) = try await Self.readDeck(dir)
                warnings = deck.blocked.map { "blocked: " + String($0.prefix { $0 != "?" && $0 != "#" }) }   // queries may carry tokens
                if deck.truncated { warnings.append("snapshot truncated: the page has more elements than an export takes") }
                let built: (data: Data, warnings: [String])
                do { built = try PPTXWriter.build(deck, payloads: payloads) } catch {
                    throw ProtocolError(code: .invalidArgs, message: error == .noSlides ? "page has no slides" : "deck too large to export")
                }
                warnings += built.warnings
                slides = deck.slides.count
                try await UnixSocketClient.offPool { try Self.inDir(dir) { try Self.put($0, "deck.pptx", built.data) } }
            } else {
                let r = try await host.callApp(command: "deck.pdf", args: args, timeout: .seconds(50))
                if case .object(let o) = r, case .number(let n)? = o["slides"] { slides = Int(n) }
                try await UnixSocketClient.offPool {
                    try Self.inDir(dir) { dfd in
                        var st = stat()
                        guard fstatat(dfd, "deck-app.pdf", &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & S_IFMT == S_IFREG,
                              renameat(dfd, "deck-app.pdf", dfd, "deck.pdf") == 0 else { throw ProtocolError(code: .internal, message: "the app left no PDF") }
                    }
                }
            }
        } catch {   // a failed or timed-out app call, a bad snapshot: nothing of the app's is left behind
            try? await UnixSocketClient.offPool { try Self.inDir(dir, Self.dropAppFiles) }
            throw error
        }
        var path = dir.appendingPathComponent("deck.\(format)").path
        if let dst {
            try await UnixSocketClient.offPool {
                let data = try Self.inDir(dir) { dfd -> Data in
                    guard let d = Self.read(dfd, "deck.\(format)", cap: 512 << 20) else { throw ProtocolError(code: .internal, message: "export vanished") }
                    return d
                }
                let parent = dst.deletingLastPathComponent().path
                try Self.inDir(dst.deletingLastPathComponent()) { dfd in
                    // the folder actually opened is the one checked (no link swapped in since)
                    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                    guard fcntl(dfd, F_GETPATH, &buf) == 0, String(cString: buf) == parent else {
                        throw ProtocolError(code: .unauthorized, message: "--out moved while exporting: use collie access request <path> --write")
                    }
                    try Self.put(dfd, dst.lastPathComponent, data)
                }
            }
            path = dst.path
        }
        return .object(["path": .string(path), "format": .string(format), "slides": .number(Double(slides)),
                        "warnings": .array(warnings.map { .string($0) })])
    }

    /// `out` resolved against `cwd` (else the terminal's cwd, else `/`): its parent's real path + its name; an existing
    /// directory is refused for anyone. A terminal's: no `..`, named `*.<format>`, and a file its own sandbox lets it
    /// write (`SandboxGrantStore.mayWrite`: under its cwd's real path or a write grant, never what the profile closes).
    func exportTarget(_ out: String, format: String, caller: TerminalRecord?, cwd: String?) throws(ProtocolError) -> URL {
        let base = URL(fileURLWithPath: cwd ?? caller?.cwd ?? "/", isDirectory: true)
        let url = URL(fileURLWithPath: out, relativeTo: base)
        let denied = ProtocolError(code: .unauthorized, message: "--out '\(out)' is not writable by you: use collie access request <path> --write, or write inside your project")
        if caller != nil, out.split(separator: "/").contains("..") { throw denied }
        let name = url.standardizedFileURL.lastPathComponent
        guard !name.isEmpty, name != "/", name != ".", name != "..",
              let parent = realpath(url.standardizedFileURL.deletingLastPathComponent().path, nil) else {
            throw ProtocolError(code: .invalidArgs, message: "--out '\(out)': its folder does not exist")
        }
        let dir = String(cString: parent); free(parent)
        let dst = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(name)
        if let me = caller {
            guard name.lowercased().hasSuffix(".\(format)") else { throw ProtocolError(code: .invalidArgs, message: "out must end in .\(format)") }
            guard let r = realpath(me.cwd, nil) else { throw denied }
            let root = String(cString: r); free(r)
            // the same inputs `prepareSandbox` builds this terminal's profile from
            let project = sandboxProject(me)
            let grants = SandboxGrantStore.applicable(sandboxGrants, terminal: me.id, project: project.path, lot: ws.lot(of: me.id)?.id)
            guard SandboxGrantStore.mayWrite(dst.path, root: root, grants: grants, home: sandboxHomeDir, collie: config.paths.root,
                                             app: SandboxInput.appBundle(of: config.collieExecutable), closed: closedPaddocks(project)) else { throw denied }
        }
        var st = stat()
        if lstat(dst.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR { throw ProtocolError(code: .invalidArgs, message: "--out '\(out)' is a folder: name the file") }
        return dst
    }

    /// The app's files in the `.export` dir `dfd` (snapshot, payloads, its PDF) unlinked, links themselves (never followed);
    /// the decks written there stay.
    private static func dropAppFiles(_ dfd: Int32) {
        let fd = dup(dfd)
        guard fd >= 0, let d = fdopendir(fd) else { if fd >= 0 { close(fd) }; return }
        defer { closedir(d) }
        var names: [String] = []
        while let e = readdir(d) {
            let n = withUnsafeBytes(of: e.pointee.d_name) { String(decoding: $0.prefix(Int(e.pointee.d_namlen)), as: UTF8.self) }
            if n == "slides.json" || n == "deck-app.pdf" || n.wholeMatch(of: /(img|svg)-\d+\.(png|svg)/) != nil { names.append(n) }
        }
        for n in names { unlinkat(dfd, n, 0) }
    }

    /// `body` on `dir` opened as a directory, never through a link.
    private static func inDir<T>(_ dir: URL, _ body: (Int32) throws -> T) throws -> T {
        let dfd = open(dir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dfd >= 0 else { throw ProtocolError(code: .internal, message: "cannot open \(dir.lastPathComponent)") }
        defer { close(dfd) }
        return try body(dfd)
    }

    /// `name` in `dfd`: a regular file up to `cap`, never through a link (as readImport).
    private static func read(_ dfd: Int32, _ name: String, cap: Int) -> Data? {
        let fd = openat(dfd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= cap,
              let d = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: cap + 1) ?? Data(),
              d.count <= cap else { return nil }
        return d
    }

    /// `data` as `name` in `dfd`: a new temp file renamed over it (a link there is replaced, never written through).
    private static func put(_ dfd: Int32, _ name: String, _ data: Data) throws {
        let tmp = ".\(name).\(UUID().uuidString.prefix(8)).tmp"
        let fd = openat(dfd, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw ProtocolError(code: .internal, message: "cannot write \(name): \(String(cString: strerror(errno)))") }
        let ok = data.withUnsafeBytes { b in
            var off = 0
            while off < b.count {
                let n = write(fd, b.baseAddress! + off, b.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        close(fd)
        guard ok, renameat(dfd, tmp, dfd, name) == 0 else {
            unlinkat(dfd, tmp, 0)
            throw ProtocolError(code: .internal, message: "cannot write \(name)")
        }
    }

    /// The deck snapshot the app left in `dir` and the payloads its nodes name (caps as readImport's), read off the
    /// pool, never through a link; then the snapshot's files deleted (the decks written there stay).
    private static func readDeck(_ dir: URL) async throws -> (DeckSnapshot, [String: Data]) {
        try await UnixSocketClient.offPool { () throws -> (DeckSnapshot, [String: Data]) in
            try inDir(dir) { dfd in
                defer { dropAppFiles(dfd) }
                guard let raw = read(dfd, "slides.json", cap: 32 << 20), let s = try? JSONDecoder().decode(DeckSnapshot.self, from: raw) else {
                    throw ProtocolError(code: .internal, message: "bad deck snapshot")
                }
                var payloads: [String: Data] = [:]
                func walk(_ n: DOMNode) {
                    for f in [n.image?.file, n.svg?.file].compactMap({ $0 })
                    where payloads[f] == nil && f.wholeMatch(of: /(img|svg)-\d+\.(png|svg)/) != nil {
                        payloads[f] = read(dfd, f, cap: f.hasSuffix(".png") ? 4 << 20 : 256 << 10)
                    }
                    n.children.forEach(walk)
                }
                s.slides.forEach { walk($0.root) }
                return (s, payloads)
            }
        }
    }
}
