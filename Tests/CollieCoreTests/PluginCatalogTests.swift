import Testing
import Foundation
import CryptoKit
import CollieCore
import CollieProtocol

private let key = Curve25519.Signing.PrivateKey()
private let pub = key.publicKey.rawRepresentation.base64EncodedString()
private let priv = key.rawRepresentation.base64EncodedString()
private let hexA = String(repeating: "a", count: 64), hexB = String(repeating: "b", count: 64)

private func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

private func version(_ v: String, tree: String = hexB, recalled: [String: Any]? = nil, minCollie: String? = nil) -> [String: Any] {
    var o: [String: Any] = [
        "version": v, "url": "https://github.com/ysraelmoreno/collie/releases/download/plugin-vizinho-v\(v)/vizinho-\(v).tar.gz",
        "sha256": hexA, "size": 812345, "treeSha256": tree, "permissions": ["project": "read"],
        "hooks": ["edit", "stop"], "helperTeamId": "AG8JQAH6YB", "recalled": recalled ?? NSNull(),
    ]
    if let minCollie { o["minCollie"] = minCollie }
    return o
}

/// The spec's example catalog, changed by `edit`, as JSON bytes.
private func catalog(_ edit: (inout [String: Any]) -> Void = { _ in }) -> Data {
    var c: [String: Any] = [
        "format": 1, "generatedAt": "2026-12-01T12:00:00Z", "sequence": 42,
        "plugins": [[
            "id": "vizinho", "name": "Vizinho", "publisher": "collie",
            "summary": "Ao editar um arquivo, o agente recebe a forma que os arquivos irmãos seguem.",
            "kind": "agent", "minCollie": "0.2.0", "versions": [version("0.1.0")],
        ]],
        "publishers": [["id": "collie", "name": "Collie", "reviewedBy": "collie"]],
    ]
    edit(&c)
    return (try? JSONSerialization.data(withJSONObject: c)) ?? Data()
}
private func editItem(_ c: inout [String: Any], _ edit: (inout [String: Any]) -> Void) {
    var items = c["plugins"] as? [[String: Any]] ?? []
    edit(&items[0]); c["plugins"] = items
}
private func accept(_ data: Data, last: Int? = nil) throws(ProtocolError) -> PluginCatalog {
    try PluginCatalog.accept(data, signature: try PluginCatalog.sign(data, privateKey: priv), keys: [pub], lastSequence: last)
}
private func refusal(_ data: Data, last: Int? = nil) -> ProtocolError? {
    L10n.$override.withValue(.pt) {
        do throws(ProtocolError) { _ = try accept(data, last: last); return nil } catch { return error }
    }
}

@Suite struct PluginCatalogTests {
    @Test func acceptsSigned() throws {
        let c = try accept(catalog())
        #expect(c.plugins[0].id == "vizinho" && c.plugins[0].kind == .agent && c.sequence == 42)
        #expect(c.plugins[0].versions[0].permissions == ["project": .string("read")])
    }

    @Test func refusesWrongKey() throws {
        let data = catalog(), sig = try PluginCatalog.sign(data, privateKey: priv)
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        #expect(throws: ProtocolError.self) { try PluginCatalog.accept(data, signature: sig, keys: [other], lastSequence: nil) }
        // the shipped placeholder accepts nothing; a rotated list accepts the signing key among others
        #expect(throws: ProtocolError.self) { try PluginCatalog.accept(data, signature: sig, lastSequence: nil) }
        #expect(try PluginCatalog.accept(data, signature: sig, keys: [other, pub], lastSequence: nil).sequence == 42)
    }

