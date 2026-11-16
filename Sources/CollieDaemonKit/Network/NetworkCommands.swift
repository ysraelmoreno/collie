import Foundation
import CollieCore
import CollieProtocol
import CollieNetwork

extension CommandRouter {
    /// A `network.*` command, run by the daemon. The leash is the permission, as for `device.*`: a terminal must reach a
    /// network panel (captured traffic carries tokens and cookies); the app (admin) needs none. The commands are
    /// panel-free otherwise (panels are not bound to a serial): `--serial`, else the only emulator online (attach) or the
    /// only one being captured (the rest).
    func networkCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        let caller = try await principal(r, peer: peer)   // nil = admin
        if let me = caller, !ConnectionGraph.reachablePanels(from: me.id, in: ws).contains(where: { $0.pluginId == "network" }) {
            throw ProtocolError(code: .notFound, message: "No network panel reachable. Open one with `panel open network`.")
        }
        if r.command.hasPrefix("network.rule-") { return try await networkRuleCommand(r, caller: caller) }
        if r.command == "network.status", str(r, "serial") == nil, await network.attached.isEmpty {
            return .object(["attached": .bool(false)])
        }
        let serial = try await networkSerial(r)
        switch r.command {
        case "network.attach": return try await network.attach(serial)
        case "network.detach": return try await network.detach(serial)
        case "network.status": return await network.status(serial)
        case "network.list":
            return try await network.list(serial, limit: try DeviceService.int(r.args, "limit", 1...10_000) ?? 100, host: str(r, "host"))
        case "network.get": return try await network.get(serial, id: try flowId(r))
        case "network.curl": return try await network.curl(serial, id: try flowId(r))
        case "network.clear": return try await network.clear(serial)
        default: throw ProtocolError(code: .invalidArgs, message: "Unknown command '\(r.command)'")
        }
    }

    /// `network.rule-*`: the map rules, global (no serial, except `rule-add --from`, whose flow is on one).
    private func networkRuleCommand(_ r: Request, caller: TerminalRecord?) async throws -> JSONValue {
        let rules = network.rules
        switch r.command {
        case "network.rule-add":
            var body: Data?
            if let path = str(r, "body-file") { body = try await ruleBodyFile(path, r, caller: caller) }
            let serial = str(r, "from") != nil ? try await networkSerial(r) : nil
            var rule = try await network.makeRule(r.args, bodyFile: body, serial: serial)
            let wanted = rule.enabled
            if caller != nil { rule.enabled = false }   // a terminal's rule is born off; only the card turns it on
            rule = try await rules.add(rule)
            if let me = caller, wanted { try await approveRule(rule, by: me) }
            return NetworkService.ruleJSON(try await rules.rule(rule.id))
        case "network.rule-list": return await network.ruleList()
        case "network.rule-remove": try await rules.remove(try need(r, "id")); return .object([:])
        case "network.rule-enable", "network.rule-disable":
            let id = try need(r, "id")
            let on = r.command == "network.rule-enable"
            if on, let me = caller, !(try await rules.rule(id).enabled) { try await approveRule(try await rules.rule(id), by: me) }
            try await rules.setEnabled(id, on)
            return NetworkService.ruleJSON(try await rules.rule(id))
        case "network.rule-clear": await rules.clear(); return .object([:])
        default: throw ProtocolError(code: .invalidArgs, message: "Unknown command '\(r.command)'")
        }
    }

    /// A terminal's rule turns on only with the user's Permitir on a card (the apps' `confirm` card); Negar or no
    /// answer: it stays off and the call is refused.
    private func approveRule(_ rule: MapRule, by me: TerminalRecord) async throws {
        let card = AppCard(kind: .confirm, paddock: me.paddockId ?? UUID(), paddockName: ws.paddocks.first { $0.id == me.paddockId }?.name ?? "",
                           app: "network", name: "Rede", base: nil, call: String(Self.cardText(rule).prefix(300)), command: "rule", by: me.id)
        guard await confirmCard(card, wait: config.ruleCardWait) else {
            throw ProtocolError(code: .unauthorized, message: "the user did not allow map rule '\(rule.id)'; it stays off (network.rule-list)")
        }
        try await network.rules.setEnabled(rule.id, true)
    }

    /// Two lines, as the card shows them: the request ("GET api.example.com/pdp") and the response ("418 · 2 KB · atraso 300 ms").
    static func cardText(_ r: MapRule) -> String {
        let m = r.match
        let query = m.query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        let target = m.isEmpty ? "qualquer requisição"
            : (m.method.map { $0 + " " } ?? "") + (m.host ?? "*") + (m.path ?? "") + (query.isEmpty ? "" : "?" + query)
        let delay = r.delayMs > 0 ? " · atraso \(r.delayMs) ms" : ""
        switch r.action {
        case .drop: return target + "\nqueda (corta a conexão)" + delay
        case .local(let status, _, _):
            let n = r.body?.count ?? 0
            return target + "\n\(status) · " + (n == 0 ? "sem corpo" : "\(max(1, Int((Double(n) / 1024).rounded()))) KB") + delay
        }
    }

    /// `--body-file`, read by the daemon at creation (the addon never reads a path). A terminal reads only inside its
    /// project and never what the sandbox never opens (Collie's data, secrets); the app anywhere. Both: at most 5 MiB.
    private func ruleBodyFile(_ path: String, _ r: Request, caller: TerminalRecord?) async throws -> Data {
        let base = URL(fileURLWithPath: r.cwd ?? caller?.cwd ?? NSHomeDirectory(), isDirectory: true)
        let real = SignedAppCheck.realPath(URL(fileURLWithPath: path, relativeTo: base).absoluteURL)
        var check: (@Sendable (String) -> Bool)?
        if let me = caller {
            let root = try await projectRoot(of: me), home = sandboxHomeDir, collie = config.paths.root
            check = { p in ProjectRoot.contains(p, root: root) && SandboxGrantStore.readRefusal(p, home: home, collie: collie) == nil }
            guard check!(real) else {
                throw ProtocolError(code: .unauthorized, message: "--body-file must be inside your project (\(root.path)): copy it there first")
            }
        }
        let allowed = check
        // off the actor: a slow disk must not hold every other command
        return try await Task.detached { () throws(ProtocolError) -> Data in try Self.readBodyFile(real, allowed: allowed) }.value
    }

    /// Reads a regular file of at most 5 MiB through one fd: no symlink followed (O_NOFOLLOW), never blocks on a FIFO
    /// (O_NONBLOCK + S_ISREG), and for a terminal (`allowed`) the opened file itself must still be inside its project
    /// (F_GETPATH: a swap after the path check is caught) and have one link (a hard link to a file outside is refused).
    static func readBodyFile(_ path: String, allowed: (@Sendable (String) -> Bool)?) throws(ProtocolError) -> Data {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let e = errno
            throw e == ELOOP ? ProtocolError(code: .unauthorized, message: "--body-file may not be a symlink")
                : ProtocolError(code: .notFound, message: "Cannot read \(path): \(String(cString: strerror(e)))")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            throw ProtocolError(code: .invalidArgs, message: "--body-file must be a regular file")
        }
        if let allowed {
            var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard st.st_nlink == 1, fcntl(fd, F_GETPATH, &buf) == 0, allowed(String(cString: buf)) else {
                throw ProtocolError(code: .unauthorized, message: "--body-file must be a file of your project (no hard links)")
            }
        }
        guard st.st_size <= MapRule.maxBody else { throw ProtocolError(code: .invalidArgs, message: MapRuleError.bodyTooLarge(Int(st.st_size)).message) }
        var data = Data(), chunk = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let n = read(fd, &chunk, chunk.count)
            guard n >= 0 else { throw ProtocolError(code: .notFound, message: "Cannot read \(path): \(String(cString: strerror(errno)))") }
            if n == 0 { return data }
            data.append(chunk, count: n)
            guard data.count <= MapRule.maxBody else { throw ProtocolError(code: .invalidArgs, message: MapRuleError.bodyTooLarge(data.count).message) }
        }
    }

    private func flowId(_ r: Request) throws(ProtocolError) -> String {
        guard let id = str(r, "id"), !id.isEmpty else { throw ProtocolError(code: .invalidArgs, message: "Missing argument 'id'") }
        return id
    }

    private func networkSerial(_ r: Request) async throws(ProtocolError) -> String {
        if let s = str(r, "serial"), !s.isEmpty { return s }
        let candidates = r.command == "network.attach"
            ? try await devices.devices().filter { $0.state == "device" && $0.serial.hasPrefix("emulator-") }.map(\.serial)
            : await network.attached
        switch candidates.count {
        case 1: return candidates[0]
        case 0: throw ProtocolError(code: .invalidArgs, message: r.command == "network.attach" ? "No emulator online" : "No emulator is being captured")
        default: throw ProtocolError(code: .ambiguous, message: "Several emulators (\(candidates.joined(separator: ", "))); pass --serial")
        }
    }

    /// A network event for `serial`, to every network panel (panels are not bound to a serial: the payload names it).
    func networkEmitted(serial: String, name: String, payload: JSONValue) async {
        for p in ws.panels where p.pluginId == "network" {
            await pluginEmitted(panel: p.id, name: name, payload: payload)
        }
    }

    /// The last network panel closed: every capture stops and its device is restored (in the background: closing a
    /// panel must not wait on adb). Captures the app started with no panel open are left alone.
    func networkPanelClosed(_ p: Panel) async {
        guard !ws.panels.contains(where: { $0.pluginId == "network" }) else { return }
        let network = network, serials = await network.attached   // these, not whatever is attached when the task runs
        Task { for s in serials { _ = try? await network.detach(s) } }
    }
}
