import Foundation
import CollieCore
import CollieDevice
import CryptoKit
import CollieProtocol

/// Everything the HTML exporter needs from the engine, plus the stamp of the design state it was read from.
/// `page`: the page whose top-level layers were read (nil: a node's export).
struct ExportSnapshot: Sendable {
    var code: [String]; var layers: [JSONValue]; var variables: JSONValue; var assets: [ExportAsset]; var thumbnail: Data?; var stamp: String
    var page: String?
}

/// Design files on the local figcraft server and the `design.*` commands run on them.
/// The registry `<root>/design/files.json` (0600) maps each file's name to its edit link, which never leaves the daemon
/// except through `design.link` (the app). Each caller (a terminal, or "app") edits a file through a `figcraft-cli mcp`
/// client of its own, joined to the file's live session, so each has its own undo. Clients start on first use, close
/// after `idle` without use, with their panel's file or their terminal; at most `maxClients` live (an idle one of the
/// daemon's own, else the one idle the longest, makes room; all busy: `.unavailable` "design engine busy"). A client found dead, or made under a server that
/// has since restarted, is made again within the call; one whose call timed out is closed (the engine may still be at it).
/// A stored link names the port its server had: it is aimed at the current one wherever it is used.
/// Results and errors are scrubbed of links, tokens and the server key.
actor DesignService {
    static let maxClients = 8
    /// Largest `--params`, `--commands` or batch file.
    static let inputCap = 4 << 20
    static let busy = ProtocolError(code: .unavailable, message: "design engine busy")

    /// `viewLink`: kept for design systems (other files add their library by it); as secret as the edit link.
    /// `paddockId`: the paddock it was made on (nil, or a paddock since deleted: pasture), which picks its active design system.
    struct File: Codable, Sendable {
        var id: String; var name: String; var editLink: String; var viewLink: String?; var createdAt: Date; var paddockId: UUID?
    }
    /// The daemon's own client of a file (design systems: library publishing and snapshots, which agents never reach).
    static let systemCaller = "collie-ds"
    private struct Key: Hashable { var caller: String; var file: String }
    /// One caller's client of one file; `busy` while a call holds it, later callers queue in `waiters` (FIFO, each with
    /// its own deadline, so time spent queued counts against the command's timeout).
    private final class Slot {
        var client: MCPStdioClient?
        var generation = 0
        var busy = false
        var waiters: [(id: Int, go: CheckedContinuation<ProtocolError?, Never>)] = []
        var lastUsed = ContinuousClock.now
        var idleTimer: Task<Void, Never>?
    }

    private let server: FigcraftServer
    private let cli: URL
    private let root: URL, runDir: URL
    private let idle: Duration
    private let timeoutCap: Duration?
    private var files: [File]?   // loaded on first use
    private var naming: Set<String> = []   // lowercased names being published
    private var slots: [Key: Slot] = [:]
    private var waiterSeq = 0
    /// Panels closed so far: a command that was awaiting the engine when its panel closed writes nothing afterwards.
    /// ponytail: grows by one UUID per closed design panel for the daemon's life; fine at this scale.
    private var closed: Set<UUID> = []
    /// `list_commands`, parsed once: the registry is fixed per figcraft build.
    private var commandList: [JSONValue]?
    /// Server keys and edit links seen: scrubbed from anything a caller gets back.
    private var secrets: Set<String> = []

    init(server: FigcraftServer, figcraftDir: URL?, root: URL, runDir: URL, idle: Duration, timeoutCap: Duration? = nil) {
        self.server = server
        // no figcraftDir: the server reports `notBundled` before the CLI is ever needed
        self.cli = (figcraftDir ?? URL(fileURLWithPath: "/nonexistent")).appendingPathComponent("bin/figcraft-cli")
        self.root = root; self.runDir = runDir; self.idle = idle; self.timeoutCap = timeoutCap
    }

    /// Every `figcraft-cli`'s environment: the daemon's, plus `FIGCRAFT_EXTRA_FONTS_DIR=<root>/fonts` (patch 0005): its
    /// font scan walks the families' folders and reads the `ttf/` files `font.add` keeps for it (the woff2 are skipped).
    private var cliEnv: [String: String] {
        ProcessInfo.processInfo.environment.merging(["FIGCRAFT_EXTRA_FONTS_DIR": root.appendingPathComponent("fonts").path]) { _, new in new }
    }
    private var designDir: URL { root.appendingPathComponent("design") }
    private var registryFile: URL { designDir.appendingPathComponent("files.json") }
    private var screens: URL { root.appendingPathComponent("screens") }
    private func exportsDir(_ file: File) -> URL { designDir.appendingPathComponent("exports/\(file.id)") }
    /// An empty folder: clients that never write anything get it as their only (read) root.
    private var sandbox: URL { designDir.appendingPathComponent("sandbox") }

    /// Live clients (tests).
    var liveClients: Int { slots.values.filter { $0.client != nil }.count }

    // MARK: files

    func list() throws -> [File] { try registry() }

    /// `name`'s file id; a name not registered yet is created first, on `paddock` (`panel.open design --file`): then
    /// `created`. A create of that name already in flight is waited for, then its file used.
    func fileId(named name: String, paddock: UUID? = nil, deadline: ContinuousClock.Instant? = nil) async throws -> (id: String, created: Bool) {
        while naming.contains(name.lowercased()) { try await Task.sleep(for: .milliseconds(100)) }   // ends with its deadline
        if let f = try registry().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return (f.id, false) }
        return (try await create(name, paddock: paddock, deadline: deadline).id, true)
    }

    /// A new empty file on the server: a short-lived "collie-bridge" client publishes it and hands back its links.
    /// `copying` (a file id): instead, the daemon's own client of that file saves its live document, which a bridge
    /// opens, renames to `name` (its library takes the document's name) and publishes to the server's address and key:
    /// kept there as a new file, its library at version 1. `deadline`: the calling command's (default: `design.new`'s).
    func create(_ name: String, paddock: UUID? = nil, deadline: ContinuousClock.Instant? = nil, copying: String? = nil) async throws -> File {
        try await guarded {
            try Self.validate(name)
            let lower = name.lowercased()
            if try registry().contains(where: { $0.name.lowercased() == lower }) || naming.contains(lower) {
                throw ProtocolError(code: .invalidArgs, message: "a design file named '\(name)' already exists")
            }
            naming.insert(lower); defer { naming.remove(lower) }
            let deadline = deadline ?? self.deadline("design.new")
            let (ep, _) = try await running()
            let pub: [String: JSONValue]
            if let copying {
                let src = try file(copying)
                // under the system client's write root; the bridge reads only this folder
                let tmp = try dir(designDir.appendingPathComponent("systems/.copy-\(UUID().uuidString.lowercased())"))
                defer { try? FileManager.default.removeItem(at: tmp) }
                let doc = tmp.appendingPathComponent("doc.figcraft")
                _ = try await use(Key(caller: Self.systemCaller, file: src.id), src, Self.systemCaller, deadline) { c throws(ProtocolError) in
                    try await Self.settle(c, deadline)
                    return try await c.command("file.save", ["path": .string(doc.path)], timeout: try Self.left(deadline))
                }
                let bridge = try await MCPStdioClient(executable: cli, args: ["mcp", "--automation-read-root", tmp.path],
                                                      env: cliEnv, runDir: runDir, name: "collie-bridge")
                defer { bridge.close() }
                _ = try await bridge.command("file.open", ["path": .string(doc.path)], timeout: try Self.left(deadline))
                _ = try await bridge.command("file.rename", ["name": .string(name)], timeout: try Self.left(deadline))
                let r = try await bridge.command("library.publishToServer", ["server": .string(ep.wsURL)], timeout: try Self.left(deadline))
                guard case .object(let o) = r else { throw ProtocolError(code: .internal, message: "design engine: no copy of '\(src.name)'") }
                pub = o
            } else {
                let bridge = try await MCPStdioClient(executable: cli, args: ["mcp", "--automation-read-root", try dir(sandbox).path],
                                                      env: cliEnv, runDir: runDir, name: "collie-bridge")
                defer { bridge.close() }
                _ = try await bridge.command("collab.publish", ["server": .string(ep.wsURL), "name": .string(name)], timeout: try Self.left(deadline))
                let peers = try await live(bridge, name, deadline) { o in
                    if case .object(let p)? = o["published"], case .string(let l)? = p["edit"], !l.isEmpty { return true }
                    return false
                }
                guard case .object(let p)? = peers["published"] else { throw ProtocolError(code: .internal, message: "design engine: no edit link for '\(name)'") }
                pub = p
            }
            guard case .string(let link)? = pub["edit"], !link.isEmpty else {
                throw ProtocolError(code: .internal, message: "design engine: no edit link for '\(name)'")
            }
            let view = if case .string(let v)? = pub["view"], !v.isEmpty { v } else { String?.none }
            secrets.insert(link)
            if let view { secrets.insert(view) }
            let f = File(id: UUID().uuidString.lowercased(), name: name, editLink: link, viewLink: view, createdAt: Date(), paddockId: paddock)
            var all = try registry()
            all.append(f)
            try save(all)
            return f
        }
    }

    /// 1-80 characters of A-Z a-z 0-9 space . _ -, without "..".
    static func validate(_ name: String) throws(ProtocolError) {
        let ok = (1...80).contains(name.count) && !name.contains("..")
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || " ._-".unicodeScalars.contains($0)) }
        guard ok else {
            throw ProtocolError(code: .invalidArgs, message: "design file names are 1-80 of A-Z a-z 0-9 space . _ - (no '..')")
        }
    }

    private func registry() throws -> [File] {
        if let files { return files }
        guard let d = FileManager.default.contents(atPath: registryFile.path) else { files = []; return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        // a corrupt registry is not replaced by an empty one (its links would be lost): it is an error until repaired
        guard let all = try? dec.decode([File].self, from: d) else {
            throw ProtocolError(code: .internal, message: "design: \(registryFile.path) is unreadable")
        }
        files = all
        secrets.formUnion(all.map(\.editLink) + all.compactMap(\.viewLink))
        return all
    }

    private func save(_ all: [File]) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Self.writePrivate(try enc.encode(all), to: registryFile)
        files = all
    }

    /// Written whole to a 0600 temp file next to `to` (its folder made 0700 when missing), then renamed over it.
    static func writePrivate(_ d: Data, to: URL) throws(ProtocolError) {
        let folder = to.deletingLastPathComponent(), tmp = folder.appendingPathComponent(".\(to.lastPathComponent).tmp")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: tmp.path, contents: d, attributes: [.posixPermissions: 0o600]),
              chmod(tmp.path, 0o600) == 0, rename(tmp.path, to.path) == 0 else {
            throw ProtocolError(code: .internal, message: "design: cannot write \(to.path)")
        }
    }

    /// Links to keep out of anything a caller gets back (design systems' view links).
    func hide(_ links: [String]) { secrets.formUnion(links) }

    /// `v` with links, keys and every secret seen hidden (as `run` returns results).
    func scrubbed(_ v: JSONValue) -> JSONValue { Self.scrub(v, secrets) }
    func scrubbed(_ s: String) -> String { Self.scrub(s, secrets) }

    private func file(_ id: String) throws -> File {
        guard let f = try registry().first(where: { $0.id == id }) else {
            throw ProtocolError(code: .notFound, message: "the panel's design file is gone")
        }
        return f
    }

    func fileRecord(_ id: String) throws -> File { try file(id) }

    // MARK: snapshots

    /// The snapshot of `panel`'s file (or of `node`) on `caller`'s own client, as `design.export` reads it.
    func htmlSnapshot(panel: Panel, caller: (key: String, name: String), node: String?,
                      deadline: ContinuousClock.Instant) async throws -> (file: File, snapshot: ExportSnapshot) {
        let r = try await guarded { () async throws -> (File, ExportSnapshot) in
            guard case .string(let fid)? = panel.state["file"] else {
                throw ProtocolError(code: .invalidArgs, message: "'design.export' needs a design panel")
            }
            let f = try file(fid)
            let snap = try await use(Key(caller: caller.key, file: f.id), f, caller.name, deadline) { c throws(ProtocolError) in
                try await Self.snapshot(c, node: node, deadline: deadline)
            }
            return (f, snap)
        }
        try alive(panel)
        return (r.0, scrubbed(r.1))
    }

    /// The snapshot of file `fileId` (of `node`, else of `page`) on the daemon's own client (design systems: nobody's undo).
    func systemSnapshot(fileId: String, node: String?, page: String? = nil, deadline: ContinuousClock.Instant) async throws -> ExportSnapshot {
        scrubbed(try await onSystemClient(fileId, deadline: deadline) { c, d throws(ProtocolError) in
            try await Self.snapshot(c, node: node, page: page, deadline: d)
        })
    }

    /// Only the stamp of file `fileId` now (layers and variables, no code, assets or thumbnail). Never closes a
    /// caller's client to make room (`artifact.list` would cost a terminal its undo): pool full of those, `busy`.
    func currentStamp(fileId: String, node: String?, page: String? = nil, deadline: ContinuousClock.Instant) async throws -> String {
        try await onSystemClient(fileId, deadline: deadline, spare: true) { c, d throws(ProtocolError) in
            try await Self.sync(c, d)
            let (ids, _) = try await Self.roots(c, node, page, d)
            var layers: [JSONValue] = []
            for id in ids { layers.append(try await Self.tree(c, id, d)) }
            return Self.stamp(layers: layers, variables: try await c.command("variable.list", [:], timeout: try Self.left(d)))
        }
    }

    /// File `id`'s variables (`variable.list`) on the daemon's own client.
    func variables(ofFile id: String, deadline: ContinuousClock.Instant) async throws -> JSONValue {
        scrubbed(try await onSystemClient(id, deadline: deadline) { c, d throws(ProtocolError) in
            try await Self.sync(c, d)
            return try await c.command("variable.list", [:], timeout: try Self.left(d))
        })
    }

    private func scrubbed(_ s: ExportSnapshot) -> ExportSnapshot {
        var s = s
        s.code = s.code.map { Self.scrub($0, secrets) }
        s.layers = s.layers.map(scrubbed)
        s.variables = scrubbed(s.variables)
        s.assets = s.assets.map { a in
            var a = a; a.name = Self.scrub(a.name, secrets)
            if a.kind == "icon" { a.data = Data(Self.scrub(String(decoding: a.data, as: UTF8.self), secrets).utf8) }   // SVG text
            return a
        }
        return s
    }

    /// Reads `node` (default: the top-level layers of `page`, else of `c`'s current page) off `c`. Not scrubbed: the
    /// instance methods do.
    static func snapshot(_ c: MCPStdioClient, node: String?, page: String? = nil,
                         deadline: ContinuousClock.Instant) async throws(ProtocolError) -> ExportSnapshot {
        try await sync(c, deadline)
        let (ids, pageId) = try await roots(c, node, page, deadline)
        var code: [String] = [], layers: [JSONValue] = []
        for id in ids {
            layers.append(try await tree(c, id, deadline))
            let r = try await c.command("inspect.code", ["id": id, "language": .string("html")], timeout: try left(deadline))
            guard case .object(let o) = r, case .string(let s)? = o["code"] else {
                throw ProtocolError(code: .internal, message: "design engine: no code in the inspect.code answer")
            }
            code.append(s)
        }
        let variables = try await c.command("variable.list", [:], timeout: try left(deadline))
        var kinds: [String: (name: String, kind: String)] = [:]
        if case .object(let o) = try await c.command("inspect.assets", ["ids": .array(ids)], timeout: try left(deadline)),
           case .array(let rows)? = o["assets"] {
            for case .object(let a) in rows {
                if case .string(let k)? = a["kind"], k == "icon" || k == "image", let id = a["id"].flatMap(idString) {
                    kinds[id] = (a["name"].flatMap { if case .string(let n) = $0 { n } else { nil } } ?? id, k)
                }
            }
        }
        var assets: [ExportAsset] = []
        if !kinds.isEmpty,
           case .object(let o) = try await c.command("file.exportLayers", ["ids": .array(ids), "assets": .bool(true)], timeout: try left(deadline)),
           case .array(let files)? = o["files"] {
            for case .object(let f) in files {
                if let id = f["id"].flatMap(idString), let k = kinds[id], case .string(let b64)? = f["data"], let d = Data(base64Encoded: b64) {
                    assets.append(ExportAsset(id: id, name: k.name, kind: k.kind, data: d))
                }
            }
        }
        // the thumbnail is a nicety: any failure leaves it out
        var shot: Data?
        do throws(ProtocolError) { shot = try await c.call("screenshot", ["ids": .array([ids[0]])], timeout: try left(deadline)).images.first }
        catch where error.code == .timeout { throw error }
        catch {}
        return ExportSnapshot(code: code, layers: layers, variables: variables, assets: assets, thumbnail: shot,
                              stamp: stamp(layers: layers, variables: variables), page: pageId)
    }

    /// `node`, or the top-level layers of `page` (else of `c`'s current page: figcraft's is per client) and that
    /// page's id; empty page: `.invalidArgs`, `page` gone: `.notFound`.
    private static func roots(_ c: MCPStdioClient, _ node: String?, _ page: String?,
                              _ deadline: ContinuousClock.Instant) async throws(ProtocolError) -> ([JSONValue], String?) {
        if let node { return ([nodeId(node)], nil) }
        let top = topLayers(decoded(try await c.call("inspect_document", ["depth": .number(1)], timeout: try left(deadline))), page: page)
        if let page, top == nil { throw ProtocolError(code: .notFound, message: "no such page \(page)") }
        guard let top, !top.ids.isEmpty else { throw ProtocolError(code: .invalidArgs, message: "the page is empty: nothing to export") }
        return (top.ids, top.page)
    }

    private static func tree(_ c: MCPStdioClient, _ id: JSONValue, _ deadline: ContinuousClock.Instant) async throws(ProtocolError) -> JSONValue {
        decoded(try await c.call("get_node", ["id": id, "depth": .number(64)], timeout: try left(deadline)))
    }

    static func idString(_ v: JSONValue) -> String? {
        switch v {
        case .number(let d): Int64(exactly: d).map(String.init) ?? String(d)
        case .string(let s): s
        default: nil
        }
    }

    /// SHA-256 hex of the canonical JSON of the layers (without `absoluteBounds` anywhere, nor the roots' `x`/`y`: moving
    /// a frame on the canvas is not a design change) and the variables.
    static func stamp(layers: [JSONValue], variables: JSONValue) -> String {
        func strip(_ v: JSONValue, root: Bool) -> JSONValue {
            switch v {
            case .array(let a): return .array(a.map { strip($0, root: false) })
            case .object(var o):
                o["absoluteBounds"] = nil
                if root { o["x"] = nil; o["y"] = nil }
                return .object(o.mapValues { strip($0, root: false) })
            default: return v
            }
        }
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        let data = (try? enc.encode(JSONValue.array([.array(layers.map { strip($0, root: true) }), variables]))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: commands

    /// `design.help`: figcraft's commands (`list_commands`), `collab.*` left out, kept when `query` is in the id or docs.
    func help(_ query: String?) async throws -> JSONValue {
        try await guarded {
            if commandList == nil {
                let c = try await MCPStdioClient(executable: cli, args: ["mcp", "--automation-read-root", try dir(sandbox).path],
                                                 env: cliEnv, runDir: runDir, name: "collie-bridge")
                defer { c.close() }
                let text = try await c.call("list_commands", [:], timeout: try Self.left(deadline("design.help"))).texts.joined(separator: "\n")
                commandList = Self.parseCommands(text).filter { Self.permitted($0.id) }
                    .map { .object(["id": .string($0.id), "help": .string($0.help)]) }
            }
            let q = (query ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            return .array(q.isEmpty ? commandList ?? [] : (commandList ?? []).filter { row in
                guard case .object(let o) = row, case .string(let id)? = o["id"], case .string(let h)? = o["help"] else { return false }
                return id.lowercased().contains(q) || h.lowercased().contains(q)
            })
        }
    }

    /// `list_commands` text: a header line, then `id[*] — label [menu] (shortcut) params` per command (docs may wrap).
    static func parseCommands(_ text: String) -> [(id: String, help: String)] {
        var rows: [(id: String, help: String)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            if let r = line.firstRange(of: " — "), case let head = line[..<r.lowerBound], !head.isEmpty,
               head.allSatisfy({ $0.isLetter || $0.isNumber || "._-*".contains($0) }) {
                rows.append((String(head.hasSuffix("*") ? head.dropLast() : head), String(line[r.upperBound...])))
            } else if !rows.isEmpty, !line.isEmpty {
                rows[rows.count - 1].help += "\n" + line
            }
        }
        return rows
    }

    /// A panel-bound `design.*` command. `caller`: (key, display name) — a terminal's id and name, or "app".
    func run(_ command: String, panel: Panel, caller: (key: String, name: String), args: [String: JSONValue],
             cwd: String?) async throws -> JSONValue {
        let r = try await guarded { () async throws -> JSONValue in
            guard case .string(let fid)? = panel.state["file"] else {
                throw ProtocolError(code: .invalidArgs, message: "'\(command)' needs a design panel")
            }
            let f = try file(fid), deadline = self.deadline(command)
            func str(_ k: String) -> String? { if case .string(let s)? = args[k] { s } else { nil } }
            func use<T: Sendable>(_ body: (MCPStdioClient) async throws(ProtocolError) -> T) async throws -> T {
                try await self.use(Key(caller: caller.key, file: f.id), f, caller.name, deadline, body)
            }
            switch command {
            case "design.link":
                let (ep, _) = try await running()   // the link names this server: it must be up for the app to join
                return .object(["editLink": .string(rehosted(f.editLink, ep))])   // the one result not scrubbed
            case "design.run":
                let cmd = try Self.allowed(str("command") ?? "")
                let params = try str("params").map { try Self.json($0, "params") } ?? .object([:])
                guard case .object(let p) = params else { throw ProtocolError(code: .invalidArgs, message: "'params' must be a JSON object") }
                try Self.checkParams(cmd, p)
                if Self.noIds(cmd, p) { return Self.skipped }
                return try await use { c throws(ProtocolError) in
                    do throws(ProtocolError) { return try await c.command(cmd, p, timeout: try Self.left(deadline)) }
                    catch { throw Self.unsure(error) }
                }
            case "design.batch":
                let steps = try Self.steps(text: try await Self.batchText(commands: str("commands"), file: str("file"), cwd: cwd))
                // an agent's filter that found nothing: `[]`, or edits with `ids: []`, are skipped (never sent)
                let skip = Set(steps.indices.filter { Self.noIds(steps[$0].command, steps[$0].params) })
                guard skip.count < steps.count else { return .object(["results": .array(steps.map { _ in Self.skipped })]) }
                var a: [String: JSONValue] = ["commands": .array(try Self.withoutSkipped(steps.map(\.raw), skip: skip))]
                if let l = str("label") { a["label"] = .string(l) }
                let ids = steps.indices.map { skip.contains($0) ? "" : steps[$0].command }   // the caller's step numbers
                let r = try await use { c throws(ProtocolError) in
                    let r: MCPResult
                    do throws(ProtocolError) { r = try await c.result("batch", a, timeout: try Self.left(deadline)) }
                    catch { throw Self.unsure(error) }
                    if r.isError {   // the engine refused it
                        let text = r.texts.joined(separator: "\n")
                        throw Self.located(skip.isEmpty ? text : Self.callerSteps(text, sent: steps.indices.filter { !skip.contains($0) }), ids)
                    }
                    return Self.decoded(r)
                }
                guard !skip.isEmpty, case .array(var done) = r else { return r }
                for i in skip.sorted() where i <= done.count { done.insert(Self.skipped, at: i) }   // each in its own place
                return .array(done)
            case "design.inspect":
                let depth = try DeviceService.int(args, "depth", 1...64)
                return try await use { c throws(ProtocolError) in
                    try await Self.sync(c, deadline)
                    if let n = str("node") {
                        var a: [String: JSONValue] = ["id": Self.nodeId(n)]
                        if let depth { a["depth"] = .number(Double(depth)) }
                        return Self.decoded(try await c.call("get_node", a, timeout: try Self.left(deadline)))
                    }
                    return Self.decoded(try await c.call("inspect_document", depth.map { ["depth": .number(Double($0))] } ?? [:],
                                                         timeout: try Self.left(deadline)))
                }
            case "design.screenshot":
                let png = try await use { c throws(ProtocolError) in
                    try await Self.sync(c, deadline)
                    return try await c.call("screenshot", str("node").map { ["ids": .array([Self.nodeId($0)])] } ?? [:],
                                            timeout: try Self.left(deadline)).images.first
                }
                guard let png, let size = AdbParsing.pngSize(png) else {
                    throw ProtocolError(code: .internal, message: "design engine: the screenshot is not a PNG")
                }
                try alive(panel)
                let out = try dir(screens).appendingPathComponent("\(panel.id.uuidString)-\(Self.epochMs()).png")
                try await Self.write(png, out)
                return .object(["path": .string(out.path), "width": .number(Double(size.width)), "height": .number(Double(size.height))])
            case "design.export":
                let ext: String
                switch str("format") {   // html: the router's (an artifact)
                case "css": ext = "css"
                case "react": ext = "tsx"
                case "figcraft": ext = "figcraft"
                default: throw ProtocolError(code: .invalidArgs, message: "format must be html|css|react|figcraft")
                }
                let out = try dir(exportsDir(f)).appendingPathComponent("\(Self.epochMs()).\(ext)")
                if ext == "figcraft" {   // the client's only write root is this folder
                    _ = try await use { c throws(ProtocolError) in
                        // the file would carry its team libraries' links (design systems' view links) to the agent
                        try await Self.sync(c, deadline)
                        let libs = try await c.command("library.list", [:], timeout: try Self.left(deadline))
                        if case .object(let o) = libs, case .array(let rows)? = o["libraries"],
                           rows.contains(where: { if case .object(let l) = $0 { l["server"] == .bool(true) } else { false } }) {
                            throw ProtocolError(code: .invalidArgs, message: "this file uses team libraries (design systems): a figcraft export would carry their links; export html, css or react instead")
                        }
                        return try await c.command("file.save", ["path": .string(out.path)], timeout: try Self.left(deadline))
                    }
                    if closed.contains(panel.id) { try? FileManager.default.removeItem(at: out) }
                    try alive(panel)
                    guard FileManager.default.fileExists(atPath: out.path) else {
                        throw ProtocolError(code: .internal, message: "design engine: the file was not saved")
                    }
                    return .object(["path": .string(out.path)])
                }
                let lang = ext == "tsx" ? "react" : ext, node = str("node")
                let code = try await use { c throws(ProtocolError) in
                    try await Self.sync(c, deadline)
                    let (ids, _) = try await Self.roots(c, node, nil, deadline)
                    var parts: [String] = []
                    for id in ids {
                        let r = try await c.command("inspect.code", ["id": id, "language": .string(lang)], timeout: try Self.left(deadline))
                        guard case .object(let o) = r, case .string(let s)? = o["code"] else {
                            throw ProtocolError(code: .internal, message: "design engine: no code in the inspect.code answer")
                        }
                        parts.append(s)
                    }
                    return parts.joined(separator: "\n")
                }
                try alive(panel)
                try await Self.write(Data(code.utf8), out)
                return .object(["path": .string(out.path)])
            default:
                throw ProtocolError(code: .invalidArgs, message: "Unknown command '\(command)'")
            }
        }
        return command == "design.link" ? r : Self.scrub(r, secrets)
    }

    /// Runs `body` on the daemon's own client of file `id` (made like a caller's: joined, live, writable; its only write
    /// root is `<root>/design/systems`), within the calling command's `deadline`. Errors scrubbed. `spare`: room is made
    /// only by closing another idle client of the daemon's own.
    func onSystemClient<T: Sendable>(_ id: String, deadline: ContinuousClock.Instant, spare: Bool = false,
                                     _ body: (MCPStdioClient, ContinuousClock.Instant) async throws(ProtocolError) -> T) async throws -> T {
        try await guarded {
            let f = try file(id)
            return try await use(Key(caller: Self.systemCaller, file: f.id), f, Self.systemCaller, deadline, spare: spare) { c throws(ProtocolError) in
                try await body(c, deadline)
            }
        }
    }

    /// Runs `body` on `caller`'s own client of `panel`'s file (as `run`: the caller's undo), within `command`'s
    /// deadline; result and errors scrubbed. For the daemon-built `design.system.*` wrappers only.
    func onCallerClient(_ command: String, panel: Panel, caller: (key: String, name: String),
                        _ body: (MCPStdioClient, ContinuousClock.Instant) async throws(ProtocolError) -> JSONValue) async throws -> JSONValue {
        let r = try await guarded { () async throws -> JSONValue in
            guard case .string(let fid)? = panel.state["file"] else {
                throw ProtocolError(code: .invalidArgs, message: "'\(command)' needs a design panel")
            }
            let f = try file(fid), deadline = self.deadline(command)
            return try await use(Key(caller: caller.key, file: f.id), f, caller.name, deadline) { c throws(ProtocolError) in
                do throws(ProtocolError) { return try await body(c, deadline) } catch { throw Self.unsure(error) }
            }
        }
        return Self.scrub(r, secrets)
    }

    /// `link` aimed at the server now up (a design system's view link, for `library.add`).
    func current(_ link: String) async throws -> String {
        try await guarded { rehosted(link, try await running().0) }
    }

    /// Publishes the library of `snapshot` (a `.figcraft` file) as the next version of file `id`'s library, through a
    /// short-lived client that reads only the snapshot's folder; the engine's answer, scrubbed. The document keeps the
    /// file's name, so the library keeps its own.
    func republish(_ snapshot: URL, to id: String, deadline: ContinuousClock.Instant) async throws -> JSONValue {
        try await guarded {
            let f = try file(id)
            let (ep, _) = try await running()
            let c = try await MCPStdioClient(executable: cli, args: ["mcp", "--automation-read-root", snapshot.deletingLastPathComponent().path],
                                             env: cliEnv, runDir: runDir, name: "collie-bridge")
            defer { c.close() }
            _ = try await c.command("file.open", ["path": .string(snapshot.path)], timeout: try Self.left(deadline))
            _ = try await c.command("file.rename", ["name": .string(f.name)], timeout: try Self.left(deadline))
            let r = try await c.command("library.publishToServer", ["server": .string(rehosted(f.editLink, ep))], timeout: try Self.left(deadline))
            return Self.scrub(r, secrets)
        }
    }

    // MARK: clients

    /// Runs `body` on `key`'s client, made (joined, live and writable) when there is none, it died, or the server
    /// restarted since; at most once per call.
    private func use<T: Sendable>(_ key: Key, _ f: File, _ name: String, _ deadline: ContinuousClock.Instant, spare: Bool = false,
                                  _ body: (MCPStdioClient) async throws(ProtocolError) -> T) async throws -> T {
        let s = try slot(key, spare: spare)
        try await acquire(s, deadline)
        defer { release(key, s) }
        let (ep, gen) = try await running()
        guard slots[key] === s else { throw Self.gone }
        if s.client?.isAlive != true || s.generation != gen {
            s.client?.close(); s.client = nil
            // the key, not the display name, tells the daemon's own client (a terminal may be named anything)
            let out = key.caller == Self.systemCaller ? designDir.appendingPathComponent("systems") : exportsDir(f)
            let c = try await client(f, name, ep, out, deadline)
            guard slots[key] === s else { c.close(); throw Self.gone }
            s.client = c; s.generation = gen
        }
        guard let c = s.client else { throw Self.gone }
        do throws(ProtocolError) { return try await body(c) } catch {
            // the engine may still be at it: the next call gets a fresh client, not this one's backlog
            if error.code == .timeout, s.client === c { c.close(); s.client = nil }
            throw error
        }
    }

    private static let gone = ProtocolError(code: .notFound, message: "the design panel or its file was closed meanwhile")

    /// `key`'s slot; a new one when the pool is full closes an idle client: the daemon's own first (nobody's undo),
    /// then the one idle the longest (`spare`: only the daemon's own).
    private func slot(_ key: Key, spare: Bool = false) throws(ProtocolError) -> Slot {
        if let s = slots[key] { return s }
        if slots.count >= Self.maxClients {
            guard let oldest = slots.filter({ !$0.value.busy && $0.value.waiters.isEmpty && (!spare || $0.key.caller == Self.systemCaller) })
                .min(by: { a, b in
                    let (x, y) = (a.key.caller == Self.systemCaller, b.key.caller == Self.systemCaller)
                    return x != y ? x : a.value.lastUsed < b.value.lastUsed
                })?.key else { throw Self.busy }
            drop(oldest)
        }
        let s = Slot()
        slots[key] = s
        return s
    }

    private func acquire(_ s: Slot, _ deadline: ContinuousClock.Instant) async throws(ProtocolError) {
        s.idleTimer?.cancel(); s.idleTimer = nil
        if !s.busy { s.busy = true; return }
        waiterSeq += 1
        let id = waiterSeq
        let refused: ProtocolError? = await withCheckedContinuation { c in
            s.waiters.append((id, c))
            Task { [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                await self?.expire(id)
            }
        }
        if let refused { throw refused }
    }

    private func expire(_ id: Int) {
        for s in slots.values {
            if let i = s.waiters.firstIndex(where: { $0.id == id }) {
                s.waiters.remove(at: i).go.resume(returning: ProtocolError(code: .timeout, message: "design engine: timed out waiting for this client"))
                return
            }
        }
    }

    /// The next waiter gets the slot; none left: idle from now, closed after `idle` unless used again.
    private func release(_ key: Key, _ s: Slot) {
        guard slots[key] === s else { return }
        if !s.waiters.isEmpty { s.waiters.removeFirst().go.resume(returning: nil); return }
        s.busy = false; s.lastUsed = .now
        let idle = idle, id = ObjectIdentifier(s)
        s.idleTimer = Task { [weak self] in
            try? await Task.sleep(for: idle)
            guard !Task.isCancelled else { return }
            await self?.idleOver(key, id)
        }
    }

    private func idleOver(_ key: Key, _ id: ObjectIdentifier) {
        guard let s = slots[key], ObjectIdentifier(s) == id, !s.busy, s.waiters.isEmpty else { return }
        drop(key)
    }

    /// Closes `key`'s client; its queued callers are refused, the one in flight fails `.unavailable`.
    private func drop(_ key: Key) {
        guard let s = slots.removeValue(forKey: key) else { return }
        s.idleTimer?.cancel()
        s.client?.close()
        for w in s.waiters { w.go.resume(returning: Self.gone) }
        s.waiters = []
    }

    /// A client of `f`: `figcraft-cli mcp` writing only into `out`, joined to its session.
    private func client(_ f: File, _ name: String, _ ep: FigcraftServer.Endpoint, _ out: URL,
                        _ deadline: ContinuousClock.Instant) async throws(ProtocolError) -> MCPStdioClient {
        let out = try dir(out)
        let c = try await MCPStdioClient(executable: cli, args: ["mcp", "--automation-write-root", out.path],
                                         env: cliEnv, runDir: runDir, name: name)
        do throws(ProtocolError) {
            _ = try await c.command("collab.join", ["link": .string(rehosted(f.editLink, ep))], timeout: try Self.left(deadline))
            _ = try await live(c, f.name, deadline) { _ in true }
            return c
        } catch {
            c.close()
            throw error
        }
    }

    /// Polls `collab.peers` until the session is live and writable (and `ready` holds); its last answer.
    private func live(_ c: MCPStdioClient, _ name: String, _ deadline: ContinuousClock.Instant,
                      ready: ([String: JSONValue]) -> Bool) async throws(ProtocolError) -> [String: JSONValue] {
        while true {
            if case .object(let o) = try await c.command("collab.peers", [:], timeout: try Self.left(deadline)) {
                if o["status"] == .string("live") && o["readOnly"] == .bool(false) && ready(o) { return o }
                if o["status"] == .string("failed") {
                    let why = if case .string(let r)? = o["reason"] { r } else { "no reason given" }
                    throw ProtocolError(code: .unavailable, message: "design engine: cannot open '\(name)': \(why)")
                }
            }
            guard ContinuousClock.now + .milliseconds(100) < deadline else {
                throw ProtocolError(code: .timeout, message: "design engine: '\(name)' did not come live")
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// `link` with its `host=` set to the server now up (the stored one may name a port from an earlier daemon run).
    private func rehosted(_ link: String, _ ep: FigcraftServer.Endpoint) -> String {
        guard let host = ep.wsURL.firstMatch(of: /^ws:\/\/([^\/?]+)/)?.1 else { return link }
        let l = link.replacing(/([?&])host=[^&]*/) { "\($0.1)host=\(host)" }
        secrets.insert(l)
        return l
    }

    private func running() async throws -> (FigcraftServer.Endpoint, Int) {
        let r = try await server.running()
        secrets.insert(r.0.key)
        return r
    }

    /// The panel is gone: so are the clients of files no open panel shows any more (`openFiles`).
    func panelClosed(_ id: UUID, openFiles: Set<String>) {
        closed.insert(id)
        for k in slots.keys where !openFiles.contains(k.file) { drop(k) }
    }

    /// A terminal was removed or relaunched: its clients go.
    func callerGone(_ caller: String) {
        for k in slots.keys where k.caller == caller { drop(k) }
    }

    /// Daemon stop: every client goes (each terminates its own process group).
    func stop() {
        for k in Array(slots.keys) { drop(k) }
    }

    // MARK: helpers

    private func alive(_ panel: Panel) throws(ProtocolError) {
        if closed.contains(panel.id) { throw ProtocolError(code: .notFound, message: "Panel '\(panel.name)' was closed meanwhile") }
    }

    private func dir(_ u: URL) throws(ProtocolError) -> URL {
        do { try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw ProtocolError(code: .internal, message: "design: cannot create \(u.path)") }
        return u
    }

    /// Off the cooperative pool: an export can be large.
    private static func write(_ d: Data, _ to: URL) async throws(ProtocolError) {
        guard try await UnixSocketClient.offPool({ (try? d.write(to: to)) != nil }) else {
            throw ProtocolError(code: .internal, message: "design: cannot write \(to.path)")
        }
    }

    /// Every error a caller sees, scrubbed; anything not a `ProtocolError` becomes `.internal`.
    private func guarded<T>(_ f: () async throws -> T) async throws -> T {
        do {
            let r = try await f()
            return r
        } catch let e as ProtocolError {
            throw ProtocolError(code: e.code, message: Self.scrub(e.message, secrets))
        } catch {
            throw ProtocolError(code: .internal, message: Self.scrub("design: \(error.localizedDescription)", secrets))
        }
    }

    /// Hides `secrets`, `figcraft://` links and `token=` / `key=` values.
    static func scrub(_ s: String, _ secrets: Set<String>) -> String {
        var s = s
        for x in secrets where !x.isEmpty { s = s.replacingOccurrences(of: x, with: "[hidden]") }
        return s.replacing(/figcraft:\/\/[^\s"'`<>)]*/, with: "[link]").replacing(/\b(?:token|key)=[^\s&"'`<>)]*/, with: "[hidden]")
    }

    static func scrub(_ v: JSONValue, _ secrets: Set<String>) -> JSONValue {
        switch v {
        case .string(let s): .string(scrub(s, secrets))
        case .array(let a): .array(a.map { scrub($0, secrets) })
        case .object(let o): .object(o.mapValues { scrub($0, secrets) })
        default: v
        }
    }

    /// The figcraft command families callers may run: the ones that edit or read the document (from the v0.7.0
    /// registry, `crates/engine/src/cmd/` + `codegen.rs`; `list_commands` lists them). Everything else is refused:
    /// `collab.*` (sessions, links), `command.batch` (use design.batch), `file.*`, `doc.*`, `branch.*`, `version.*`,
    /// `window.*` (other documents, the disk), `library.*`/`libraries.*` (publish to / pull from servers),
    /// `plugin.*`/`plugins.*`/`widget.*` (remote or local code), `codeConnect.*`, `devResource.*` (paths, URLs),
    /// `app.*`, `pref.*`, `help.*`, `view.*`, `tool.*`, `comment.*`, `dev.*`, `template.*` (app UI and state).
    static let families: Set<String> = [
        "node", "text", "vector", "shape", "frame", "section", "object", "select", "selection", "layers", "edit", "style",
        "fill", "stroke", "effect", "paint", "image", "layout", "grid", "align", "distribute", "arrange", "transform", "bool",
        "shapeBuilder", "component", "instance", "variable", "page", "inspect", "proto", "annotation", "measure", "guide", "export",
    ]
    /// In those families but refused: the system clipboard and app defaults (`edit.*` ones),
    /// `edit.repeat` (repeats whatever ran last).
    static let refusedCommands: Set<String> = [
        "edit.copy", "edit.cut", "edit.paste", "edit.pasteOver", "edit.pasteReplace", "edit.copyProperties",
        "edit.pasteProperties", "edit.repeat", "edit.pickColor", "edit.setDefaultProperties",
    ]

    static func permitted(_ cmd: String) -> Bool {
        guard let dot = cmd.firstIndex(of: ".") else { return false }
        return families.contains(String(cmd[..<dot])) && !refusedCommands.contains(cmd)
    }

    private static func allowed(_ cmd: String) throws(ProtocolError) -> String {
        guard !cmd.isEmpty else { throw ProtocolError(code: .invalidArgs, message: "Missing argument 'command'") }
        guard permitted(cmd) else {
            throw ProtocolError(code: .invalidArgs, message: "design command '\(cmd)' is not available to agents")
        }
        return cmd
    }

    /// Allowed commands that can also name a file: only their in-memory forms (the client's write root confines the rest).
    private static func checkParams(_ cmd: String, _ p: [String: JSONValue], inBatch: Bool = false) throws(ProtocolError) {
        // a batch's `{"$step": n}` references resolve in the engine, after these checks: none where a check looks
        if p["$step"] != nil { throw ProtocolError(code: .invalidArgs, message: "step references are not allowed in 'params'") }
        try needsTargets(cmd, p, inBatch: inBatch)
        if cmd == "variable.import" { try noStepRef(p["variables"], "variables") }
        if cmd == "text.preview" { try noStepRef(p["command"], "command"); try noStepRef(p["params"], "params") }
        let refused: Bool = switch cmd {
        case "image.place", "variable.export", "component.playground": p["path"] != nil && p["path"] != .null   // data / text / code only
        case "variable.import": if case .object? = p["variables"] { false } else { true }   // a string may be a path
        // runs another command by id (textpreview.rs PREVIEWABLE, which includes library.applyStyle: a library fetch);
        // the only other re-dispatchers, edit.repeat and command.batch, are refused outright
        case "text.preview": if case .string(let c)? = p["command"], ["style.apply", "text.setVariations", "text.style"].contains(c) { false } else { true }
        default: false
        }
        if refused { throw ProtocolError(code: .invalidArgs, message: "design command '\(cmd)' may not name a file or URL here") }
        try checkLinks(cmd, p)
        // text.preview runs its inner command (text.style) with the inner params
        if cmd == "text.preview", case .string(let c)? = p["command"] {
            switch p["params"] {
            case nil, .null?: try needsTargets(c, [:], inBatch: inBatch)
            case .object(let ip)?: try checkLinks(c, ip); try needsTargets(c, ip, inBatch: inBatch)
            default: throw ProtocolError(code: .invalidArgs, message: "text.preview params must be an object")
            }
        }
    }

    /// Links: only schemes the HTML export would emit; only `null` removes a link (figcraft stores "" as a link).
    private static func checkLinks(_ cmd: String, _ p: [String: JSONValue]) throws(ProtocolError) {
        for k in ["field", "url", "hyperlink", "boundVariables"] { try noStepRef(p[k], k) }
        if case .object(let o)? = p["props"], o["$step"] != nil { throw ProtocolError(code: .invalidArgs, message: "step references are not allowed in 'props'") }
        if case .object(let o)? = p["props"] { for k in ["hyperlink", "boundVariables"] { try noStepRef(o[k], "props.\(k)") } }
        var links: [JSONValue?] = []
        if cmd == "text.link" { links.append(p["url"]) }
        if cmd == "text.style" || cmd == "node.set" { links.append(p["hyperlink"]) }
        let props: [String: JSONValue] = if case .object(let o)? = p["props"] { o } else { [:] }
        links.append(props["hyperlink"])   // every props::apply caller (create/set)
        // a variable's value is never checked: no link may come from one (variable.bind, style.bind, boundVariables)
        if p["variable"] != nil && p["variable"] != .null { try refuseLinkField(p["field"]) }
        for case .object(let bound)? in [p["boundVariables"], props["boundVariables"]] {
            for (k, v) in bound where v != .null { try refuseLinkField(.string(k)) }
        }
        for case let v? in links {
            switch v {
            case .null: continue
            case .string(let u) where ExportSemantics.safeHref(u) != nil: continue
            default: throw ProtocolError(code: .invalidArgs, message: "link must be http(s), mailto, tel, #anchor or a relative path")
            }
        }
    }

    /// Refuses a batch `{"$step": n}` reference in `v`, or one nested in it.
    private static func noStepRef(_ v: JSONValue?, _ what: String) throws(ProtocolError) {
        func has(_ v: JSONValue) -> Bool {
            switch v {
            case .object(let o): o["$step"] != nil || o.values.contains(where: has)
            case .array(let a): a.contains(where: has)
            default: false
            }
        }
        if let v, has(v) { throw ProtocolError(code: .invalidArgs, message: "step references are not allowed in '\(what)'") }
    }

    /// Refuses binding a variable to the `hyperlink` field (figcraft matches field names exactly; any case refused).
    static func refuseLinkField(_ field: JSONValue?) throws(ProtocolError) {
        if case .string(let f)? = field, f.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "hyperlink" {
            throw ProtocolError(code: .invalidArgs, message: "a link can't be bound to a variable")
        }
    }

    private static func json(_ s: String, _ what: String) throws(ProtocolError) -> JSONValue {
        guard s.utf8.count <= inputCap else { throw ProtocolError(code: .invalidArgs, message: "'\(what)' is over 4 MiB") }
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) else {
            throw ProtocolError(code: .invalidArgs, message: "'\(what)' is not valid JSON")
        }
        return v
    }

    /// The batch's JSON text: `--commands`, or a `.json` `--file` inside the caller's cwd tree (links resolved; the
    /// daemon reads nothing else on a caller's behalf), read off the cooperative pool.
    private static func batchText(commands: String?, file: String?, cwd: String?) async throws(ProtocolError) -> String {
        switch (commands, file) {
        case (let c?, nil): return c
        case (nil, let f?):
            guard f.hasSuffix(".json") else { throw ProtocolError(code: .invalidArgs, message: "--file must be a .json file") }
            guard let cwd, cwd.hasPrefix("/") else { throw ProtocolError(code: .invalidArgs, message: "--file needs the caller's current directory") }
            let base = URL(fileURLWithPath: cwd, isDirectory: true).resolvingSymlinksInPath().path
            let u = URL(fileURLWithPath: f, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath()
            guard u.path.hasPrefix(base == "/" ? "/" : base + "/") else {
                throw ProtocolError(code: .invalidArgs, message: "--file must be inside the current directory")
            }
            let (data, size) = try await UnixSocketClient.offPool { () -> (Data?, Int) in
                let size = ((try? FileManager.default.attributesOfItem(atPath: u.path)[.size]) as? Int) ?? -1
                return (0...inputCap).contains(size) ? (FileManager.default.contents(atPath: u.path), size) : (nil, size)
            }
            if size > inputCap { throw ProtocolError(code: .invalidArgs, message: "'\(f)' is over 4 MiB") }
            guard let data else { throw ProtocolError(code: .invalidArgs, message: "cannot read \(f)") }
            return String(decoding: data, as: UTF8.self)
        default: throw ProtocolError(code: .invalidArgs, message: "pass --commands <json array> or --file <path.json>")
        }
    }

    /// The batch's steps: `[{command, params?}]`, each allowed (`[]`: none).
    private static func steps(text: String) throws(ProtocolError) -> [(command: String, params: [String: JSONValue], raw: JSONValue)] {
        guard case .array(let a) = try json(text, "commands") else {
            throw ProtocolError(code: .invalidArgs, message: "the batch must be a JSON array of {command, params}")
        }
        return try a.enumerated().map { (i, step) throws(ProtocolError) in
            guard case .object(let o) = step, case .string(let cmd)? = o["command"] else {
                throw ProtocolError(code: .invalidArgs, message: "batch step \(i + 1) needs a string 'command'")
            }
            let params: [String: JSONValue]
            switch o["params"] { case nil, .null?: params = [:]; case .object(let p)?: params = p
            default: throw ProtocolError(code: .invalidArgs, message: "batch step \(i + 1): 'params' must be an object") }
            let ok = try allowed(cmd)
            try checkParams(cmd, params, inBatch: true)
            return (ok, params, step)
        }
    }

    static let skipped = JSONValue.object(["skipped": .string("no ids")])
    /// Edits whose `ids: []` (an agent's filter that found nothing) is skipped instead of sent.
    static let selectionEdits: Set<String> = ["edit.delete", "edit.duplicate", "object.group"]
    static func noIds(_ cmd: String, _ p: [String: JSONValue]) -> Bool { selectionEdits.contains(cmd) && p["ids"] == .array([]) }

    /// R7/R10: an agent names its layers, never the user's selection. The engine's commands whose params doc takes
    /// `ids?`/`id?` (figcraft v0.7.0 `crates/engine/src`, spec params; `params.rs` `targets()`: no `ids` array and no
    /// `id` = the selection), among the permitted ones, minus `proto.evaluate` (its `id?` defaults to the document's
    /// modes) and `vector.edit.*` (`selectionOnly`). They need `ids` (an array) or `id`.
    /// ponytail: a static table; a new engine version's commands need it regenerated from the spec params docs.
    static let targetCommands: Set<String> = [
        "align.bottom", "align.hcenter", "align.left", "align.right", "align.top", "align.vcenter",
        "annotation.add", "annotation.edit", "annotation.list", "annotation.remove",
        "arrange.back", "arrange.backward", "arrange.forward", "arrange.front", "arrange.packH", "arrange.packV",
        "arrange.roundToPixels", "arrange.spacing", "arrange.tidy",
        "bool.exclude", "bool.flatten", "bool.intersect", "bool.subtract", "bool.union",
        "component.addProperty", "component.addVariant", "component.combineVariants", "component.create",
        "component.createMultiple", "component.deleteProperty", "component.detach", "component.editProperty",
        "component.exposeInstance", "component.goToMain", "component.hideWhenPublishing", "component.makeSlot",
        "component.playground", "component.properties", "component.pushChanges", "component.removeSlot",
        "component.resetInstance", "component.resetOverride", "component.restoreMain",
        "distribute.horizontal", "distribute.vertical",
        "edit.delete", "edit.duplicate",
        "effect.add", "effect.move", "effect.remove", "effect.set",
        "export.add", "export.remove", "export.update",
        "fill.add", "fill.move", "fill.pattern", "fill.remove", "fill.set",
        "frame.swapOrientation",
        "grid.add", "grid.move", "grid.remove",
        "image.adjust", "image.savePreset",
        "inspect.assets", "inspect.code", "inspect.componentCode", "inspect.properties",
        "instance.exposed", "instance.resetSlot", "instance.setProperties", "instance.slotInsert", "instance.swap",
        "layout.add", "layout.remove", "layout.setTrack", "layout.suggest",
        "measure.distances", "measure.padding",
        "node.reparent",
        "object.batchRename", "object.convertToFrame", "object.convertToGroup", "object.convertToSection",
        "object.flipH", "object.flipV", "object.frameSelection", "object.group", "object.mask", "object.moveToPage",
        "object.opacityKeys", "object.rasterize", "object.releaseMask", "object.removeFill", "object.removeFrame",
        "object.removeStroke", "object.rename", "object.resizeToFit", "object.rotate180", "object.rotateLeft",
        "object.rotateRight", "object.setThumbnail", "object.swapFillStroke", "object.toggleLock",
        "object.toggleVisible", "object.ungroup", "object.wrapInSection",
        "page.delete", "page.duplicate", "page.move", "page.rename", "page.setBackground",
        "proto.action.add", "proto.action.move", "proto.action.remove", "proto.action.set",
        "proto.conditional.addBlock", "proto.conditional.removeBlock", "proto.conditional.setCondition",
        "proto.interaction.add", "proto.interaction.clear", "proto.interaction.remove", "proto.interaction.set",
        "section.toggleContents",
        "selection.colors",
        "shapeBuilder.merge", "shapeBuilder.regions", "shapeBuilder.remove",
        "stroke.add", "stroke.brush", "stroke.move", "stroke.remove", "stroke.set", "stroke.widthProfile",
        "style.apply", "style.detach",
        "text.alignCenter", "text.alignJustify", "text.alignLeft", "text.alignRight", "text.bold", "text.bulletList",
        "text.case", "text.caseLower", "text.caseOriginal", "text.caseSmallCaps", "text.caseTitle", "text.caseUpper",
        "text.decoration", "text.italic", "text.lineHeightDown", "text.lineHeightUp", "text.link", "text.listStyle",
        "text.maxLines", "text.numberList", "text.paragraphIndent", "text.paragraphSpacing", "text.pathOptions",
        "text.removeFromPath", "text.set", "text.setFeatures", "text.setVariations", "text.sizeDown", "text.sizeUp",
        "text.strikethrough", "text.style", "text.trackingDown", "text.trackingUp", "text.underline",
        "text.weightDown", "text.weightUp",
        "transform.move", "transform.moveTo", "transform.resize", "transform.rotate", "transform.scale",
        "variable.bind", "variable.setMode",
        "vector.flatten", "vector.join", "vector.offset", "vector.outlineStroke", "vector.reverse", "vector.simplify",
        "vector.smoothJoin",
    ]
    /// Other params that default to the selection: each group needs one of its keys.
    static let selectionDefaults: [String: [[String]]] = [
        "guide.remove": [["index"]], "proto.flow.add": [["start"]], "proto.present": [["start"]],
        "text.onPath": [["text"], ["path"]], "style.create": [["from", "value"]],
    ]
    /// Commands with no target param that act on the selection (or vector edit mode's selected points): refused.
    static let selectionOnly: Set<String> = [
        "transform.nudge", "transform.nudgeSize", "transform.rotationOrigin", "transform.setRotationOrigin",
        "object.hideOthers", "text.listIndent", "text.listOutdent", "vector.deleteHeal",
    ]
    /// `inBatch`: a `{"$step": n}` object stands for an earlier step's result (design.run has none).
    private static func needsTargets(_ cmd: String, _ p: [String: JSONValue], inBatch: Bool) throws(ProtocolError) {
        if selectionOnly.contains(cmd) || cmd.hasPrefix("vector.edit.") {
            throw ProtocolError(code: .invalidArgs, message: "\(cmd) acts only on the user's selection: not available to agents")
        }
        // only what the engine takes as a target; anything else falls through to the selection (`params.rs` `targets()`)
        func given(_ k: String) -> Bool {
            if k == "value", let v = p[k] { return v != .null }   // style.create's own style JSON, not a target
            switch p[k] {
            case .object(let o)?: return inBatch && o["$step"] != nil
            case .array?: return k == "ids"                // `[]`: skipped or refused by the engine, never the selection
            case .number?: return k != "ids"               // a layer id, or the guide's `index`
            case .string?: return k != "ids" && k != "index"   // a layer id
            default: return false
            }
        }
        var groups = selectionDefaults[cmd] ?? []
        if targetCommands.contains(cmd) { groups.insert(["ids", "id"], at: 0) }
        for g in groups where !g.contains(where: given) {
            let what = g == ["ids", "id"] ? "ids" : g.joined(separator: " or ")
            throw ProtocolError(code: .invalidArgs, message: "\(cmd) needs \(what): agents never act on the user's selection")
        }
    }

    /// The engine's own batch errors count the steps it was sent (`step n`, `` `$step` n ``, `0 to n`): back to the
    /// caller's numbers (`sent[i]` = the caller's index of sent step i). Numbers out of range stay as they are.
    static func callerSteps(_ message: String, sent: [Int]) -> String {
        message.replacing(/(step |`\$step` |0 to )(\d+)/) { m in
            guard let i = Int(m.output.2), sent.indices.contains(i) else { return String(m.output.0) }
            return "\(m.output.1)\(sent[i])"
        }
    }

    /// `steps` without the `skip` indices; `{"$step": n}` renumbered to the steps sent. A reference to a skipped step
    /// is refused (it has no result). Only whole, non-negative indices are renumbered (never `Int(n)` on any Double).
    static func withoutSkipped(_ steps: [JSONValue], skip: Set<Int>) throws(ProtocolError) -> [JSONValue] {
        var to: [Int: Int] = [:]
        for i in steps.indices where !skip.contains(i) { to[i] = to.count }
        func walk(_ v: JSONValue) throws(ProtocolError) -> JSONValue {
            switch v {
            case .object(var o) where o["$step"] != nil:   // `{"$step": n}`, `{"$step": n, "field": f}` (the engine's forms)
                // not a step index (1.5, -1, 1e300, a string): as is, for the engine to refuse
                guard case .number(let n)? = o["$step"], let k = Int(exactly: n), k >= 0 else { return v }
                if let m = to[k] { o["$step"] = .number(Double(m)); return .object(o) }
                if skip.contains(k) {
                    throw ProtocolError(code: .invalidArgs, message: "{\"$step\": \(k)} refers to a step skipped for having no ids")
                }
                return v   // past the last step: the engine refuses it
            case .object(let o):
                var out: [String: JSONValue] = [:]
                for (k, x) in o { out[k] = try walk(x) }
                return .object(out)
            case .array(let a): return .array(try a.map { x throws(ProtocolError) in try walk(x) })
            default: return v
            }
        }
        return try steps.indices.filter { !skip.contains($0) }.map { i throws(ProtocolError) in try walk(steps[i]) }
    }

    /// The engine's refusal of a batch (an `isError` answer: it applied nothing), with the step it names: engine errors
    /// quote the failing command (`node.set`).
    /// ponytail: a command used by several steps names them all; a step whose error quotes no command is not located.
    static func located(_ message: String, _ steps: [String]) -> ProtocolError {
        let named = Set(message.matches(of: /`([A-Za-z0-9_.\-]+)`/).map { String($0.1) })
        let hits = steps.indices.filter { named.contains(steps[$0]) }
        let at = switch hits.count {
        case 0: ""
        case 1: " at step \(hits[0] + 1) (\(steps[hits[0]]), $step \(hits[0]))"
        default: " at one of steps \(hits.map { "\($0 + 1)" }.joined(separator: ", ")) (\(steps[hits[0]]))"
        }
        return ProtocolError(code: .internal, message: "batch failed\(at); nothing was applied: \(message.isEmpty ? "no reason given" : message)")
    }

    /// A timed-out edit: the engine may have applied it after all.
    private static func unsure(_ e: ProtocolError) -> ProtocolError {
        e.code == .timeout ? ProtocolError(code: .timeout, message: "\(e.message); it may still have been applied") : e
    }

    /// Reads see the latest live state: `collab.peers` polls the session first.
    static func sync(_ c: MCPStdioClient, _ deadline: ContinuousClock.Instant) async throws(ProtocolError) {
        _ = try await c.command("collab.peers", [:], timeout: try left(deadline))
    }

    /// A tool's text answer as JSON (a string when it is not JSON).
    private static func decoded(_ r: MCPResult) -> JSONValue {
        let t = r.texts.joined(separator: "\n")
        return (try? JSONDecoder().decode(JSONValue.self, from: Data(t.utf8))) ?? .string(t)
    }

    /// `sync`, a pause, `sync` again: edits other clients just made reach this one through the server (tens of ms
    /// here) and the session reports no sequence to wait for.
    /// ponytail: a fixed 500 ms; an edit slower than that to arrive is missed (publish retries, see DesignSystemService)
    static func settle(_ c: MCPStdioClient, _ deadline: ContinuousClock.Instant) async throws(ProtocolError) {
        try await sync(c, deadline)
        try? await Task.sleep(for: .milliseconds(500))
        try await sync(c, deadline)
    }

    /// Page `page`'s id and top-level layer ids from `inspect_document` (no `page`: the current one, else the first);
    /// nil when there is no such page.
    static func topLayers(_ doc: JSONValue, page: String?) -> (page: String, ids: [JSONValue])? {
        guard case .object(let d) = doc, case .array(let pages)? = d["pages"] else { return nil }
        func id(_ v: JSONValue) -> String? { if case .object(let p) = v { p["id"].flatMap(idString) } else { nil } }
        let want = page ?? d["currentPage"].flatMap(idString)
        guard case .object(let p)? = pages.first(where: { id($0) != nil && id($0) == want }) ?? (page == nil ? pages.first : nil),
              let pid = p["id"].flatMap(idString) else { return nil }
        guard case .array(let kids)? = p["children"] else { return (pid, []) }
        return (pid, kids.compactMap { if case .object(let k) = $0 { k["id"] } else { nil } })
    }

    /// Session ids are large integers; anything else (e.g. "VariableID:…") goes as a string.
    private static func nodeId(_ s: String) -> JSONValue { Int64(s).map { .number(Double($0)) } ?? .string(s) }

    private static func epochMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// The command's own timeout less 2 s: the answer must reach the CLI before it gives up.
    nonisolated func deadline(_ command: String) -> ContinuousClock.Instant {
        let own = Duration.seconds(max(1, (PluginRegistry.command(command)?.1.timeoutSeconds ?? 30) - 2))
        return .now + min(own, timeoutCap ?? own)
    }

    static func left(_ deadline: ContinuousClock.Instant) throws(ProtocolError) -> Duration {
        let d = deadline - .now
        guard d > .zero else { throw ProtocolError(code: .timeout, message: "design engine: timed out") }
        return d
    }
}

extension DesignService.File {
    private enum CodingKeys: String, CodingKey { case id, name, editLink, viewLink, createdAt, paddockId }
    private enum Legacy: String, CodingKey { case floorId }   // before the herding vocabulary
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        editLink = try c.decode(String.self, forKey: .editLink); viewLink = try c.decodeIfPresent(String.self, forKey: .viewLink)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        paddockId = try c.decodeIfPresent(UUID.self, forKey: .paddockId) ?? d.container(keyedBy: Legacy.self).decodeIfPresent(UUID.self, forKey: .floorId)
    }
}
