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
    /// dir (`.git`, `*.git`). The Collie app bundle and its folders (I3). For writes, also what the profile closes after
    /// every grant (R32: config run outside (`~/.config/gh` too), preferences, `~/Applications`; R34: global agent config is grantable) and `closed`: a pasture's
    /// paddock worktrees (M3). A refused card shows only Negar.
    /// Why `path` (resolved) is never read, nil: it is readable (2Q: reads are open but for `readClosed` and Collie's data).
    static func readRefusal(_ path: String, home: URL, collie: URL) -> String? {
        let p = URL(fileURLWithPath: path).pathComponents.map { $0.lowercased() }
        guard p.starts(with: URL(fileURLWithPath: SignedAppCheck.realPath(collie)).pathComponents.map { $0.lowercased() })
                || EssentialPaths.readClosed.contains(where: { closes(p, $0, home: home) }) else { return nil }
        return refusal(path, op: "read", home: home, collie: collie) ?? "Nunca lido no sandbox."
    }

    /// `p` (components) lies in the home-relative entry `e`; a `x*` entry: any name starting with x at that depth (and below).
    /// B (round 3): without case, as the macOS volume compares (`~/.config/FISH` is `~/.config/fish`).
    static func closes(_ p: [String], _ e: String, home: URL) -> Bool {
        let p = p.map { $0.lowercased() }
        func comps(_ u: URL) -> [String] { URL(fileURLWithPath: SignedAppCheck.realPath(u)).pathComponents.map { $0.lowercased() } }
        guard e.hasSuffix("*") else { return p.starts(with: comps(home.appendingPathComponent(e))) }
        let c = comps(home.appendingPathComponent(String(e.dropLast()))), n = c.count
        return p.count >= n && p.prefix(n - 1).elementsEqual(c.prefix(n - 1)) && p[n - 1].hasPrefix(c[n - 1])
    }

    /// Whether a terminal may have the daemon write the file `path` (resolved) for it, by the profile's write rules: inside
    /// `root` (its resolved cwd) or under one of its write `grants`; never what the profile closes after both (`refusal`'s
    /// write rules: Collie's data, secrets, the app, any git dir (R17, R27), `neverWritable`, a pasture's paddocks); the
    /// global agent config (R34) only under a write grant.
    /// ponytail: stricter than the profile where it re-opens (agents' state, `.build/` checkouts): no deck goes there.
    /// The denials compare without case (B, round 3); the caller passes `path` resolved (`SignedAppCheck.realPath`).
    static func mayWrite(_ path: String, root: String, grants: [SandboxGrant], home: URL, collie: URL, app: URL?, closed: [URL]) -> Bool {
        let p = URL(fileURLWithPath: path).pathComponents
        func under(_ r: String) -> Bool { p.starts(with: URL(fileURLWithPath: r).pathComponents) }
        let granted = grants.contains { $0.access == .write && under($0.path) }
        guard under(root) || granted, refusal(path, op: "write", home: home, collie: collie, app: app, closed: closed) == nil else { return false }
        return granted || !EssentialPaths.agentConfig.contains { closes(p, $0, home: home) }
    }

    static func refusal(_ path: String, op: String, home: URL, collie: URL, app: URL? = nil, closed: [URL] = []) -> String? {
        if op == "exec" { return tr("Executar este programa não pode ser liberado no sandbox.", "Running this program cannot be allowed in the sandbox.") }
        // B (round 3): every refusal compares without case, as the macOS volume does
        let p = URL(fileURLWithPath: path).pathComponents.map { $0.lowercased() }
        func comps(_ u: URL) -> [String] { URL(fileURLWithPath: SignedAppCheck.realPath(u)).pathComponents.map { $0.lowercased() } }
        if comps(home).starts(with: p) || EssentialPaths.tooWide.contains(where: { comps(home.appendingPathComponent($0)) == p }) {
            return tr("Amplo demais: o Collie não libera a pasta pessoal, ~/Library ou ~/Library/Application Support inteiras, nem o que fica acima delas.", "Too broad: Collie does not allow the whole home folder, ~/Library or ~/Library/Application Support, nor anything above them.")
        }
        func within(_ u: URL) -> Bool { p.starts(with: comps(u)) }
        func closes(_ e: String) -> Bool { Self.closes(p, e, home: home) }
        if within(collie) { return tr("Dados do Collie (e o token de admin) nunca são liberados para um agente.", "Collie data (and the admin token) is never allowed for an agent.") }
        if (EssentialPaths.secrets + EssentialPaths.neverGranted).contains(where: closes) {
            return tr("Segredos (chaves SSH, credenciais, chaves do sistema, e-mail, mensagens, perfis de navegador) e agentes do launchd nunca são liberados.", "Secrets (SSH keys, credentials, system keys, email, messages, browser profiles) and launchd agents are never allowed.")
        }
        if let app, within(app) || comps(app).starts(with: p) {
            return tr("O app do Collie (e as pastas que o contêm) nunca é liberado: o launchd roda o daemon de lá, fora do sandbox.", "The Collie app (and the folders containing it) is never allowed: launchd runs the daemon from there, outside the sandbox.")
        }
        if p.contains(where: { $0.hasSuffix(".git") }) {
            return tr("Pastas do git (.git) nunca são liberadas: o seu git executa hooks e configuração de lá fora do sandbox.", "Git folders (.git) are never allowed: your git runs hooks and configuration from there, outside the sandbox.")
        }
        guard op != "read" else { return nil }
        if EssentialPaths.neverWritable.contains(where: closes) {
            return tr("Configuração que roda fora do sandbox (rc do shell, git, gh, npm, preferências, ~/Applications) nunca é liberada para escrita.", "Configuration that runs outside the sandbox (shell rc, git, gh, npm, preferences, ~/Applications) is never allowed for writing.")
        }
        if closed.contains(where: within) {
            return tr("Os cercados deste pasto nunca são graváveis daqui: abra um terminal no cercado.", "This pasture's paddocks are never writable from here: open a terminal in the paddock.")
        }
        return nil
    }
}
