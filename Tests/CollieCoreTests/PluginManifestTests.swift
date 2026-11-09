import Testing
import Foundation
import CollieCore
import CollieProtocol

private let notas = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Examples/plugins/notas")

/// The notas manifest as a dictionary, changed by `edit`, decoded and validated.
private func manifest(_ edit: (inout [String: Any]) -> Void = { _ in }) throws(ProtocolError) -> PluginManifest {
    var m = try! JSONSerialization.jsonObject(with: Data(contentsOf: notas.appendingPathComponent("collie-plugin.json"))) as! [String: Any]
    edit(&m)
    return try PluginManifest.decode(try! JSONSerialization.data(withJSONObject: m))
}
private func refusal(_ edit: (inout [String: Any]) -> Void) -> ProtocolError? {
    do throws(ProtocolError) { _ = try manifest(edit); return nil } catch { return error }
}
private func command(_ name: String, timeout: Double? = nil) -> [String: Any] {
    var c: [String: Any] = ["name": name, "summary": "s", "runs": "ui"]
    if let timeout { c["timeout"] = timeout }
    return c
}

@Suite struct PluginManifestTests {
    @Test func decodesNotasExample() throws {
        let m = try PluginManifest.load(folder: notas)
        #expect(m.apiVersion == 1 && m.id == "notas" && m.name == "Notas" && m.version == "0.1.0" && m.license == "MIT")
        #expect(m.ui == "ui/index.html" && m.defaultPlacement == .dockRight && m.placements.contains(.canvas))
        #expect(m.commands.map(\.name) == ["add", "list", "export"])
        #expect(m.commands[0].params.first?.type == "rest" && m.commands[0].timeout == 30)
        #expect(m.commands[2].outputFile && !m.commands[0].outputFile)
        #expect(m.events == ["notas.changed"] && m.helper == nil)
    }

    @Test func refusesBadId() {
        for id in ["Browser", "x", "panel", "design", "memory", "plugin", "admin", "artifact", "1abc", "a_b", "notas\n", String(repeating: "a", count: 33)] {
            #expect(refusal { $0["id"] = id; $0["events"] = [] }?.code == .invalidArgs, "\(id)")
        }
        #expect(refusal { $0["id"] = "kanban"; $0["events"] = ["kanban.changed"] } == nil)
    }

    @Test func refusesHelperInPhase1() {
        let e = refusal { $0["helper"] = "bin/x" }
        #expect(e?.code == .invalidArgs && e?.message.contains("precisa de um Collie mais novo") == true, "\(String(describing: e))")
        let r = refusal { var c = command("go"); c["runs"] = "helper"; $0["commands"] = [c] }
        #expect(r?.message.contains("precisa de um Collie mais novo") == true)
        #expect(refusal { $0["apiVersion"] = 3 }?.message.contains("precisa de um Collie mais novo") == true)
        #expect(refusal { var c = command("go"); c["runs"] = "shell"; $0["commands"] = [c] }?.code == .invalidArgs)
    }

    @Test func refusesPermissionsInPhase1() {
        for p: Any in [["network": ["api.x.com"]], ["project": "read"], ["camera": true]] {
            #expect(refusal { $0["permissions"] = p }?.message.contains("precisa de um Collie mais novo") == true, "\(p)")
        }
        for p: Any in [[String: Any](), ["network": [String](), "project": "none"]] {
            #expect(refusal { $0["permissions"] = p } == nil, "\(p)")
        }
    }

    @Test func refusesBadCommandName() {
        for n in ["Add", "", "a.b", "a b", "-x", String(repeating: "a", count: 33)] {
            #expect(refusal { $0["commands"] = [command(n)] }?.code == .invalidArgs, "\(n)")
        }
        #expect(refusal { $0["commands"] = [command("a"), command("a")] }?.code == .invalidArgs)   // duplicate
        #expect(refusal { var c = command("a"); c["params"] = [["name": "panel", "type": "string"]]; $0["commands"] = [c] }?.code == .invalidArgs)
        #expect(refusal { var c = command("a"); c["params"] = [["name": "x", "type": "file"]]; $0["commands"] = [c] }?.code == .invalidArgs)
        #expect(refusal { var c = command("a"); c["params"] = [["name": "x", "type": "rest"]]; $0["commands"] = [c] }?.code == .invalidArgs)   // rest must be positional
    }

