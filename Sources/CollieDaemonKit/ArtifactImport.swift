import Foundation
import CollieCore
import CollieProtocol

extension CommandRouter {
    /// `artifact.import`: agent page `id` rebuilt as a screen in a new design file, which the artifact then exports as
    /// its version 1. Refused for an export, or while an import of it runs.
    func importArtifact(_ id: UUID, width: Int, by: String) async throws -> JSONValue {
        let a = try await artifacts.get(id)
        guard a.kind == .agent else { throw ProtocolError(code: .invalidArgs, message: "already imported: edit its design screen") }
        guard importingArtifacts.insert(id).inserted else { throw ProtocolError(code: .invalidArgs, message: "import already in progress") }
        defer { importingArtifacts.remove(id) }
        return try await runImport(a, width: width, by: by)
    }

    /// `artifact.add`'s import of `a`, in the background (`importing` from now on). Its failure is the artifact's
    /// `importError` (and runImport's event).
    func importInBackground(_ a: Artifact, width: Int, by: String) {
        importingArtifacts.insert(a.id)
        Task {
            defer { importingArtifacts.remove(a.id) }
            _ = try? await runImport(a, width: width, by: by)
        }
    }

    /// The import, within one `artifact.import` deadline: the app's DOM snapshot of the page; a new design file (named
    /// after the title, on the artifact's floor, the floor's design system enabled); the mapper's steps run as one
    /// batch (one undo step) on the daemon's own client of it; its colors bound to the system's (`bindColors`); that screen exported into the artifact itself. Any
    /// failure (scrubbed, the design file made so far kept) becomes the artifact's `importError`, an `artifact.imported`
    /// `{id, error}` event and is thrown.
    private func runImport(_ a: Artifact, width: Int, by: String) async throws -> JSONValue {
        let deadline = design.deadline("artifact.import")
        var made: DesignService.File?
        do {
            let src = a.source ?? "\(a.folder)/source.html"
            // the url is built here from the record, never taken from a caller
            _ = try await host.callApp(command: "html.snapshot",
                                       args: ["id": .string(a.id.uuidString.lowercased()), "url": .string("collie-artifact://app/\(src)"),
                                              "width": .number(Double(width))],
                                       timeout: min(.seconds(40), try DesignService.left(deadline)))
            var (snap, payloads) = try await Self.readImport(artifacts.dir.appendingPathComponent("\(a.folder)/.import"))
            snap.blocked = snap.blocked.map { String($0.prefix { $0 != "?" && $0 != "#" }) }   // queries may carry tokens

            let floor = a.floorId.flatMap { id in ws.floors.contains { $0.id == id } ? id : nil }
            var f: DesignService.File
            while true {
                let name = Self.importName(a.title, taken: Set(try await design.list().map(\.name)))
                do { f = try await design.create(name, floor: floor, deadline: deadline); break }
                catch let e as ProtocolError where e.message.hasSuffix("already exists") {   // taken meanwhile: the next one
                    _ = try DesignService.left(deadline)
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            made = f
            var warnings: [String] = []
            let enabled = await enableActiveSystem(f, deadline)
            if case .string(let w)? = enabled["designSystemError"] { warnings.append(w) }

            let title = a.title, families = Self.families(snap.root).union(["Inter"])
            let (root, mapped, uses, ids) = try await design.onSystemClient(f.id, deadline: deadline) {
                c, d throws(ProtocolError) -> (String, [String], [HTMLImport.ColorUse], [JSONValue]) in
                func names(_ v: JSONValue) -> [String] { if case .array(let a) = v { a.compactMap { if case .string(let s) = $0 { s } else { nil } } } else { [] } }
                var book = FontBook(families: [:])
                let have = names(try await c.command("text.fonts", [:], timeout: try DesignService.left(d)))
                for fam in have where families.contains(where: { $0.caseInsensitiveCompare(fam) == .orderedSame }) {
                    book.families[fam] = names(try await c.command("text.fonts", ["family": .string(fam)], timeout: try DesignService.left(d)))
                }
                let (steps, warnings, uses) = HTMLImport.steps(snap, payloads: payloads, fonts: book, name: title)
                guard !steps.isEmpty else { throw ProtocolError(code: .invalidArgs, message: warnings.last ?? "nothing to import") }
                let r = try await c.result("batch", ["commands": .array(steps), "label": .string("Importar \(title)")],
                                           timeout: try DesignService.left(d))
                let text = r.texts.joined(separator: "\n")
                if r.isError {
                    throw DesignService.located(text, steps.map { if case .object(let o) = $0, case .string(let c)? = o["command"] { c } else { "" } })
                }
                guard case .array(let results)? = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
                      case .object(let first)? = results.first, let root = first["id"].flatMap(DesignService.idString) else {
                    throw ProtocolError(code: .internal, message: "design engine: no screen id in the batch answer")
                }
                return (root, warnings, uses, results.map { if case .object(let o) = $0 { o["id"] ?? .null } else { .null } })
            }
            var clean: [String] = []   // blocked links among them
            for w in mapped { clean.append(await design.scrubbed(w)) }
            warnings = clean + warnings
            if case .string(let system)? = enabled["designSystem"],
               let w = await bindColors(uses, ids: ids, file: f, system: system, deadline: deadline) { warnings.append(await design.scrubbed(w)) }

            let shot = try await design.systemSnapshot(fileId: f.id, node: root, deadline: deadline)
            guard case .object(var out) = try await exportHTML(f, node: root, snapshot: shot, by: by, deadline: deadline,
                                                               importing: (a.id, warnings)) else {
                throw ProtocolError(code: .internal, message: "artifacts: no export")
            }
            out["path"] = nil
            out["file"] = .string(f.name); out["node"] = .string(root)
            let id = JSONValue.string(a.id.uuidString.lowercased())
            for p in ws.panels where p.pluginId == "artifacts" {
                await pluginEmitted(panel: p.id, name: "artifact.imported", payload: .object(["id": id, "file": .string(f.name)]))
            }
            return .object(out)
        } catch {
            // also ends the store's conversion of `a` (an export that failed before its commit)
            var m = await design.scrubbed((error as? ProtocolError)?.message ?? "\(error)")
            if let made { m += " (design file \(made.name) kept)" }
            try? await artifacts.setImportError(a.id, m)
            for p in ws.panels where p.pluginId == "artifacts" {
                await pluginEmitted(panel: p.id, name: "artifact.imported", payload: .object(["id": .string(a.id.uuidString.lowercased()), "error": .string(m)]))
            }
            throw ProtocolError(code: (error as? ProtocolError)?.code ?? .internal, message: m)
        }
    }

    /// Each of `uses` (a step's node: `ids`) whose color is the value of one of active system `system`'s published
    /// color variables (`HTMLImport.colorNames` of its file's `variable.list`, kept to the ids the library of `f`
    /// lists) bound to it by the library, as one batch on the daemon's client of `f`; other colors stay literal. A
    /// warning: what was bound, or why nothing was (never thrown).
    private func bindColors(_ uses: [HTMLImport.ColorUse], ids: [JSONValue], file f: DesignService.File, system: String,
                            deadline: ContinuousClock.Instant) async -> String? {
        do {
            let ds = try await systems.system(named: system)
            // ponytail: values of the system's file as it is now (the library lists none); a value changed since the last
            // publish can match here yet bind to the published one — read the published snapshot if that bites
            let list = try await design.onSystemClient(ds.fileId.uuidString.lowercased(), deadline: deadline) { c, d throws(ProtocolError) in
                try await c.command("variable.list", [:], timeout: try DesignService.left(d))
            }
            let view = try await design.current(ds.viewLink)
            let published = try await design.onSystemClient(f.id, deadline: deadline) { c, d throws(ProtocolError) -> Set<String> in
                let r = try await c.command("library.list", ["assets": .bool(true)], timeout: try DesignService.left(d))
                guard case .object(let o) = r, case .array(let libs)? = o["libraries"] else { return [] }
                for case .object(let l) in libs {
                    let path = if case .string(let p)? = l["path"] { DesignSystemService.unhosted(p) } else { "" }
                    guard path == DesignSystemService.unhosted(view) || l["name"] == .string(ds.name),
                          case .array(let vs)? = l["variables"] else { continue }
                    return Set(vs.compactMap { if case .object(let v) = $0, case .string(let id)? = v["id"] { id } else { nil } })
                }
                return []
            }
            let names = HTMLImport.colorNames(list, published: published)
            var groups: [[String]: [JSONValue]] = [:], n = 0   // [variable id, field] → layer ids
            for u in uses {
                guard let v = names[HTMLImport.normHex(u.hex)], u.step < ids.count, ids[u.step] != .null else { continue }
                groups[[v.id, u.field == "stroke" ? "stroke" : "fill"], default: []].append(ids[u.step])
                n += 1
            }
            guard n > 0 else { return nil }
            func step(_ c: String, _ p: [String: JSONValue]) -> JSONValue { .object(["command": .string(c), "params": .object(p)]) }
            let steps = [step("library.add", ["path": .string(view)])] + groups.keys.sorted { $0.joined(separator: "\u{0}") < $1.joined(separator: "\u{0}") }.map {
                step("library.bindVariable", ["library": .object(["$step": .number(0)]), "variable": .string($0[0]), "field": .string($0[1]),
                                              "ids": .array(groups[$0] ?? [])])
            }
            try await design.onSystemClient(f.id, deadline: deadline) { c, d throws(ProtocolError) in
                let r = try await c.result("batch", ["commands": .array(steps), "label": .string("Ligar cores ao design system")],
                                           timeout: try DesignService.left(d))
                if r.isError { throw ProtocolError(code: .internal, message: "design engine: \(r.texts.joined(separator: "\n"))") }
            }
            return "bound \(n) colors to \(ds.name)"
        } catch {
            return "colors not bound to \(system): \((error as? ProtocolError)?.message ?? "\(error)")"
        }
    }

    /// `title` as a design file name (2A rules: anything outside A-Z a-z 0-9 space . _ - becomes "-", no "..", at
    /// most 80; nothing left: "Importado"), then " 2", " 3"… until it is none of `taken` (case aside).
    static func importName(_ title: String, taken: Set<String>) -> String {
        let ok = CharacterSet.alphanumerics
        var s = String(String.UnicodeScalarView(title.unicodeScalars.map {
            $0.isASCII && (ok.contains($0) || " ._-".unicodeScalars.contains($0)) ? $0 : "-"
        }))
        while s.contains("..") { s = s.replacingOccurrences(of: "..", with: ".") }
        func trim<S: StringProtocol>(_ x: S) -> String { x.trimmingCharacters(in: .whitespaces) }
        s = trim(trim(s).prefix(80))
        if s.isEmpty { s = "Importado" }
        let lower = Set(taken.map { $0.lowercased() })
        var name = s, n = 1
        while lower.contains(name.lowercased()) {
            n += 1
            name = trim(s.prefix(80 - " \(n)".count)) + " \(n)"
        }
        return name
    }

    /// The first family of every `font-family` in the snapshot (as the mapper reads it).
    private static func families(_ n: DOMNode) -> Set<String> {
        var out: Set<String> = []
        if let css = n.style["fontFamily"], let first = css.split(separator: ",").first {
            out.insert(first.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
        }
        for c in n.children { out.formUnion(families(c)) }
        return out
    }

    /// The snapshot the app left in `dir` and the payload files it names (`img-<n>.png` up to 4 MiB, `svg-<n>.svg` up
    /// to 256 KiB; others, missing or over: left out), read off the pool, never through a link; then `dir` deleted.
    private static func readImport(_ dir: URL) async throws -> (DOMSnapshot, [String: Data]) {
        try await UnixSocketClient.offPool { () throws -> (DOMSnapshot, [String: Data]) in
            defer { try? FileManager.default.removeItem(at: dir) }
            let bad = ProtocolError(code: .internal, message: "bad snapshot")
            let dfd = open(dir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard dfd >= 0 else { throw bad }
            defer { close(dfd) }
            func read(_ name: String, cap: Int) -> Data? {
                let fd = openat(dfd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard fd >= 0 else { return nil }
                defer { close(fd) }
                var st = stat()
                guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= cap,
                      let d = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: cap + 1) ?? Data(),
                      d.count <= cap else { return nil }
                return d
            }
            guard let raw = read("snapshot.json", cap: 32 << 20), let s = try? JSONDecoder().decode(DOMSnapshot.self, from: raw) else { throw bad }
            var payloads: [String: Data] = [:]
            func walk(_ n: DOMNode) {
                for f in [n.image?.file, n.svg?.file].compactMap({ $0 })
                where payloads[f] == nil && f.wholeMatch(of: /(img|svg)-\d+\.(png|svg)/) != nil {
                    payloads[f] = read(f, cap: f.hasSuffix(".png") ? 4 << 20 : 256 << 10)
                }
                n.children.forEach(walk)
            }
            walk(s.root)
            return (s, payloads)
        }
    }
}
