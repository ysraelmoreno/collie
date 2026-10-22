import Foundation
import CollieCore
import CollieProtocol

extension Partitura {
    /// What applying it would create, for the confirmation: every terminal with its command and prompt, panels with state, cords.
    var preview: JSONValue {
        .object([
            "terminals": .array(terminals.map { t in
                var o: [String: JSONValue] = ["key": .string(t.key), "preset": .string(t.preset.rawValue), "isMaestro": .bool(t.isMaestro)]
                if let c = t.command { o["command"] = .string(c) }
                if let r = t.role { o["role"] = .string(r) }
                return .object(o)
            }),
            "panels": .array(panels.map { .object(["key": .string($0.key), "pluginId": .string($0.pluginId), "state": .object($0.state)]) }),
            "cords": .array(cords.map { .array($0.map { .string($0) }) }),
            "wantsFloor": .bool(wantsFloor),
        ])
    }
}

extension CommandRouter {
    /// `partitura.*`: the admin token, or a Maestro for list/get/save; remove/import/export are the app's.
    func partituraCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        let caller = try await principal(r, peer: peer)   // nil = admin (the app)
        func invalid(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        if let caller {
            if ["partitura.remove", "partitura.import", "partitura.export"].contains(r.command) {
                throw ProtocolError(code: .unauthorized, message: "'\(r.command)' é só do app")
            }
            guard caller.isMaestro else { throw ProtocolError(code: .notMaestro, message: "'\(r.command)' é só para Maestros") }
        }
        func partitura() async throws -> Partitura {
            let id = try need(r, "id")
            guard let p = await partituras.get(id) else { throw ProtocolError(code: .notFound, message: "partitura '\(id)' não existe") }
            return p
        }
        switch r.command {
        case "partitura.list":
            return .array(await partituras.list().map { p in
                .object(["id": .string(p.id), "name": .string(p.name), "summary": .string(p.summary), "wantsFloor": .bool(p.wantsFloor),
                         "builtIn": .bool(p.builtIn), "terminals": .number(Double(p.terminals.count)), "panels": .number(Double(p.panels.count))])
            })
        case "partitura.get":
            let p = try await partitura()
            guard case .object(var o) = try isoJSON(p) else { throw invalid("partitura: não foi possível codificar") }
            o["builtIn"] = .bool(p.builtIn)
            return .object(o)
        case "partitura.save": return try await savePartitura(r, caller: caller)
        case "partitura.apply": return try await applyPartitura(r, caller: caller)
        case "partitura.remove":
            try await partituras.setAside(try need(r, "id"))
            return .object([:])
        case "partitura.import":
            let raw = Data(try need(r, "json").utf8)
            let p = try PartituraFormat.decode(raw)   // size, format, keys, state, cords: nothing is written when it fails
            if !flag(r, "replace"), let old = await partituras.get(p.id) { throw invalid("já existe uma partitura \(old.name)") }
            try await partituras.put(p)
            return .object(["id": .string(p.id), "preview": p.preview])
        case "partitura.export":
            let p = try await partitura()
            let data = try PartituraFormat.encode(p)
            _ = try PartituraFormat.decode(data)   // what leaves passes what comes in
            return .object(["json": .string(String(decoding: data, as: UTF8.self))])
        default: throw ProtocolError(code: .internal, message: "'\(r.command)' ainda não existe")
        }
    }

