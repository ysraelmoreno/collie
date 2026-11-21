import Foundation
import CollieCore
import CollieProtocol

/// M13.1: `collie-work.json` at a project's root, read under the file rules of onda13.md. Reading never runs anything.
enum WorkConfigFile: Equatable {
    case absent, refused(String), loaded(Data)

    /// `<root>/collie-work.json`: a root path without `..`, a regular file (never through a symlink), at most 16 KB.
    static func read(root: URL) -> WorkConfigFile {
        guard !root.pathComponents.contains("..") else { return .refused("o caminho do projeto contém '..'") }
        let path = root.appendingPathComponent(ProjectWorkConfig.fileName).path
        var st = stat()
        guard lstat(path, &st) == 0 else { return errno == ENOENT ? .absent : .refused("collie-work.json não pôde ser lido") }
        if st.st_mode & S_IFMT == S_IFLNK { return .refused("collie-work.json é um link simbólico; só um arquivo regular é lido") }
        guard st.st_mode & S_IFMT == S_IFREG else { return .refused("collie-work.json não é um arquivo regular") }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)   // swapped for a link after the lstat: ELOOP
        guard fd >= 0 else { return .refused("collie-work.json não pôde ser aberto sem seguir link simbólico") }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return .refused("collie-work.json não é um arquivo regular") }
        guard st.st_size <= ProjectWorkConfig.maxBytes else { return .refused(ProjectWorkConfig.ConfigError.tooLarge(Int(st.st_size)).message) }
        let data = (try? h.read(upToCount: ProjectWorkConfig.maxBytes + 1)) ?? Data()
        guard data.count <= ProjectWorkConfig.maxBytes else { return .refused(ProjectWorkConfig.ConfigError.tooLarge(data.count).message) }
        return .loaded(data)
    }
}

extension CommandRouter {
    static let noWorkConfig = "nenhum collie-work.json neste projeto"

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
        var lines = ["\(ProjectWorkConfig.fileName): \(v(path)) (árvore de trabalho)"]
        lines += warnings.map { "aviso: \(v($0))" }
        let fields: [(String, String?)] = [("gate", c.gate), ("precheck", c.precheck), ("smoke", c.smoke), ("full", c.full)]
        for (k, s) in fields { lines.append("\(k): " + (s.map(v) ?? "(não definido)")) }
        var areas: [String: JSONValue] = [:]
        if c.areas.isEmpty { lines.append("áreas: (nenhuma)") } else {
            lines.append("áreas (o check que cada uma vira sozinha):")
            for name in c.areas.keys.sorted() {
                guard case .success(let check) = c.composeCheck(areas: [name]) else { continue }
                areas[name] = .string(check)
                lines.append("  \(name): \(v(check))")
            }
        }
        lines.append("Só leitura: nenhum comando do arquivo foi executado.")
        var o: [String: JSONValue] = ["output": .string(lines.joined(separator: "\n")), "exists": .bool(true),
                                      "source": .string("worktree"), "path": .string(v(path)),
                                      "warnings": .array(warnings.map { .string(v($0)) }), "areas": .object(areas)]
        for (k, s) in fields { if let s { o[k] = .string(v(s)) } }
        return .object(o)
    }
}
