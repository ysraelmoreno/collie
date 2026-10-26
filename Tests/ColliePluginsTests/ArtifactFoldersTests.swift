import Foundation
import Testing
import CollieProtocol
@testable import ColliePlugins

private func row(_ id: String, _ folder: String?, title: String? = nil) -> ArtifactRow {
    let o: JSONValue = .object(["id": .string(id), "kind": .string("agent"), "title": .string(title ?? "T \(id)"), "file": .null, "node": .null,
                                "by": .string("app"), "at": .string("2026-10-21T10:00:00Z"), "version": .number(1), "url": .string("u"),
                                "thumbnail": .null, "status": .null, "warnings": .array([]), "source": .null, "importError": .null,
                                "folder": folder.map { .string($0) } ?? .null])
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
    return try! d.decode(ArtifactRow.self, from: JSONEncoder().encode(o))
}
private func folder(_ path: String, pinned: Bool = false, presentation: Bool = false, items: [String] = []) -> ArtifactFolderRow {
    ArtifactFolderRow(path: path, count: 0, total: 0, color: nil, pinned: pinned, presentation: presentation, items: items)
}

@Suite struct ArtifactFolderTreeTests {
    @Test func groupsInUserOrderPinnedFirstNoFolderLast() {
        let rows = [row("a", "Cliente/Landing"), row("b", nil), row("c", "cliente"), row("d", "Zeta")]
        let s = ArtifactFolderTree.sections(rows: rows, folders: [folder("Landing"), folder("Cliente"), folder("Vazia", pinned: true)])
        #expect(s.map(\.name) == ["Vazia", "Landing", "Cliente", "Landing", "Zeta", "Sem pasta"])
        #expect(s.map(\.depth) == [0, 0, 0, 1, 0, 0])
        #expect(s[2].rows.map(\.id) == ["c"] && s[2].total == 2 && s[3].path == "Cliente/Landing" && s.last?.path == nil)
        #expect(s[0].total == 0)   // an empty folder of the user's shows
    }

    @Test func collapsedHidesSubfolders() {
        let rows = [row("a", "Cliente/Landing/v2"), row("c", "Cliente")]
        let s = ArtifactFolderTree.sections(rows: rows, folders: [], collapsed: ["cliente"])
        #expect(s.map(\.name) == ["Cliente"] && s[0].collapsed && s[0].total == 2 && s[0].hasChildren)
    }

    @Test func searchFiltersRowsAndEmptyFolders() {
        let rows = [row("a", "Cliente", title: "Home"), row("b", "Cliente", title: "Preços"), row("c", nil, title: "home antiga")]
        let s = ArtifactFolderTree.sections(rows: rows, folders: [folder("Vazia")], query: "HOME")
        #expect(s.map(\.name) == ["Cliente", "Sem pasta"] && s[0].rows.map(\.id) == ["a"] && s[1].rows.map(\.id) == ["c"])
        // the folder's name matches too
        #expect(ArtifactFolderTree.sections(rows: rows, folders: [], query: "clien").first?.rows.count == 2)
    }

    @Test func presentationOrdersItsPages() {
        let rows = [row("a", "Deck"), row("b", "Deck"), row("c", "Deck")]
        let s = ArtifactFolderTree.sections(rows: rows, folders: [folder("Deck", presentation: true, items: ["c", "a", "b"])])
        #expect(s[0].rows.map(\.id) == ["c", "a", "b"] && s[0].presentation)
    }

    @Test func caseRuleMatchesTheDaemon() {
        // lowercased, as ArtifactFolder.same: "Straße" and "STRASSE" are two folders
        let s = ArtifactFolderTree.sections(rows: [row("a", "Straße"), row("b", "STRASSE"), row("c", "árvore")], folders: [folder("ÁRVORE")])
        #expect(s.map(\.name) == ["ÁRVORE", "STRASSE", "Straße"] || s.map(\.name) == ["ÁRVORE", "Straße", "STRASSE"])
        #expect(s[0].rows.map(\.id) == ["c"])
    }

    @Test func renamedPathKeepsParent() {
        #expect(ArtifactFolderTree.renamed("Cliente/Landing", to: " Nova ") == "Cliente/Nova")
        #expect(ArtifactFolderTree.renamed("Cliente", to: "Marca") == "Marca")
    }
}