    @Test func refusesTamperedByte() throws {
        var data = catalog()
        let sig = try PluginCatalog.sign(data, privateKey: priv)
        data[data.count / 2] ^= 0x01
        do throws(ProtocolError) { _ = try PluginCatalog.accept(data, signature: sig, keys: [pub], lastSequence: nil); Issue.record("aceito") }
        catch { #expect(error.message.contains("assinatura")) }
    }

    @Test func refusesFormat2() {
        #expect(refusal(catalog { $0["format"] = 2 })?.message.contains("formato 2") == true)
    }

    @Test func refusesOlderSequence() {
        #expect(refusal(catalog(), last: 43)?.message.contains("sequence") == true)
    }

    @Test func acceptsSameSequence() {
        #expect(refusal(catalog(), last: 42) == nil)
        #expect(refusal(catalog(), last: 41) == nil)
    }

    @Test func refusesBadItem() {
        let cases: [(String, Data)] = [
            ("não tem versão", catalog { editItem(&$0) { $0["versions"] = [] } }),
            ("repetido", catalog { $0["plugins"] = ($0["plugins"] as? [Any] ?? []) + ($0["plugins"] as? [Any] ?? []) }),
            ("sha256", catalog { editItem(&$0) { var v = version("0.1.0"); v["sha256"] = String(hexA.dropLast()); $0["versions"] = [v] } }),
            ("url", catalog { editItem(&$0) { var v = version("0.1.0"); v["url"] = "https://github.com/outro/collie/releases/download/plugin-x/x.tar.gz"; $0["versions"] = [v] } }),
            ("url", catalog { editItem(&$0) { var v = version("0.1.0"); v["url"] = "https://github.com/ysraelmoreno/collie/releases/download/plugin-x/../../../x.tar.gz"; $0["versions"] = [v] } }),
            ("publisher", catalog { editItem(&$0) { $0["publisher"] = "fulano" } }),
        ]
        for (why, data) in cases {
            let r = refusal(data)
            #expect(r?.code == .invalidArgs && r?.message.contains(why) == true, "\(why): \(r?.message ?? "aceito")")
        }
    }

    @Test func staleAfter30Days() throws {
        let now = Date()
        func at(_ days: Double) throws -> PluginCatalog {
            try accept(catalog { $0["generatedAt"] = iso(now.addingTimeInterval(days * 86400)) })
        }
        #expect(try at(-31).isStale(now: now))
        #expect(try !at(-29).isStale(now: now))
        #expect(try !at(1).isStale(now: now))
    }

    @Test func recallByTree() throws {
        let c = try accept(catalog { editItem(&$0) {
            $0["versions"] = [version("0.1.0", tree: hexA, recalled: ["reason": "vaza arquivos", "at": "2026-12-02T00:00:00Z"])]
        } })
        #expect(c.recall(forTree: hexA)?.reason == "vaza arquivos")
        #expect(c.recall(forTree: hexB) == nil)
    }

    @Test func latestSkipsRecalledAndNewerCollie() throws {
        let c = try accept(catalog { editItem(&$0) {
            $0["versions"] = [version("0.1.0"), version("0.2.0", recalled: ["reason": "r", "at": "2026-12-02T00:00:00Z"]),
                              version("0.3.0", minCollie: "9.0.0")]
        } })
        #expect(c.latest("vizinho", collie: "0.5.0")?.version == "0.1.0")
        #expect(c.latest("vizinho", collie: "9.0.0")?.version == "0.3.0")
        #expect(c.latest("vizinho", collie: "0.1.0") == nil)   // item minCollie 0.2.0
        #expect(c.latest("outro", collie: "9.0.0") == nil)
    }

    @Test func compareIsNumeric() {
        #expect(PluginCatalog.compare("0.10.0", "0.9.0") == .orderedDescending)
        #expect(PluginCatalog.compare("1.0", "1.0.0") == .orderedSame)
        #expect(PluginCatalog.compare("0.2.0", "0.2.1") == .orderedAscending)
    }
}

@Suite struct PluginCatalogEnglishTests {
    @Test func refusalsAreEnglish() {
        L10n.$override.withValue(.en) {
            do throws(ProtocolError) { _ = try accept(catalog(), last: 43) } catch {
                #expect(error.message.hasPrefix("plug-in catalog refused:") && error.message.contains("lower than the last accepted"), "\(error.message)")
                return
            }
            Issue.record("accepted")
        }
    }
}
