import Foundation
import CryptoKit
import CollieCore
import CollieProtocol
import CollieTerminal

/// What a paired phone may call (remote API spec §3): an allowlist, never `admin.*`. Each entry is read or mutating;
/// a `read` device is refused every mutating one (checked against the store on every message: a scope change applies
/// at once). Everything else answers "Unknown command", like a command that doesn't exist.
enum RemoteSurface {
    enum Kind: Sendable { case read, mutating }
    static let commands: [String: Kind] = [
        "workspace.snapshot": .read, "terminal.screen": .read, "work.list": .read, "work.get": .read, "work.summary": .read,
        "approvals.list": .read, "access.cards": .read, "chat.history": .read, "artifact.list": .read, "artifact.get": .read,
        "events.subscribe": .read, "events.unsubscribe": .read,   // handled by the session itself
        // behind the scope gate already; their handlers come in slices 7-8
        "approval.answer": .mutating, "approval.dismiss": .mutating, "access.grant": .mutating, "access.deny": .mutating,
        "agent.ask": .mutating, "work.rerail": .mutating, "mac.reveal": .mutating,
    ]

    /// The card's stable id: its dedup key (terminal, op, folder) hashed — same card, same id across updates.
    static func cardId(_ d: SandboxDenial) -> String {
        let h = SHA256.hash(data: Data("\(d.terminal.uuidString.lowercased())|\(d.op)|\(d.folder)".utf8))
        return Data(h.prefix(16)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// The remote principal's requests: explicit projections (fields picked one by one, never a record dumped), so no
/// token, path of Collie's own, cwd or command leaves the Mac.
extension CommandRouter {
    func remoteRequest(_ r: Request, device: RemoteDevice, via: RemoteVia) async -> Response {
        do { return Response(id: r.id, ok: true, result: try await remoteRead(r, device: device, via: via)) }
        catch let e as ProtocolError { return Response(id: r.id, ok: false, error: e) }
        catch { return Response(id: r.id, ok: false, error: ProtocolError(code: .internal, message: "\(error)")) }
    }

    private func remoteRead(_ r: Request, device: RemoteDevice, via: RemoteVia) async throws -> JSONValue {
        switch r.command {
        case "workspace.snapshot":
            let closed = Int(try num(r, "closedWorks", max: 100) ?? 20), arts = Int(try num(r, "artifacts", max: 200) ?? 50)
            let terminalIds = Set(ws.terminals.map(\.id))
            var o: [String: JSONValue] = [
                "mac": .object(["name": .string(Self.computerName()), "installId": .string((try? remoteInstallId()) ?? ""),
                                "collieVersion": .string(config.version ?? "dev"), "build": .string(config.build ?? "dev"), "keyFingerprint": .string(remoteIdentity?.fingerprint ?? ""),
                                "via": .string(via.rawValue), "pairedAt": .string(device.pairedAt.ISO8601Format())]),
                "paddocks": .array(ws.paddocks.map(remotePaddock)),
                "lots": .array(ws.lots.map(remoteLot)),
                "leashes": .array(ws.connections.filter { terminalIds.contains($0.a) && terminalIds.contains($0.b) }.map { c in
                    .object(["a": .string(c.a.uuidString.lowercased()), "b": .string(c.b.uuidString.lowercased())]) }),
            ]
            var terms: [JSONValue] = []
            for t in ws.terminals { terms.append(try await remoteTerminal(t)) }
            o["terminals"] = .array(terms)
            o["approvals"] = remoteApprovals(await asks.approvals())
            o["accessCards"] = .array(accessCards.all.map(remoteCard))
            let all = try await work.list(includeClosed: true)
            let open = all.filter { $0.closedAt == nil }
            let done = all.filter { $0.closedAt != nil }.sorted { $0.closedAt! > $1.closedAt! }.prefix(closed)
            o["works"] = .array((open + done).map(remoteWorkRow))
            o["artifacts"] = .array(try await artifacts.list().sorted { $0.at > $1.at }.prefix(arts).map(remoteArtifact))
            return .object(o)
        case "terminal.screen":
            let t = try remoteTerminalRecord(r)
            let lines = Int(try num(r, "lines", max: 500) ?? 200)
            // the rendered screen (its last `lines` rows) while it runs; no renderer (tests) or stopped: the scrollback tail
            if config.screenRenderer != nil, await registry.process(t.id)?.isRunning == true {
                let rows = try await screen(t).split(separator: "\n", omittingEmptySubsequences: false)
                return .object(["text": .string(rows.suffix(lines).joined(separator: "\n")), "truncated": .bool(rows.count > lines)])
            }
            let s = await registry.scrollback(t.id)?.tail(lines: lines) ?? (text: "", truncated: false)
            return .object(["text": .string(ANSI.strip(s.text)), "truncated": .bool(s.truncated)])
        case "work.list":
            return .array(try await work.list(includeClosed: flag(r, "closed")).map(remoteWorkRow))
        case "work.get":
            return try isoJSON(try await remoteWork(r))
        case "work.summary":
            let w = try await remoteWork(r)
            let sum = WorkSummary.make(w, terminalAlive: await registry.process(w.terminalId)?.isRunning == true, now: Date())
            return .object(["markdown": .string(sum.markdown())])
        case "approvals.list":
            return remoteApprovals(await asks.approvals())
        case "access.cards":
            return .object(["cards": .array(accessCards.all.map(remoteCard)),
                            "grants": .array(sandboxGrants.map { g in .object(["id": .string(g.id.uuidString.lowercased()), "path": .string(g.path),
                                "access": .string(g.access.rawValue), "scope": .string(g.scope.rawValue)]) })])
        case "chat.history":
            let before = try str(r, "before").map { s throws(ProtocolError) in
                guard let id = UUID(uuidString: s) else { throw ProtocolError(code: .notFound, message: "Mensagem não encontrada.") }
                return id
            }
            var page = try await chat.page(before: before, limit: Int(try num(r, "limit", max: 200) ?? 50))
            if str(r, "terminal") != nil { let name = try remoteTerminalRecord(r).name; page = page.filter { $0.terminal == name } }
            return try isoJSON(page)
        case "artifact.list":
            return .array(try await artifacts.list().sorted { $0.at > $1.at }.map(remoteArtifact))
        case "artifact.get":
            guard let id = str(r, "id").flatMap(UUID.init(uuidString:)), let a = try await artifacts.list().first(where: { $0.id == id }) else {
                throw ProtocolError(code: .notFound, message: "Artifact não encontrado.")
            }
            return remoteArtifact(a)
        default:   // allowlisted, mutating, past the scope gate: handlers in slices 7-8
            throw ProtocolError(code: .unavailable, message: "'\(r.command)' ainda não está disponível pelo iPhone.")
        }
    }

    func remotePaddock(_ f: Paddock) -> JSONValue {
        .object(["id": .string(f.id.uuidString.lowercased()), "name": .string(f.name),
                 "branch": f.branch.isEmpty ? .null : .string(f.branch), "base": f.baseBranch.isEmpty ? .null : .string(f.baseBranch),
                 "status": .string(f.status.rawValue)])
    }

    func remoteLot(_ l: Lot) -> JSONValue {
        .object(["id": .string(l.id.uuidString.lowercased()), "name": .string(l.name), "members": .array(l.members.map { .string($0.uuidString.lowercased()) })])
    }

    private func remoteTerminalRecord(_ r: Request) throws -> TerminalRecord {
        guard let id = str(r, "terminal").flatMap(UUID.init(uuidString:)), let t = ws.terminals.first(where: { $0.id == id }) else {
            throw ProtocolError(code: .notFound, message: "Terminal não encontrado.")
        }
        return t
    }

    private func remoteWork(_ r: Request) async throws -> Work {
        guard let id = str(r, "id").flatMap(UUID.init(uuidString:)), let w = try await work.get(id) else {
            throw ProtocolError(code: .notFound, message: "Trabalho não encontrado.")
        }
        return w
    }

    private func id(_ u: UUID?) -> JSONValue { u.map { .string($0.uuidString.lowercased()) } ?? .null }

    func remoteTerminal(_ t: TerminalRecord) async throws -> JSONValue {
        let running = await registry.process(t.id)?.isRunning == true
        let badge = running ? (await hub.currentBadges[t.id] ?? .idle) : .stopped
        let shepherd = t.isShepherd ? nil : ConnectionGraph.reachable(from: t.id, in: ws).filter(\.isShepherd)
            .min { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var activity: JSONValue = .null
        if let w = try await work.active(terminal: t.id) {
            let task = w.tasks.first { $0.state == .inProgress } ?? w.tasks.first { $0.state == .open }
            activity = .object(["work": .string(w.title), "task": task.map { .string($0.title) } ?? .null])
        }
        return .object(["id": id(t.id), "name": .string(t.name), "preset": .string(t.preset.rawValue), "paddockId": id(t.paddockId),
                        "isShepherd": .bool(t.isShepherd), "shepherdId": id(shepherd?.id), "shepherd": shepherd.map { .string($0.name) } ?? .null,
                        "running": .bool(running), "badge": .string(badge.rawValue),
                        "badgeSince": .string(await hub.since(t.id).ISO8601Format()),
                        "activity": activity, "sandbox": .string(t.sandbox == .sandboxed ? "sandboxed" : "free"), "lotId": id(ws.lot(of: t.id)?.id)])
    }

    private func paddockName(_ terminal: UUID) -> JSONValue {
        guard let pid = ws.terminals.first(where: { $0.id == terminal })?.paddockId, let f = ws.paddocks.first(where: { $0.id == pid }) else { return .null }
        return .string(f.name)
    }

    func remoteApprovals(_ list: [Approval]) -> JSONValue {
        .array(list.map { a in .object(["id": id(a.id), "terminalId": id(a.terminalId), "terminal": .string(a.terminal),
                                        "paddock": paddockName(a.terminalId), "kind": .string(a.kind.rawValue), "reason": .string(a.reason),
                                        "prompt": .string(a.prompt), "at": .string(a.at.ISO8601Format())]) })
    }

    func remoteCard(_ d: SandboxDenial) -> JSONValue {
        let home = sandboxHomeDir.path
        let agentConfig = [".claude", ".codex", ".cursor", ".claude.json"].contains { d.path == home + "/" + $0 || d.path.hasPrefix(home + "/" + $0 + "/") }
        return .object(["id": .string(RemoteSurface.cardId(d)), "terminalId": id(d.terminal),
                        "terminal": ws.terminals.first { $0.id == d.terminal }.map { .string($0.name) } ?? .null,
                        "paddock": paddockName(d.terminal), "op": .string(d.op), "path": .string(d.path), "folder": .string(d.folder),
                        "count": .number(Double(d.count)), "at": .string(d.at.ISO8601Format()), "requested": .bool(d.requested),
                        "reason": d.reason.map { .string($0) } ?? .null, "refusal": d.refusal.map { .string($0) } ?? .null,
                        "folderRefusal": d.folderRefusal.map { .string($0) } ?? .null, "isAgentConfig": .bool(agentConfig)])
    }

    private func remoteWorkRow(_ w: Work) -> JSONValue {
        func count(_ s: TaskState) -> JSONValue { .number(Double(w.tasks.filter { $0.state == s }.count)) }
        func jobs(_ s: JobState) -> JSONValue { .number(Double(w.jobs.filter { $0.state == s }.count)) }
        return .object(["id": id(w.id), "title": .string(w.title), "terminalId": id(w.terminalId),
                        "terminalName": ws.terminals.first { $0.id == w.terminalId }.map { .string($0.name) } ?? .null,
                        "paddockId": id(w.paddockId), "branch": w.branch.map { .string($0) } ?? .null,
                        "openedAt": .string(w.openedAt.ISO8601Format()), "closedAt": w.closedAt.map { .string($0.ISO8601Format()) } ?? .null,
                        "closedBy": w.closedBy.map { .string($0) } ?? .null, "lastCommit": w.commits.last.map { .string($0) } ?? .null,
                        "tasks": .object(["open": count(.open), "inProgress": count(.inProgress), "done": count(.done),
                                          "deferred": count(.deferred), "abandoned": count(.abandoned)]),
                        "jobs": .object(["running": jobs(.running), "finished": jobs(.finished), "gone": jobs(.gone), "unknown": jobs(.unknown)])])
    }

    private func remoteArtifact(_ a: Artifact) -> JSONValue {
        let key = a.id.uuidString.lowercased()
        // open on the artifact, or on the project page it was added from (`collie artifact new` opens the file)
        let live = ws.panels.contains { p in
            guard p.pluginId == "preview" else { return false }
            if p.state["artifact"] == .string(key) { return true }
            guard let from = a.addedFrom, case .string(let f)? = p.state["file"], case .string(let root)? = p.state["root"],
                  let u = try? PreviewFile.resolve(f, projectRoot: URL(fileURLWithPath: root)) else { return false }
            return SignedAppCheck.realPath(u) == from
        }
        return .object(["id": .string(key), "kind": .string(a.kind.rawValue), "title": .string(a.title), "by": .string(a.by),
                        "at": .string(a.at.ISO8601Format()), "version": .number(Double(a.version)),
                        "folder": a.inFolder.map { .string($0) } ?? .null, "live": .bool(live),
                        "importing": .bool(importingArtifacts.contains(a.id)), "importError": a.importError.map { .string($0) } ?? .null])
    }
}