    @Test func refusesTimeoutOutOfRange() {
        for t in [0.0, -1, 301, 1e9] { #expect(refusal { $0["commands"] = [command("a", timeout: t)] }?.code == .invalidArgs, "\(t)") }
        #expect(refusal { $0["commands"] = [command("a", timeout: 300)] } == nil)
        #expect(refusal { $0["commands"] = [command("a", timeout: 1)] } == nil)
    }

    @Test func refusesTooManyCommands() {
        #expect(refusal { $0["commands"] = (0..<65).map { command("c\($0)") } }?.code == .invalidArgs)
        #expect(refusal { $0["commands"] = (0..<64).map { command("c\($0)") } } == nil)
    }

    @Test func refusesUnsafeUIPath() {
        for ui in ["../x.html", "ui/../../x.html", "/etc/passwd", "ui/index.js", "index.html", "ui//index.html", "ui/./index.html"] {
            #expect(refusal { $0["ui"] = ui }?.code == .invalidArgs, "\(ui)")
        }
        #expect(throws: ProtocolError.self) {   // valid path, missing file
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pm-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            try FileManager.default.copyItem(at: notas.appendingPathComponent("collie-plugin.json"), to: tmp.appendingPathComponent("collie-plugin.json"))
            _ = try PluginManifest.load(folder: tmp)
        }
    }

    @Test func specNamesPrefixed() throws {
        let s = try PluginManifest.load(folder: notas).pluginSpec()
        #expect(s.id == "notas" && s.title == "Notas" && !s.runsInDaemon && s.source == .external(version: "0.1.0"))
        #expect(s.commands.map(\.name) == ["notas.add", "notas.list", "notas.export"])
        #expect(s.commands[0].params.map(\.name) == ["text", "panel"] && s.commands[0].params[0].kind == .rest)
        #expect(s.commands[0].timeoutSeconds == 30 && s.events == ["notas.changed"])
        #expect(s.commands.map(\.outputFile) == [false, false, true])
        #expect(s.commands[2].params.map(\.name) == ["format", "out", "panel"])   // the manifest's own --out
        // an outputFile command without --out gets one; a positional or non-string --out is refused
        let m = try manifest { var c = command("png"); c["outputFile"] = true; $0["commands"] = [c]; $0["stateKeys"] = ["board"] }
        #expect(m.pluginSpec().commands[0].params.map(\.name) == ["out", "panel"] && m.pluginSpec().stateKeys == ["board"])
        #expect(refusal { var c = command("png"); c["outputFile"] = true; c["params"] = [["name": "out", "type": "string", "positional": true]]; $0["commands"] = [c] }?.code == .invalidArgs)
    }

    @Test func registerRevalidatesAndHerdAcceptsExternalWithStateKeys() async throws {
        try await PluginRegistry.exclusively { () async throws in
        defer { PluginRegistry.setExternal([]) }
        var bad = try PluginManifest.load(folder: notas); bad.id = "kanban"; bad.helper = "bin/x"   // fine on the wire, not valid
        var ok = try PluginManifest.load(folder: notas); ok.stateKeys = ["filter"]
        PluginManifest.register([ok, bad])
        #expect(PluginRegistry.externalSpecs.map(\.id) == ["notas"] && Commands.spec("notas.add") != nil)
        let t = HerdTerminal(key: "pastor", preset: .shell, isShepherd: true)
        func herd(_ state: [String: JSONValue], plugin: String = "notas") -> Herd {
            Herd(id: "h", name: "H", terminals: [t], panels: [HerdPanel(key: "notas", pluginId: plugin, placement: .canvas, state: state)])
        }
        #expect(throws: Never.self) { try HerdFormat.validate(herd(["filter": .string("hoje")])) }
        #expect(throws: ProtocolError.self) { try HerdFormat.validate(herd(["url": .string("x")])) }   // not a declared key
        #expect(throws: ProtocolError.self) { try HerdFormat.validate(herd([:], plugin: "kanban")) }   // not loaded
        #expect(throws: ProtocolError.self) { try HerdFormat.validate(herd([:], plugin: "device")) }   // built-in, still out
        PluginManifest.register([])
        #expect(throws: ProtocolError.self) { try HerdFormat.validate(herd([:])) }   // uninstalled
        }
    }

