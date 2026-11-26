import Foundation
import CollieCore
import CollieProtocol

/// M13.1: `collie-work.json` at a project's root, read under the file rules of onda13.md. Reading never runs anything.
enum WorkConfigFile: Equatable {
    case absent, refused(String), loaded(Data)

    /// `<root>/collie-work.json`: a root path without `..`, a regular file (never through a symlink), at most 16 KB.
    static func read(root: URL) -> WorkConfigFile {
        guard !root.pathComponents.contains("..") else { return .refused(tr("o caminho do projeto contém '..'", "the project path contains '..'")) }
        return regular(root.appendingPathComponent(ProjectWorkConfig.fileName).path, name: ProjectWorkConfig.fileName,
                       max: ProjectWorkConfig.maxBytes) { ProjectWorkConfig.ConfigError.tooLarge($0).message }
    }

    /// U3: the same rules for any file: a regular file (never through a symlink), at most `max` bytes. `tooLarge` nil:
    /// a bigger file is cut at `max` instead of refused.
    static func regular(_ path: String, name: String, max: Int, tooLarge: ((Int) -> String)?) -> WorkConfigFile {
        var st = stat()
        guard lstat(path, &st) == 0 else { return errno == ENOENT ? .absent : .refused(tr("\(name) não pôde ser lido", "\(name) could not be read")) }
        if st.st_mode & S_IFMT == S_IFLNK { return .refused(tr("\(name) é um link simbólico; só um arquivo regular é lido", "\(name) is a symbolic link; only a regular file is read")) }
        guard st.st_mode & S_IFMT == S_IFREG else { return .refused(tr("\(name) não é um arquivo regular", "\(name) is not a regular file")) }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)   // swapped for a link after the lstat: ELOOP
        guard fd >= 0 else { return .refused(tr("\(name) não pôde ser aberto sem seguir link simbólico", "\(name) could not be opened without following a symbolic link")) }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return .refused(tr("\(name) não é um arquivo regular", "\(name) is not a regular file")) }
        if let tooLarge, st.st_size > max { return .refused(tooLarge(Int(st.st_size))) }
        let data = (try? h.read(upToCount: max + 1)) ?? Data()
        guard data.count <= max else { return tooLarge.map { .refused($0(data.count)) } ?? .loaded(data.prefix(max)) }
        return .loaded(data)
    }

    /// M13.3: the file as committed in `base` (a sha), never the working tree's: a regular blob (never a link or a
    /// submodule) of at most 16 KB at the repository's root. Not in `base`: `.absent`.
    static func read(base: String, dir: URL) async -> WorkConfigFile {
        guard base.count == 40 || base.count == 64, base.allSatisfy(\.isHexDigit) else { return .refused(tr("a base do laço não é um commit", "the loop's base is not a commit")) }
        let name = ProjectWorkConfig.fileName
        guard let ls = try? await GitRunner.run(["--literal-pathspecs", "ls-tree", "-z", "-l", base, "--", name], in: dir, timeout: .seconds(30)),
              ls.status == 0 else { return .refused(tr("\(name) não pôde ser lido do commit \(base.prefix(7))", "\(name) could not be read from commit \(base.prefix(7))")) }
        // "<mode> <type> <oid> <size>\t<name>\0"
        guard let entry = ls.stdout.split(separator: "\0").first, let tab = entry.firstIndex(of: "\t") else { return .absent }
        let meta = entry[..<tab].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard String(entry[entry.index(after: tab)...]) == name, meta.count == 4 else { return .absent }
        guard meta[1] == "blob", meta[0] == "100644" || meta[0] == "100755" else { return .refused(tr("\(name) no commit \(base.prefix(7)) não é um arquivo regular", "\(name) at commit \(base.prefix(7)) is not a regular file")) }
        guard let size = Int(meta[3]), size <= ProjectWorkConfig.maxBytes else {
            return .refused(ProjectWorkConfig.ConfigError.tooLarge(Int(meta[3]) ?? ProjectWorkConfig.maxBytes + 1).message)
        }
        guard let blob = try? await GitRunner.run(["cat-file", "blob", meta[2]], in: dir, timeout: .seconds(30)), blob.status == 0,
              blob.stdoutData.count <= ProjectWorkConfig.maxBytes else { return .refused(tr("\(name) não pôde ser lido do commit \(base.prefix(7))", "\(name) could not be read from commit \(base.prefix(7))")) }
        return .loaded(blob.stdoutData)
    }

    /// M13.3: `config(root:)`'s result for the file committed in `base`.
    static func config(base: String, dir: URL) async -> Result<ProjectWorkConfig?, ProtocolError> {
        parsed(await read(base: base, dir: dir))
    }

    /// M13.2: the file read and parsed. `.success(nil)`: no file; `.failure`: one line, cleaned, saying why it is not used.
    static func config(root: URL) -> Result<ProjectWorkConfig?, ProtocolError> { parsed(read(root: root)) }

    private static func parsed(_ file: WorkConfigFile) -> Result<ProjectWorkConfig?, ProtocolError> {
        func bad(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: RerailText.clean(m, max: 300)) }
        switch file {
        case .absent: return .success(nil)
        case .refused(let m): return .failure(bad(m))
        case .loaded(let d):
            switch ProjectWorkConfig.parse(d) {
            case .success(let ok): return .success(ok.config)
            case .failure(let e): return .failure(bad(e.message))
            }
        }
    }
}