@MainActor @Suite struct ArtifactFolderModelTests {
    actor Log { var calls: [(String, [String: JSONValue])] = []; func add(_ c: String, _ a: [String: JSONValue]) { calls.append((c, a)) } }

    @Test func actionsCallTheDaemon() async {
        let log = Log()
        let m = ArtifactsModel(call: { c, a throws(ProtocolError) in
            await log.add(c, a)
            switch c {
            case "artifact.list": return .array([])
            case "artifact.folders": return .array([.object(["path": .string("Cliente"), "count": .number(0), "total": .number(0), "color": .null,
                                                             "pinned": .bool(false), "presentation": .bool(false), "items": .array([])])])
            default: return .object([:])
            }
        })
        await m.refresh()
        #expect(m.folders.map(\.path) == ["Cliente"])
        await m.move("a", to: "Cliente"); await m.move("a", to: nil)
        await m.createFolder("Landing", in: "Cliente")
        await m.renameFolder("Cliente/Landing", to: "Home")
        await m.removeFolder("Cliente", emptying: true)
        await m.setFolder("Cliente", pinned: true)
        let calls = await log.calls.filter { !["artifact.list", "artifact.folders"].contains($0.0) }
        #expect(calls.map(\.0) == ["artifact.move", "artifact.move", "artifact.folder.create", "artifact.folder.rename", "artifact.folder.remove", "artifact.folder.set"])
        #expect(calls[1].1["folder"] == .string("") && calls[2].1["path"] == .string("Cliente/Landing"))
        #expect(calls[3].1["to"] == .string("Cliente/Home") && calls[4].1["move-to"] == .string("") && calls[5].1["pin"] == .string("true"))
    }
}

/// A move used to refetch `artifact.list` twice (the action's refresh and the `artifact.changed` one): the daemon asks the
/// design engine for every export's stamp on each list. A move or a folder change now refetches only `artifact.folders`.
@MainActor @Suite struct ArtifactMoveRefreshTests {
    actor Log {
        var calls: [String] = [], items: [String] = []
        func add(_ c: String) { calls.append(c) }
        func put(_ i: [String]) { items = i }
        func count(_ c: String) -> Int { calls.filter { $0 == c }.count }
    }
    private func make(window: Duration = .milliseconds(500)) -> (ArtifactsModel, Log) {
        let log = Log()
        let m = ArtifactsModel(call: { c, _ throws(ProtocolError) in
            await log.add(c)
            switch c {
            case "artifact.list":
                return .array(["a", "b", "c"].map { id in
                    .object(["id": .string(id), "kind": .string("export"), "title": .string(id), "file": .null, "node": .null, "by": .string("app"),
                             "at": .string("2026-10-21T10:00:00Z"), "version": .number(1), "url": .string("u"), "thumbnail": .null,
                             "status": .string("current"), "warnings": .array([]), "source": .null, "importError": .null, "folder": .null])
                })
            case "artifact.folders":
                return .array([.object(["path": .string("Cliente"), "count": .number(0), "total": .number(0), "color": .null, "pinned": .bool(false),
                                        "presentation": .bool(false), "items": .array(await log.items.map { .string($0) })])])
            default: return .object([:])
            }
        }, window: window)
        return (m, log)
    }

    @Test func moveRefetchesOnlyTheFolders() async {
        let (m, log) = make()
        await m.refresh()
        await log.put(["a", "c"])   // what the daemon has after the move
        await m.move("a", to: "Cliente")
        #expect(await log.count("artifact.list") == 1)   // the first refresh only
        #expect(m.rows.map(\.folder) == ["Cliente", nil, "Cliente"] && m.rows.map(\.status) == ["current", "current", "current"])
    }

    @Test func changedEventsRefetchFoldersCoalesced() async throws {
        let (m, log) = make(window: .milliseconds(100))
        await m.refresh()
        await log.put(["b"])
        for _ in 0..<20 { await m.handleEvent("artifact.changed") }
        #expect(await pollUntil { await log.count("artifact.folders") == 3 })   // the first at once, one at the window's end
        try await Task.sleep(for: .milliseconds(250))
        #expect(await log.count("artifact.folders") == 3)
        #expect(await log.count("artifact.list") == 1)
        #expect(m.rows.map(\.folder) == [nil, "Cliente", nil])
    }
}
