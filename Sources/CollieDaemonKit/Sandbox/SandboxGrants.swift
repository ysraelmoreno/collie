import Foundation
import CollieCore

/// The user's grants, `<root>/sandbox/grants.json` (0600, inside the Collie dir every profile closes). Read
/// defensively: a missing or corrupt file is no grants, an entry that doesn't decode is skipped (never a wider one).
struct SandboxGrantStore {
    let file: URL
    init(root: URL) { file = root.appendingPathComponent("sandbox/grants.json") }

    private struct Lenient: Decodable {
        let grant: SandboxGrant?
        init(from d: Decoder) throws { grant = try? SandboxGrant(from: d) }
    }

    func load() -> [SandboxGrant] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return ((try? d.decode([Lenient].self, from: data)) ?? []).compactMap(\.grant)
    }

    func save(_ grants: [SandboxGrant]) throws {
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        let tmp = dir.appendingPathComponent(".grants-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: tmp.path, contents: try e.encode(grants), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path])
        }
        guard rename(tmp.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
    }

    /// The grants a terminal's profile gets: its own, and its lot's (current and future members). A summoned or herd
    /// terminal has a new id: nothing of its creator's own grants.
    /// A terminal grant also needs the terminal's project to be the one it was clicked for (R29).
    static func applicable(_ all: [SandboxGrant], terminal: UUID, project: String?, lot: UUID?) -> [SandboxGrant] {
        all.filter { ($0.scope == .terminal && $0.owner == terminal && ($0.project == nil || $0.project == project))
            || ($0.scope == .lot && $0.owner == lot) }
    }

    /// Why `path` (resolved) can never be granted, in the app's words; nil: it can. Too wide (`/`, the home, above it,
    /// `~/Library`, `~/Library/Application Support`), or closed whatever the user clicks (R23, R27): Collie's data and
    /// admin token, secrets, mail/messages/containers/keychains, launchd agents, and anything that is or is inside a git
    /// dir (`.git`, `*.git`). Global agent config is grantable (spec).
    static func refusal(_ path: String, op: String, home: URL, collie: URL) -> String? {
        if op == "exec" { return "Executar este programa não pode ser liberado no sandbox." }
        let p = URL(fileURLWithPath: path).pathComponents
        func comps(_ u: URL) -> [String] { URL(fileURLWithPath: SignedAppCheck.realPath(u)).pathComponents }
        if comps(home).starts(with: p) || EssentialPaths.tooWide.contains(where: { comps(home.appendingPathComponent($0)) == p }) {
            return "Amplo demais: o Collie não libera a pasta pessoal, ~/Library ou ~/Library/Application Support inteiras, nem o que fica acima delas."
        }
        func within(_ u: URL) -> Bool { p.starts(with: comps(u)) }
        if within(collie) { return "Dados do Collie (e o token de admin) nunca são liberados para um agente." }
        if (EssentialPaths.secrets + EssentialPaths.neverGranted).contains(where: { within(home.appendingPathComponent($0)) }) {
            return "Segredos (chaves SSH, credenciais, chaves do sistema, e-mail, mensagens, perfis de navegador) e agentes do launchd nunca são liberados."
        }
        if p.contains(where: { $0.hasSuffix(".git") }) {
            return "Pastas do git (.git) nunca são liberadas: o seu git executa hooks e configuração de lá fora do sandbox."
        }
        return nil
    }
}