extension CommandRouter {
    static var noWorkConfig: String { tr("nenhum collie-work.json neste projeto", "no collie-work.json in this project") }

    /// `work.config`: the terminal's project's `collie-work.json` (its paddock's worktree root), its warnings and the
    /// check each area becomes. Read only: none of its commands is run. Values are the repository's data, cleaned.
    func workConfig(_ t: TerminalRecord) throws(ProtocolError) -> JSONValue {
        let root = ProjectRoot.resolve(cwd: t.cwd, paddock: ws.paddocks.first { $0.id == t.paddockId })
        let data: Data
        switch WorkConfigFile.read(root: root) {
        case .absent: return .object(["output": .string(Self.noWorkConfig), "exists": .bool(false)])
        case .refused(let m): throw ProtocolError(code: .invalidArgs, message: m)
        case .loaded(let d): data = d
        }
        let c: ProjectWorkConfig, warnings: [String]
        switch ProjectWorkConfig.parse(data) {
        case .failure(let e): throw ProtocolError(code: .invalidArgs, message: RerailText.clean(e.message, max: 300))
        case .success(let ok): (c, warnings) = (ok.config, ok.warnings)
        }
        let path = root.appendingPathComponent(ProjectWorkConfig.fileName).path
        func v(_ s: String) -> String { RerailText.clean(s, max: 2 * ProjectWorkConfig.maxCommand + 10) }
        var lines = ["\(ProjectWorkConfig.fileName): \(v(path)) \(tr("(árvore de trabalho)", "(working tree)"))"]
        lines.append(tr("o laço lê a versão commitada em HEAD, não a da árvore: o que não estiver commitado não vale (git status mostra se diferem)", "the loop reads the version committed at HEAD, not the tree's: what is not committed does not count (git status shows whether they differ)"))
        lines += warnings.map { tr("aviso: ", "warning: ") + v($0) }
        let fields: [(String, String?)] = [("gate", c.gate), ("precheck", c.precheck), ("smoke", c.smoke), ("full", c.full)]
        for (k, s) in fields { lines.append("\(k): " + (s.map(v) ?? tr("(não definido)", "(not set)"))) }
        var areas: [String: JSONValue] = [:]
        if c.areas.isEmpty { lines.append(tr("áreas: (nenhuma)", "areas: (none)")) } else {
            lines.append(tr("áreas (o check que cada uma vira sozinha):", "areas (the check each one becomes on its own):"))
            for name in c.areas.keys.sorted() {
                guard case .success(let check) = c.composeCheck(areas: [name]) else { continue }
                areas[name] = .string(check)
                lines.append("  \(name): \(v(check))")
            }
        }
        lines.append(tr("Só leitura: nenhum comando do arquivo foi executado.", "Read only: no command from the file was run."))
        var o: [String: JSONValue] = ["output": .string(lines.joined(separator: "\n")), "exists": .bool(true),
                                      "source": .string("worktree"), "path": .string(v(path)),
                                      "warnings": .array(warnings.map { .string(v($0)) }), "areas": .object(areas)]
        for (k, s) in fields { if let s { o[k] = .string(v(s)) } }
        return .object(o)
    }
}
