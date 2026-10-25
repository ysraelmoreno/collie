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
        #expect(refusal { $0["apiVersion"] = 2 }?.message.contains("precisa de um Collie mais novo") == true)
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
    }

    @Test func unknownKeysIgnored() throws {
        let m = try manifest {
            $0["futureKey"] = ["x": 1]
            var c = command("a"); c["futureFlag"] = true; $0["commands"] = [c]
        }
        #expect(m.commands.map(\.name) == ["a"])
    }
}