    /// A list given as an array of names or one comma-separated string.
    private func names(_ r: Request, _ k: String) -> [String] {
        switch r.args[k] {
        case .array(let a)?: return a.compactMap { if case .string(let s) = $0 { s.trimmingCharacters(in: .whitespaces) } else { nil } }.filter { !$0.isEmpty }
        case .string(let s)?: return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default: return []
        }
    }
    /// An object given as such or as a JSON string.
    private func object(_ r: Request, _ k: String) throws(ProtocolError) -> [String: JSONValue] {
        switch r.args[k] {
        case .object(let o)?: return o
        case .string(let s)?:
            guard case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) else {
                throw ProtocolError(code: .invalidArgs, message: "'\(k)' deve ser um objeto JSON")
            }
            return o
        default: return [:]
        }
    }

    private func savePartitura(_ r: Request, caller: TerminalRecord?) async throws -> JSONValue {
        func invalid(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        let name = try need(r, "name").trimmingCharacters(in: .whitespaces)
        let id = PartituraFormat.slug(name)
        guard !id.isEmpty else { throw invalid("partitura: nome inválido") }
        let termNames = names(r, "terminals"), panelNames = names(r, "panels")
        guard !termNames.isEmpty else { throw invalid("faltou o argumento 'terminals'") }
        // a Maestro: what it reaches by cord plus itself; the app: anything
        let reachT: [TerminalRecord] = caller.map { me in [me] + ConnectionGraph.reachable(from: me.id, in: ws) } ?? ws.terminals
        let reachP: [Panel] = caller.map { ConnectionGraph.reachablePanels(from: $0.id, in: ws) } ?? ws.panels
        func pick<T>(_ n: String, all: [T], reach: [T], name: (T) -> String, kind: String) throws(ProtocolError) -> T {
            let same = { (x: T) in name(x).caseInsensitiveCompare(n) == .orderedSame }
            guard all.contains(where: same) else { throw ProtocolError(code: .notFound, message: "\(kind) '\(n)' não encontrado") }
            let hits = reach.filter(same)
            guard hits.count == 1 else {
                throw ProtocolError(code: hits.isEmpty ? .notConnected : .ambiguous,
                                    message: hits.isEmpty ? "sem corda até '\(n)'; ligue antes" : "mais de um \(kind) chamado '\(n)'")
            }
            return hits[0]
        }
        var terms: [TerminalRecord] = [], panels: [Panel] = []
        for n in termNames { let t = try pick(n, all: ws.terminals, reach: reachT, name: \.name, kind: "terminal"); if !terms.contains(where: { $0.id == t.id }) { terms.append(t) } }
        for n in panelNames { let p = try pick(n, all: ws.panels, reach: reachP, name: \.name, kind: "painel"); if !panels.contains(where: { $0.id == p.id }) { panels.append(p) } }

        var warnings: [String] = []
        var kept: [(Panel, [String: JSONValue])] = []
        var designFiles: [DesignService.File]?
        for p in panels {
            guard let allowed = PartituraFormat.allowedState[p.pluginId] else {
                warnings.append("painel \(p.name) (\(p.pluginId)) não entra em partituras"); continue
            }
            var state: [String: JSONValue] = [:]
            for (k, v) in p.state where allowed.contains(k) {
                if p.pluginId == "design", k == "file" {   // the registry's id becomes the file's name; never the id
                    if designFiles == nil { designFiles = try await design.list() }
                    guard case .string(let fid) = v, let f = designFiles?.first(where: { $0.id == fid }) else {
                        warnings.append("painel \(p.name): arquivo de design não existe mais; salvo sem arquivo"); continue
                    }
                    guard PartituraFormat.isPlainFileName(f.name) else {
                        warnings.append("painel \(p.name): o nome do arquivo de design não cabe numa partitura; salvo sem arquivo"); continue
                    }
                    state[k] = .string(f.name)
                } else if p.pluginId == "browser", k == "url" {   // only what a partitura may carry: http(s) with a host
                    guard case .string(let s) = v, var u = URLComponents(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
                          !(u.host ?? "").isEmpty else {
                        warnings.append("painel \(p.name): endereço não é http(s); salvo sem endereço"); continue
                    }
                    if u.user != nil || u.password != nil {   // never user:pass@ in a file
                        u.user = nil; u.password = nil
                        warnings.append("painel \(p.name): usuário e senha tirados do endereço")
                    }
                    guard let plain = u.string else { warnings.append("painel \(p.name): endereço inválido; salvo sem endereço"); continue }
                    if u.query != nil { warnings.append("painel \(p.name): o endereço tem parâmetros (?…); confira se não levam segredo") }
                    state[k] = .string(plain)
                } else { state[k] = v }
            }
            kept.append((p, state))
        }

        // keys: the names without their common "<x>-" prefix, as slugs, unique
        let all = terms.map(\.name) + kept.map(\.0.name)
        var cut = 0
        if let dash = all.first?.firstIndex(of: "-") {
            let pre = String(all[0][...dash])
            if all.allSatisfy({ $0.lowercased().hasPrefix(pre.lowercased()) && $0.count > pre.count }) { cut = pre.count }
        }
        var used = Set<String>()
        func key(_ n: String, _ fallback: String) -> String {
            var base = PartituraFormat.slug(String(n.dropFirst(cut))); if base.isEmpty { base = fallback }
            var k = base, i = 2
            while !used.insert(k).inserted { let s = "-\(i)"; k = String(base.prefix(24 - s.count)) + s; i += 1 }
            return k
        }
        var keyOf: [UUID: String] = [:]
        for t in terms { keyOf[t.id] = key(t.name, "terminal") }
        for (p, _) in kept { keyOf[p.id] = key(p.name, "painel") }

        // frames: the app's, relative to the smallest x and y; a Maestro's save carries none
        var frames: [String: PartituraFrame] = [:]
        if caller == nil {
            for (n, v) in try object(r, "frames") {
                guard case .object(let o) = v, case .number(let x)? = o["x"], case .number(let y)? = o["y"],
                      case .number(let w)? = o["w"], case .number(let h)? = o["h"] else { throw invalid("a posição de '\(n)' precisa de x, y, w, h") }
                frames[n.lowercased()] = PartituraFrame(x: x, y: y, w: w, h: h)
            }
        }
        let fx = frames.values.map(\.x).min() ?? 0, fy = frames.values.map(\.y).min() ?? 0
        func frame(_ n: String) -> PartituraFrame? {
            frames[n.lowercased()].map { PartituraFrame(x: $0.x - fx, y: $0.y - fy, w: $0.w, h: $0.h) }
        }
        let roles = try object(r, "roles").reduce(into: [String: String]()) { if case .string(let s) = $1.value { $0[$1.key.lowercased()] = s } }

        var pt = Partitura(id: id, name: name, summary: str(r, "summary") ?? "", wantsFloor: flag(r, "wantsFloor"),
                           terminals: try terms.map { t throws(ProtocolError) in
                               if t.preset == .custom, (t.command ?? "").isEmpty { throw invalid("terminal '\(t.name)': preset custom sem comando") }
                               return PartituraTerminal(key: keyOf[t.id]!, preset: t.preset, command: t.preset == .custom ? t.command : nil,
                                                        role: roles[t.name.lowercased()], isMaestro: t.isMaestro, frame: frame(t.name)?.clamped(terminal: true))
                           },
                           panels: kept.map { p, state in
                               PartituraPanel(key: keyOf[p.id]!, pluginId: p.pluginId, placement: .canvas, state: state, frame: frame(p.name)?.clamped(terminal: false))
                           })
        // cords between the selected only; a panel-to-panel cord is not part of the format
        let panelIds = Set(kept.map(\.0.id))
        for c in ws.connections {
            guard let a = keyOf[c.a], let b = keyOf[c.b], !(panelIds.contains(c.a) && panelIds.contains(c.b)) else { continue }
            pt.cords.append([a, b])
        }
        try PartituraFormat.validate(pt)
        if !flag(r, "replace"), let old = await partituras.get(id) { throw invalid("já existe uma partitura \(old.name)") }
        try await partituras.put(pt)
        return .object(["id": .string(id), "warnings": .array(warnings.map { .string($0) })])
    }
}
