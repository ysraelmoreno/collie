import Foundation
import CollieCore
import CollieProtocol

/// Design systems: design files whose library (tokens, styles, components) is published on the local figcraft server
/// as numbered versions, through the daemon's own client of each file (`DesignService.systemCaller`). Every version
/// is also kept as a snapshot `v<N>.figcraft`. Nothing here returns a link: view links join the scrubbed secrets.
actor DesignSystemService {
    private let design: DesignService
    private let store: DesignSystemStore
    private var systems: [DesignSystem]?   // loaded on first use
    /// Lowercased names with a create or publish in flight: later ones wait (versions and snapshots stay in order).
    private var busy: Set<String> = []

    init(design: DesignService, root: URL) {
        self.design = design
        self.store = DesignSystemStore(dir: root.appendingPathComponent("design"))
    }

    func list() async throws -> [DesignSystem] { try await registry() }

    func history(name: String) async throws -> [DesignSystemEvent] {
        let id = try await system(named: name).id, store = store
        return try await UnixSocketClient.offPool { store.history(id) }
    }

    func system(named name: String) async throws -> DesignSystem {
        guard let s = try await registry().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw ProtocolError(code: .notFound, message: "no design system named '\(name)'")
        }
        return s
    }

    /// A system, why its snapshot is missing (the version is out and recorded all the same) and how the version
    /// reached the screen files using the system.
    typealias Outcome = (system: DesignSystem, snapshotError: String?, files: [FileOutcome])

    /// A new system: its design file seeded with the starter tokens, style and component (or a copy of `from`'s file),
    /// published and snapshotted. A create that failed half-way leaves its file and a pending mark (`DesignSystemStore`):
    /// a retry of that name takes the file over (a seeded one is re-seeded only without a `Tokens` collection and
    /// published; a copy, already published as v1, is kept as it is, whatever `from` says now). Any other design file
    /// of that name is refused: user files are never seeded. Everything runs within the command's one deadline.
    func create(name: String, from: String?, reason: String, by: String) async throws -> Outcome {
        let deadline = design.deadline("design.system.create")
        try DesignSystemStore.validate(name)
        let lower = name.lowercased()
        var source: DesignSystem?
        if let from {
            source = try await system(named: from)
            if let s = source, let v = s.reverted {   // its file is not what its library says
                throw ProtocolError(code: .invalidArgs, message: "design system '\(s.name)' was reverted to v\(v) and its file still shows newer content; publish it (or --force) before copying")
            }
        }
        // no await from the check to the insert
        if try await registry().contains(where: { $0.name.lowercased() == lower }) || busy.contains(lower) {
            throw ProtocolError(code: .invalidArgs, message: "a design system named '\(name)' already exists")
        }
        busy.insert(lower); defer { busy.remove(lower) }
        let f: DesignService.File, version: Int, copied: Bool
        if let existing = try await design.list().first(where: { $0.name.lowercased() == lower }) {
            let st = store
            guard let mark = try await UnixSocketClient.offPool({ st.pending() })[lower], mark.fileId == existing.id else {
                throw ProtocolError(code: .invalidArgs,
                                    message: "a design file named '\(name)' already exists (not a design system); pick another name")
            }
            f = existing; copied = mark.copied
        } else {
            f = try await design.create(name, deadline: deadline, copying: source.map { $0.fileId.uuidString.lowercased() })
            copied = source != nil
            let st = store, mark = DesignSystemStore.Pending(fileId: f.id, copied: copied)
            try await UnixSocketClient.offPool { try st.setPending(lower, mark) }
        }
        if !copied {
            version = try await design.onSystemClient(f.id, deadline: deadline) { c, deadline throws(ProtocolError) in
                try await DesignService.sync(c, deadline)
                if try await !Self.hasTokens(c, deadline) {
                    let r = try await c.result("batch", ["commands": .array(Self.seed), "label": .string("Design system")],
                                               timeout: try DesignService.left(deadline))
                    if r.isError { throw ProtocolError(code: .internal, message: "design engine: seeding failed: \(r.texts.joined(separator: "\n"))") }
                }
                // ponytail: an adopted file whose library is already out unchanged is refused "no changes to publish"
                // (the server's version can't be read back); edit it and create again
                return try await Self.publish(c, deadline)
            }
        } else {
            version = 1   // the copy's library, published by `create` itself
        }
        guard let fileId = UUID(uuidString: f.id), let view = f.viewLink else {
            throw ProtocolError(code: .internal, message: "design engine: no view link for '\(name)'")
        }
        let ds = DesignSystem(id: UUID(), name: name, fileId: fileId, viewLink: view, version: version, createdAt: Date())
        let out = try await record(ds, kind: "created", reason: reason, by: by, deadline: deadline)
        let st = store
        _ = try? await UnixSocketClient.offPool { try st.setPending(lower, nil) }   // ponytail: a mark left by a failed clear is harmless (the name is a system now)
        return out
    }

    /// The next version of `name`'s library, from its file's live document; refused when nothing changed. Then taken
    /// by each of `users` (the screen files using it). After a revert the file still shows the newer content: refused
    /// then unless `force` (which publishes the file as it is and clears the mark).
    func publish(name: String, reason: String, by: String, users: [DesignService.File] = [], force: Bool = false,
                 deadline: ContinuousClock.Instant? = nil) async throws -> Outcome {
        let deadline = deadline ?? design.deadline("design.system.publish")
        let lower = name.lowercased()
        try await claim(lower, deadline); defer { busy.remove(lower) }
        var ds = try await system(named: name)
        if let v = ds.reverted, !force {
            throw ProtocolError(code: .invalidArgs, message: "design system '\(ds.name)' was reverted to v\(v), but its file still shows the newer content — edit the file back to v\(v), or publish with --force to publish it as it is")
        }
        ds.reverted = nil
        ds.version = try await design.onSystemClient(ds.fileId.uuidString.lowercased(), deadline: deadline) { c, deadline throws(ProtocolError) in
            try await DesignService.settle(c, deadline)
            // another client's edit may still be on its way: "no changes" is believed after 2 s of asking
            let giveUp = ContinuousClock.now + .seconds(2)
            while true {
                do throws(ProtocolError) { return try await Self.publish(c, deadline) } catch {
                    guard error.message == "no changes to publish", ContinuousClock.now < giveUp else { throw error }
                }
                try? await Task.sleep(for: .milliseconds(200))
                try await DesignService.sync(c, deadline)
            }
        }
        return try await record(ds, kind: "published", reason: reason, by: by, deadline: deadline, users: users)
    }

    /// Snapshot `v<version>` of `name` published again as its next version (its file's live document is left as it
    /// is), then taken by each of `users`. Marked `reverted` unless `version` is what the file was last published as
    /// (its content is the library's again).
    func revert(name: String, to version: Int, reason: String, by: String, users: [DesignService.File],
                deadline: ContinuousClock.Instant? = nil) async throws -> Outcome {
        let deadline = deadline ?? design.deadline("design.system.revert")
        let lower = name.lowercased()
        try await claim(lower, deadline); defer { busy.remove(lower) }
        var ds = try await system(named: name)
        let src = store.dir(ds.id).appendingPathComponent("v\(version).figcraft")
        guard try await UnixSocketClient.offPool({ FileManager.default.fileExists(atPath: src.path) }) else {
            throw ProtocolError(code: .notFound, message: "design system '\(ds.name)' has no snapshot of version \(version)")
        }
        let r: JSONValue
        do { r = try await design.republish(src, to: ds.fileId.uuidString.lowercased(), deadline: deadline) }
        catch let e as ProtocolError where e.message.contains("no changes to publish") {
            throw ProtocolError(code: .invalidArgs, message: "no changes to publish: version \(version) is the current one")
        }
        ds.version = try Self.version(r)
        // ponytail: the live file can't be replaced from the snapshot in its session (versions aren't shared there,
        // and no command swaps a document's content keeping its ids): marked, so a publish needs --force. The file's
        // version is its last publish from the live document (created or published); unpublished edits since aren't seen
        let id = ds.id
        let fileVersion = try await UnixSocketClient.offPool { [store] in
            store.history(id).last { ["created", "published"].contains($0.kind) }?.version
        }
        ds.reverted = fileVersion == version ? nil : version
        let out = "v\(ds.version).figcraft", store = store
        return try await record(ds, kind: "reverted", reason: reason, by: by, deadline: deadline, users: users) {
            let dst = try store.folder(ds.id).appendingPathComponent(out)
            guard try await UnixSocketClient.offPool({ (try? FileManager.default.copyItem(at: src, to: dst)) != nil }) else {
                throw ProtocolError(code: .internal, message: "design: cannot copy the snapshot")
            }
            return out
        }
    }

    // MARK: active systems

    /// The design files that are systems (or a system's create left half-way): never a screen file of any scope.
    func systemFileIds() async throws -> Set<String> {
        let st = store
        return Set(try await registry().map { $0.fileId.uuidString.lowercased() } + (try await UnixSocketClient.offPool { st.pending() }).values.map(\.fileId))
    }

    /// `ds`'s library enabled in each of `files` (`library.add` by its view link), every other design system's library
    /// there swapped for it (`library.swap`), all in one batch per file: all or nothing in that file, while one file's
    /// failure leaves the others as they are. Within `deadline`, shared between the files. Another system's library is
    /// told by its link (any port), else by its name (a copy published before it was renamed shows its source's).
    func apply(_ ds: DesignSystem, to files: [DesignService.File], deadline: ContinuousClock.Instant) async -> [FileOutcome] {
        let all = (try? await registry()) ?? []
        let others = Set(all.filter { $0.id != ds.id }.map { $0.name.lowercased() })
        let otherLinks = Set(all.filter { $0.id != ds.id }.map { Self.unhosted($0.viewLink) }), own = Self.unhosted(ds.viewLink)
        let label = "Design system \(ds.name)"
        return await each(files, ds, deadline) { c, view, dl throws(ProtocolError) in
            try await DesignService.sync(c, dl)
            let list = try await c.command("library.list", [:], timeout: try DesignService.left(dl))
            let old: [JSONValue] = Self.rows(Self.field(list, "libraries")).compactMap { l in
                let path = if case .string(let p)? = Self.field(l, "path") { Self.unhosted(p) } else { "" }
                let name = if case .string(let n)? = Self.field(l, "name") { n.lowercased() } else { "" }
                guard path != own, otherLinks.contains(path) || others.contains(name) else { return nil }
                return Self.field(l, "id")
            }
            let add = Self.step("library.add", ["path": .string(view)])
            let swaps = old.map { Self.step("library.swap", ["from": $0, "to": .object(["$step": .number(0)])]) }
            // the client may hold an older copy of the new library: `library.updates` fetches it again
            let results = try await Self.batch(c, [add, Self.step("library.updates", [:])] + swaps, label, dl)
            let unmatched = results.dropFirst(2).flatMap { Self.rows(Self.field($0, "unmatched")).compactMap { if case .string(let u) = $0 { u } else { nil } } }
            return (old.isEmpty ? "added" : "swapped", unmatched)
        }
    }

    /// A link without its `host=` (the server's port moves between daemon runs).
    static func unhosted(_ link: String) -> String { link.replacing(/([?&])host=[^&]*/) { "\($0.1)" } }

    /// `ds`'s current version taken by each of `files` (`library.acceptUpdates`), as `apply` shares out `deadline`.
    func propagate(_ ds: DesignSystem, to files: [DesignService.File], deadline: ContinuousClock.Instant) async -> [FileOutcome] {
        let label = "Design system \(ds.name) v\(ds.version)"
        return await each(files, ds, deadline) { c, view, dl throws(ProtocolError) in
            // added again by its current link (the stored one may name an earlier server port), fetched fresh, taken
            _ = try await Self.batch(c, [Self.step("library.add", ["path": .string(view)]), Self.step("library.updates", [:]),
                                         Self.step("library.acceptUpdates", ["ids": .array([.object(["$step": .number(0)])])])], label, dl)
            return ("v\(ds.version)", [])
        }
    }

    // MARK: agent wrappers

    /// `design.system.<verb>` for an agent, on `ds` (the file's effective system, picked by the daemon). The
    /// `library.*` params are built from validated fields only: nothing the agent sends becomes `library`, `server` or
    /// `path`. Edits run on the caller's own client of the panel's file (its undo) as one batch: the library added
    /// again by its current link (heals an old server port), fetched fresh (clients cache libraries), then the command.
    /// `tokens` reads on the daemon's client and returns the library's published assets, without its id or link.
    func wrapped(_ command: String, _ a: [String: JSONValue], ds: DesignSystem, panel: Panel, file: String,
                 caller: (key: String, name: String)) async throws -> JSONValue {
        let step = command == "design.system.tokens" ? nil : try Self.wrapperStep(command, a)   // validated first
        let view = try await design.current(ds.viewLink)
        let add = Self.step("library.add", ["path": .string(view)]), fresh = Self.step("library.updates", [:])
        if command == "design.system.tokens" {
            let tokens = try await design.onSystemClient(file, deadline: design.deadline(command)) { c, dl throws(ProtocolError) in
                try await DesignService.sync(c, dl)
                let r = try await Self.batch(c, [add, Self.step("library.list", ["assets": .bool(true)])], "Design system \(ds.name)", dl)
                let id = Self.field(r.first, "id")
                guard case .object(let lib)? = Self.rows(Self.field(r.last, "libraries")).first(where: { Self.field($0, "id") == id }) else {
                    throw ProtocolError(code: .internal, message: "design engine: the library of '\(ds.name)' is not listed")
                }
                // the library's id, path (its link) and server status left out
                return JSONValue.object(lib.filter { ["name", "version", "description", "collections", "variables", "styles", "components"].contains($0.key) })
            }
            return await design.scrubbed(tokens)   // as a caller's client's results: links, keys and the daemon's secrets hidden
        }
        guard let (cmd, p) = step else { return .null }
        var params = p; params["library"] = .object(["$step": .number(0)])
        return try await design.onCallerClient(command, panel: panel, caller: caller) { c, dl throws(ProtocolError) in
            try await DesignService.sync(c, dl)
            let r = try await Self.batch(c, [add, fresh, Self.step(cmd, params)], "Design system \(ds.name): \(cmd)", dl)
            return r.last ?? .null
        }
    }

    /// The `library.*` command and params (all but `library`) of a wrapper, from the agent's fields.
    static func wrapperStep(_ command: String, _ a: [String: JSONValue]) throws(ProtocolError) -> (String, [String: JSONValue]) {
        switch command {
        case "design.system.bind":
            try DesignService.refuseLinkField(a["field"])
            return ("library.bindVariable", ["variable": try name(a, "variable"), "field": try name(a, "field"), "ids": (try ids(a, required: true) ?? .null)])
        case "design.system.style":
            var p: [String: JSONValue] = ["style": try name(a, "style"), "ids": (try ids(a, required: true) ?? .null)]
            if let t = a["target"] {
                guard case .string(let s) = t, ["fill", "stroke", "text", "effect"].contains(s) else {
                    throw ProtocolError(code: .invalidArgs, message: "'target' must be fill|stroke|text|effect")
                }
                p["target"] = t
            }
            return ("library.applyStyle", p)
        case "design.system.place":
            var p: [String: JSONValue] = ["component": try name(a, "component")]
            for k in ["x", "y"] { if let n = try number(a, k) { p[k] = .number(n) } }
            return ("library.place", p)
        case "design.system.mode":
            // ponytail: one collection per system (the seed's `Tokens`) unless --collection names another
            var p: [String: JSONValue] = ["collection": a["collection"] == nil ? .string("Tokens") : try name(a, "collection"), "mode": try name(a, "mode")]
            if let ids = try ids(a, required: false) { p["ids"] = ids }
            return ("library.setVariableMode", p)
        default:
            throw ProtocolError(code: .invalidArgs, message: "Unknown command '\(command)'")
        }
    }

    /// A name (of a variable, style, component, collection, mode or field): 1-200 characters, no control characters.
    private static func name(_ a: [String: JSONValue], _ k: String) throws(ProtocolError) -> JSONValue {
        guard case .string(let s)? = a[k] else { throw ProtocolError(code: .invalidArgs, message: "Missing argument '\(k)'") }
        guard (1...200).contains(s.count), !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ProtocolError(code: .invalidArgs, message: "'\(k)' must be 1-200 characters")
        }
        return .string(s)
    }

    /// `ids`: comma-separated layer ids as design.inspect shows them (figcraft's are unsigned integers), at most 1000.
    private static func ids(_ a: [String: JSONValue], required: Bool) throws(ProtocolError) -> JSONValue? {
        guard case .string(let s)? = a["ids"] else {
            if required { throw ProtocolError(code: .invalidArgs, message: "Missing argument 'ids'") }
            return nil
        }
        let parts = s.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let ids = parts.compactMap { p in p.allSatisfy(\.isASCII) ? UInt64(p) : nil }.filter { $0 < 1 << 53 }
        guard !parts.isEmpty, parts.count <= 1000, ids.count == parts.count else {
            throw ProtocolError(code: .invalidArgs, message: "'ids' must be 1-1000 comma-separated layer ids")
        }
        return .array(ids.map { .number(Double($0)) })
    }

    /// A finite page coordinate (|n| ≤ 1e7), when given.
    private static func number(_ a: [String: JSONValue], _ k: String) throws(ProtocolError) -> Double? {
        let n: Double?
        switch a[k] {
        case nil, .null?: return nil
        case .number(let v)?: n = v
        case .string(let s)?: n = Double(s)
        default: n = nil
        }
        guard let n, n.isFinite, abs(n) <= 1e7 else { throw ProtocolError(code: .invalidArgs, message: "'\(k)' must be a finite number") }
        return n
    }

    /// An activation (`activated`) or an undo (`undone`; `reverted` with a scope in older histories) of `ds` in `scope` (`floorId`: a floor's), in its history.
    func logActivation(_ ds: DesignSystem, kind: String, scope: String, floorId: UUID?, by: String, reason: String,
                       files: [FileOutcome]) async throws {
        try await append(DesignSystemEvent(at: Date(), kind: kind, version: ds.version, scope: scope, by: by, reason: reason,
                                           snapshot: nil, files: files, floorId: floorId), to: ds.id)
    }

    /// The system most recently made active in the workspace (`floorId` nil) or on floor `floorId`, other than
    /// `current`: what an undo goes back to.
    func previous(floorId: UUID?, current: UUID?) async throws -> DesignSystem? {
        let all = try await registry().filter { $0.id != current }, store = store
        let hits = try await UnixSocketClient.offPool {
            all.flatMap { ds in
                store.history(ds.id).filter { e in
                    // a scope's events only (a version revert has no scope)
                    ["activated", "undone", "reverted"].contains(e.kind) && (floorId.map { e.floorId == $0 } ?? (e.scope == "workspace"))
                }.map { ($0.at, ds.id) }
            }.max { $0.0 < $1.0 }?.1
        }
        return all.first { $0.id == hits }
    }

    private func append(_ e: DesignSystemEvent, to id: UUID) async throws {
        let store = store
        try await UnixSocketClient.offPool { try store.append(e, to: id) }
    }

    /// `body` on the daemon's client of each file in turn, each within its share of `deadline` (at least 15 s, or what
    /// is left); once it is gone, the files left fail "timeout" (one that timed out: "timeout (may have applied)"). `body` gets `ds`'s view link aimed at the current server.
    private func each(_ files: [DesignService.File], _ ds: DesignSystem, _ deadline: ContinuousClock.Instant,
                      _ body: @escaping @Sendable (MCPStdioClient, String, ContinuousClock.Instant) async throws(ProtocolError) -> (String, [String]))
        async -> [FileOutcome] {
        guard !files.isEmpty else { return [] }
        let view: String
        do { view = try await design.current(ds.viewLink) } catch {
            return files.map { FileOutcome(file: $0.name, ok: false, detail: Self.detail(error)) }
        }
        var out: [FileOutcome] = []
        for (i, f) in files.enumerated() {
            let left = deadline - .now
            guard left > .zero else { out.append(FileOutcome(file: f.name, ok: false, detail: "timeout")); continue }
            let mine = min(deadline, .now + max(left / (files.count - i), .seconds(15)))
            do {
                let (detail, unmatched) = try await design.onSystemClient(f.id, deadline: mine) { c, dl throws(ProtocolError) in
                    try await body(c, view, dl)
                }
                out.append(FileOutcome(file: f.name, ok: true, detail: detail, unmatched: unmatched.isEmpty ? nil : unmatched))
            } catch {
                out.append(FileOutcome(file: f.name, ok: false, detail: Self.detail(error)))
            }
        }
        return out
    }

    private static func detail(_ e: any Error) -> String {
        guard let p = e as? ProtocolError else { return "\(e)" }
        return p.code == .timeout ? "timeout (may have applied)" : p.message
    }

    private static func step(_ command: String, _ params: [String: JSONValue]) -> JSONValue {
        .object(["command": .string(command), "params": .object(params)])
    }

    private static func rows(_ v: JSONValue?) -> [JSONValue] { if case .array(let a)? = v { a } else { [] } }
    private static func field(_ v: JSONValue?, _ k: String) -> JSONValue? { if case .object(let o)? = v { o[k] } else { nil } }

    /// One `batch` (all or nothing): its steps' results.
    private static func batch(_ c: MCPStdioClient, _ steps: [JSONValue], _ label: String,
                              _ deadline: ContinuousClock.Instant) async throws(ProtocolError) -> [JSONValue] {
        let r = try await c.result("batch", ["commands": .array(steps), "label": .string(label)], timeout: try DesignService.left(deadline))
        let text = r.texts.joined(separator: "\n")
        if r.isError { throw ProtocolError(code: .internal, message: "design engine: \(text.isEmpty ? "the batch failed" : text)") }
        return rows(try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))
    }

    // MARK: helpers

    /// Waits (within `deadline`) for no create, publish or revert of `lower` to be in flight, then holds it.
    private func claim(_ lower: String, _ deadline: ContinuousClock.Instant) async throws {
        while busy.contains(lower) {
            guard ContinuousClock.now < deadline else { throw ProtocolError(code: .timeout, message: "design system '\(lower)' is busy") }
            try? await Task.sleep(for: .milliseconds(100))
        }
        busy.insert(lower)
    }

    private func registry() async throws -> [DesignSystem] {
        if let systems { return systems }
        let st = store
        let all = try await UnixSocketClient.offPool { try st.load() }
        systems = all
        await design.hide(all.map(\.viewLink))
        return all
    }

    /// `library.publishToServer` in the file's session (edit access): the server's new version. The engine refuses a
    /// publish with nothing changed since the last one.
    private static func publish(_ c: MCPStdioClient, _ deadline: ContinuousClock.Instant) async throws(ProtocolError) -> Int {
        let r: JSONValue
        do throws(ProtocolError) { r = try await c.command("library.publishToServer", [:], timeout: try DesignService.left(deadline)) }
        catch where error.message.contains("no changes to publish") { throw ProtocolError(code: .invalidArgs, message: "no changes to publish") }
        return try version(r)
    }

    /// The version in a publish answer.
    private static func version(_ r: JSONValue) throws(ProtocolError) -> Int {
        guard case .object(let o) = r, case .number(let v)? = o["version"], v >= 1 else {
            throw ProtocolError(code: .internal, message: "design engine: no version in the publish answer")
        }
        return Int(v)
    }

    /// A version that is out: registered and in the history whatever happens to its snapshot (saved first, within
    /// `deadline`, by `snapshot` or else from the file; its failure is reported, not thrown), then taken by `users`.
    private func record(_ ds: DesignSystem, kind: String, reason: String, by: String, deadline: ContinuousClock.Instant,
                        users: [DesignService.File] = [], snapshot: (() async throws -> String)? = nil) async throws -> Outcome {
        var snap: String?, snapshotError: String?
        do { snap = if let snapshot { try await snapshot() } else { try await self.snapshot(ds, deadline) } } catch {
            snapshotError = (error as? ProtocolError)?.message ?? "\(error)"
        }
        var all = try await registry()
        if let i = all.firstIndex(where: { $0.id == ds.id }) { all[i] = ds } else { all.append(ds) }
        let st = store, saved = all
        try await UnixSocketClient.offPool { try st.save(saved) }
        systems = all
        let files = await propagate(ds, to: users, deadline: deadline)
        try await append(DesignSystemEvent(at: Date(), kind: kind, version: ds.version, scope: nil, by: by, reason: reason,
                                           snapshot: snap, files: files), to: ds.id)
        return (ds, snapshotError, files)
    }

    /// The file as it is now, saved as `v<version>.figcraft` in the system's folder; its file name.
    private func snapshot(_ ds: DesignSystem, _ deadline: ContinuousClock.Instant) async throws -> String {
        let name = "v\(ds.version).figcraft", out = try store.folder(ds.id).appendingPathComponent(name)
        _ = try await design.onSystemClient(ds.fileId.uuidString.lowercased(), deadline: deadline) { c, deadline throws(ProtocolError) in
            try await c.command("file.save", ["path": .string(out.path)], timeout: try DesignService.left(deadline))
        }
        guard try await UnixSocketClient.offPool({ FileManager.default.fileExists(atPath: out.path) }) else {
            throw ProtocolError(code: .internal, message: "design engine: the snapshot was not saved")
        }
        return name
    }

    /// The file has a `Tokens` variable collection (an earlier seed got through).
    private static func hasTokens(_ c: MCPStdioClient, _ deadline: ContinuousClock.Instant) async throws(ProtocolError) -> Bool {
        let r = try await c.command("variable.list", [:], timeout: try DesignService.left(deadline))
        guard case .object(let o) = r, case .array(let cols)? = o["collections"] else { return false }
        return cols.contains { if case .object(let c) = $0 { c["name"] == .string("Tokens") } else { false } }
    }

    // MARK: seed

    /// Light / Dark values (from the 2026-10-20 figcraft spike's portfolio tokens).
    static let colors: [(String, String, String)] = [
        ("bg", "#FAFAF7", "#111317"), ("surface", "#FFFFFF", "#1B1E24"), ("text", "#16181D", "#ECEDEF"),
        ("muted", "#5B616E", "#9AA1AD"), ("accent", "#2F6F4F", "#7BD3A2"),
    ]
    static let numbers: [(String, Double)] = [
        ("space/s", 8), ("space/m", 16), ("space/l", 32), ("space/xl", 64), ("radius/card", 12),
        ("type/body", 16), ("type/h3", 20), ("type/h2", 28), ("type/h1", 48),
    ]

    /// One batch: collection `Tokens` (Light, Dark) with the variables above, text style `Heading` (size bound to
    /// `type/h2`) and component `Button` (auto layout, `accent` fill, `radius/card` corners, a text label).
    static let seed: [JSONValue] = {
        var steps: [JSONValue] = []
        func add(_ command: String, _ params: [String: JSONValue]) -> JSONValue {
            steps.append(.object(["command": .string(command), "params": .object(params)]))
            return .object(["$step": .number(Double(steps.count - 1))])
        }
        let col = add("variable.createCollection", ["name": .string("Tokens"), "modes": .array([.string("Light"), .string("Dark")])])
        var v: [String: JSONValue] = [:]
        for (n, light, dark) in colors {
            v[n] = add("variable.create", ["collection": col, "name": .string(n), "type": .string("color"),
                                           "values": .object(["Light": .string(light), "Dark": .string(dark)])])
        }
        for (n, x) in numbers {
            v[n] = add("variable.create", ["collection": col, "name": .string(n), "type": .string("number"),
                                           "values": .object(["Light": .number(x), "Dark": .number(x)])])
        }
        func bind(_ node: JSONValue, _ field: String, _ variable: String) {
            _ = add("variable.bind", ["ids": .array([node]), "field": .string(field), "variable": v[variable] ?? .null])
        }
        // the style is defined from a text layer, which then goes
        let sample = add("node.create", ["type": .string("text"), "text": .string("Heading"), "name": .string("Heading")])
        bind(sample, "fontSize", "type/h2")
        let style = add("style.create", ["type": .string("text"), "name": .string("Heading"), "from": sample])
        _ = add("style.bind", ["style": style, "field": .string("fontSize"), "variable": v["type/h2"] ?? .null])
        _ = add("edit.delete", ["ids": .array([sample])])
        let button = add("node.create", ["type": .string("component"), "name": .string("Button"), "props": .object([
            "layout": .string("horizontal"), "sizingH": .string("hug"), "sizingV": .string("hug"),
            "fills": .array([.object(["type": .string("solid"), "color": .string("#2F6F4F")])]),
        ])])
        for (field, variable) in [("fill", "accent"), ("cornerRadius", "radius/card"), ("paddingLeft", "space/m"),
                                  ("paddingRight", "space/m"), ("paddingTop", "space/s"), ("paddingBottom", "space/s")] {
            bind(button, field, variable)
        }
        let label = add("node.create", ["type": .string("text"), "text": .string("Button"), "name": .string("Label"), "parent": button])
        bind(label, "fill", "surface")
        bind(label, "fontSize", "type/body")
        return steps
    }()
}
