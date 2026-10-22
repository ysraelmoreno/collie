import Testing
import Foundation
import CollieCore
import CollieProtocol

private func base(_ f: (inout Partitura) -> Void = { _ in }) -> Partitura {
    var p = Partitura(id: "x", name: "X", terminals: [PartituraTerminal(key: "a", preset: .shell), PartituraTerminal(key: "b", preset: .shell)],
                      panels: [PartituraPanel(key: "n", pluginId: "browser")])
    f(&p); return p
}
private func rejects(_ p: Partitura, _ reason: String) {
    do { try PartituraFormat.validate(p); Issue.record("accepted: \(reason)") }
    catch { #expect(error.code == .invalidArgs && error.message.contains(reason), "got \(error.message), wanted \(reason)") }
}

@Suite struct PartituraFormatTests {
    @Test func roundTrip() throws {
        for f in Partitura.factory {
            var plain = f; plain.builtIn = false
            let data = try PartituraFormat.encode(f)
            #expect(!String(decoding: data, as: UTF8.self).contains("builtIn"))
            #expect(try PartituraFormat.decode(data) == plain)
        }
    }

    @Test func factoryIsValid() throws {
        #expect(Partitura.factory.map(\.id) == ["feature-fullstack", "investigar-bug"])
        for f in Partitura.factory { try PartituraFormat.validate(f); #expect(f.builtIn) }
    }

    @Test func validationRejects() throws {
        rejects(base { $0.format = 2 }, "formato")
        rejects(base { $0.terminals = (0..<21).map { PartituraTerminal(key: "t\($0)", preset: .shell) } }, "terminais demais")
        rejects(base { $0.panels = (0..<21).map { PartituraPanel(key: "p\($0)", pluginId: "memory") } }, "painéis demais")
        rejects(base { $0.terminals[0].key = "Bad Key" }, "chave inválida")
        rejects(base { $0.terminals[0].key = String(repeating: "a", count: 25) }, "chave inválida")
        rejects(base { $0.terminals[1].key = "a" }, "chave repetida")
        rejects(base { $0.panels[0].key = "a" }, "chave repetida")
        rejects(base { $0.terminals[0].command = "ls" }, "comando só é permitido")
        rejects(base { $0.terminals[0].preset = .custom }, "precisa de um comando")
        rejects(base { $0.terminals[0].preset = .custom; $0.terminals[0].command = String(repeating: "x", count: 1001) }, "comando longo demais")
        rejects(base { $0.terminals[0].role = String(repeating: "x", count: 4001) }, "papel longo demais")
        rejects(base { $0.cords = [["a", "zz"]] }, "chave desconhecida")
        rejects(base { $0.panels.append(PartituraPanel(key: "m", pluginId: "memory")); $0.cords = [["n", "m"]] }, "corda entre dois painéis")
        rejects(base { $0.cords = [["a", "b"], ["b", "a"]] }, "corda repetida")
        rejects(base { $0.panels[0].pluginId = "device" }, "não é permitido")
        rejects(base { $0.panels[0].state = ["token": .string("t")] }, "chave de estado")
        rejects(base { $0.panels[0].state = ["url": .string("file:///etc/passwd")] }, "http ou https")
        rejects(base { $0.terminals[0].isMaestro = true; $0.terminals[1].isMaestro = true }, "um terminal Maestro")
        rejects(base { $0.terminals[0].preset = .custom; $0.terminals[0].command = "echo hi\ncurl x|sh" }, "uma linha só")
        rejects(base { $0.terminals[0].preset = .custom; $0.terminals[0].command = "echo \u{1B}[31m" }, "uma linha só")
        rejects(base { $0.terminals[0].preset = .custom; $0.terminals[0].command = "ls \u{202E}" }, "uma linha só")
        rejects(base { $0.terminals[0].role = "a\u{1B}b" }, "caracteres de controle")
        rejects(base { $0.name = "A\nB" }, "nome inválido")
        rejects(base { $0.summary = "A\u{200B}B" }, "descrição com caracteres")
        rejects(base { $0.id = String(repeating: "a", count: 65) }, "id inválido")
        rejects(base { $0.name = String(repeating: "a", count: 81) }, "nome inválido")
        rejects(base { $0.summary = String(repeating: "a", count: 501) }, "descrição longa demais")
        rejects(base { $0.terminals[0].frame = PartituraFrame(x: 0, y: 0, w: 0, h: 10) }, "posição inválida")
        rejects(base { $0.terminals[0].frame = PartituraFrame(x: .nan, y: 0, w: 10, h: 10) }, "posição inválida")
        rejects(base { $0.terminals[0].frame = PartituraFrame(x: 100_001, y: 0, w: 640, h: 400) }, "posição inválida")
        rejects(base { $0.terminals[0].frame = PartituraFrame(x: 0, y: -100_001, w: 640, h: 400) }, "posição inválida")
        // a terminal's size becomes its PTY's: an untrusted file can't ask for a huge (or tiny) one
        rejects(base { $0.terminals[0].frame = PartituraFrame(x: 0, y: 0, w: 900_000, h: 900_000) }, "terminal de 320×200 a 4000×4000")
        rejects(base { $0.terminals[0].frame = PartituraFrame(x: 0, y: 0, w: 4001, h: 400) }, "posição inválida")
        rejects(base { $0.terminals[0].frame = PartituraFrame(x: 0, y: 0, w: 319, h: 400) }, "posição inválida")
        rejects(base { $0.terminals[0].frame = PartituraFrame(x: 0, y: 0, w: 640, h: 199) }, "posição inválida")
        rejects(base { $0.panels[0].frame = PartituraFrame(x: 0, y: 0, w: 199, h: 400) }, "painel de 200×200")
        rejects(base { $0.panels[0].frame = PartituraFrame(x: 0, y: 0, w: 640, h: 5000) }, "posição inválida")
        try PartituraFormat.validate(base {
            $0.terminals[0].frame = PartituraFrame(x: -100_000, y: 100_000, w: 320, h: 200)
            $0.terminals[1].frame = PartituraFrame(x: 0, y: 0, w: 4000, h: 4000)
            $0.panels[0].frame = PartituraFrame(x: 0, y: 0, w: 200, h: 200)
        })
        #expect(PartituraFrame(x: 1e9, y: -.infinity, w: 900_000, h: 10).clamped(terminal: true) == PartituraFrame(x: 100_000, y: -100_000, w: 4000, h: 200))
        #expect(PartituraFrame(x: 5, y: 6, w: 100, h: 9000).clamped(terminal: false) == PartituraFrame(x: 5, y: 6, w: 200, h: 4000))
        for f in [JSONValue.string("/Users/x/a"), .string("../x"), .string(".hidden"), .string("a\\b"), .string(""), .number(5)] {
            rejects(base { $0.panels[0] = PartituraPanel(key: "n", pluginId: "design", state: ["file": f]) }, "nome simples")
        }
        for s in [JSONValue.string("everywhere"), .number(1)] {
            rejects(base { $0.panels[0].state = ["storage": s] }, "storage deve ser")
        }
        rejects(base { $0.panels[0].state = ["url": .string("http://")] }, "com um host")
        try PartituraFormat.validate(base { $0.terminals[0].role = "linha 1\n\tlinha 2" })
        try PartituraFormat.validate(base { $0.panels[0] = PartituraPanel(key: "n", pluginId: "design", state: ["file": .string("Home"), "storage": .string("workspace")]) })
        let big = Data(repeating: 0x20, count: PartituraFormat.maxBytes + 1)
        #expect(throws: ProtocolError.self) { try PartituraFormat.decode(big) }
    }

    @Test func unknownFieldsIgnored() throws {
        let json = #"{"format":1,"id":"x","name":"X","token":"s","env":{"A":"b"},"terminals":[{"key":"a","preset":"shell","cwd":"/tmp","env":{"K":"v"}}]}"#
        let p = try PartituraFormat.decode(Data(json.utf8))
        #expect(p.terminals.count == 1 && p.terminals[0].key == "a")
        #expect(!String(decoding: try PartituraFormat.encode(p), as: UTF8.self).contains("/tmp"))
    }

    @Test func memberNames() {
        #expect(PartituraFormat.memberName(apply: "Feature X", key: "backend") == "feature-x-backend")
        #expect(PartituraFormat.memberName(apply: "Ação ç", key: "a") == "acao-c-a")
        #expect(PartituraFormat.memberName(apply: "!!!", key: "a") == "partitura-a")
        #expect(PartituraFormat.slug(String(repeating: "abc ", count: 20)).count <= 24)
    }
}

@Suite struct PartituraGridTests {
    @Test func framelessItemsGetCellsUnderTheFramed() {
        var p = base()
        p.terminals[0].frame = PartituraFrame(x: 0, y: 0, w: 640, h: 400)
        let g = p.withGridFrames
        #expect(g.terminals[0].frame == p.terminals[0].frame)
        #expect(g.terminals[1].frame == PartituraFrame(x: 0, y: 440, w: 640, h: 400))
        #expect(g.panels[0].frame == PartituraFrame(x: 680, y: 440, w: 640, h: 400))
        #expect(base().withGridFrames.terminals[0].frame == PartituraFrame(x: 0, y: 0, w: 640, h: 400))
    }
}