    /// R7 (M5): one manifest an app can't read doesn't lose the event's others.
    @Test func pluginsChangedDecodesLossily() throws {
        let good = try String(contentsOf: notas.appendingPathComponent("collie-plugin.json"), encoding: .utf8)
        let e = try JSONDecoder().decode(WorkspaceEvent.self, from: Data(#"{"t":"pluginsChanged","m":[{"id":5},\#(good)]}"#.utf8))
        guard case .pluginsChanged(let ms) = e else { Issue.record("\(e)"); return }
        #expect(ms.map(\.id) == ["notas"])
    }

    @Test func unknownKeysIgnored() throws {
        let m = try manifest {
            $0["futureKey"] = ["x": 1]
            var c = command("a"); c["futureFlag"] = true; $0["commands"] = [c]
        }
        #expect(m.commands.map(\.name) == ["a"])
    }

    // apiVersion 2: apps do cercado (spec 2026-11-08)
    private func v2(_ edit: @escaping (inout [String: Any]) -> Void = { _ in }) -> (inout [String: Any]) -> Void {
        { m in
            m["apiVersion"] = 2; m["id"] = "kube"; m["ui"] = "http://127.0.0.1:4100/"; m["events"] = ["kube.pod.crashed"]
            m["service"] = ["base": "http://127.0.0.1:4100", "start": "npm run serve"]
            m["commands"] = [["name": "pods", "summary": "List pods", "runs": "http", "http": ["method": "GET", "path": "/api/pods"]],
                             ["name": "restart", "summary": "Restart", "runs": "http", "http": ["method": "POST", "path": "/api/restart"], "confirm": true, "timeout": 60]]
            edit(&m)
        }
    }

    @Test func v2AppWithLoopbackServiceAndHttpCommands() throws {
        let m = try manifest(v2())
        #expect(m.uiIsURL && m.serviceOrigin == "http://127.0.0.1:4100")
        #expect(m.commands.map(\.runs) == ["http", "http"] && m.commands[1].confirm && m.commands[1].http?.path == "/api/restart")
        let spec = m.pluginSpec()
        #expect(spec.uiURL == "http://127.0.0.1:4100/" && spec.serviceBase == "http://127.0.0.1:4100")
        #expect(spec.commands.first { $0.name == "kube.restart" }?.timeoutSeconds == 60 + PluginManifest.confirmWait)   // the card waits first
        #expect(try manifest(v2 { $0["service"] = ["base": "http://localhost:8080/"]; $0["ui"] = "http://localhost:8080/app/index.html" }).serviceOrigin == "http://localhost:8080")
        #expect(try manifest(v2 { $0["service"] = ["base": "http://[::1]:9"]; $0["ui"] = "http://[::1]:9/" }).serviceOrigin == "http://[::1]:9")
    }

    @Test func v2RefusesWhatLeavesLoopbackOrItsBase() {
        for base in ["http://10.0.0.2:4100", "http://example.com", "file:///tmp", "http://127.0.0.1:4100/api", "http://u:p@127.0.0.1:1", "http://127.0.0.1:1?x=1"] {
            #expect(refusal(v2 { $0["service"] = ["base": base] })?.message.contains("service.base") == true, "\(base)")
        }
        #expect(refusal(v2 { $0["ui"] = "http://127.0.0.1:4200/" })?.message.contains("ui") == true)   // another port
        #expect(refusal(v2 { $0["ui"] = "http://evil.test/" })?.message.contains("ui") == true)
        for path in ["api/pods", "/api/../x", "/api?x=1", "/a#b", "//evil.test/x"] {
            #expect(refusal(v2 { $0["commands"] = [["name": "p", "summary": "s", "runs": "http", "http": ["method": "GET", "path": path]]] }) != nil, "\(path)")
        }
        #expect(refusal(v2 { $0["commands"] = [["name": "p", "summary": "s", "runs": "http", "http": ["method": "TRACE", "path": "/x"]]] }) != nil)
        #expect(refusal(v2 { $0["service"] = nil; $0["ui"] = "ui/index.html" })?.message.contains("service.base") == true)   // http without a service
        // v1 doesn't take v2 parts
        #expect(refusal { $0["service"] = ["base": "http://127.0.0.1:4100"] }?.message.contains("apiVersion 2") == true)
        #expect(refusal { var c = command("go"); c["confirm"] = true; $0["commands"] = [c] }?.message.contains("apiVersion 2") == true)
    }
}
