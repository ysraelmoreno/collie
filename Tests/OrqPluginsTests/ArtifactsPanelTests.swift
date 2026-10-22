import Foundation
import Testing
import OrqProtocol
@testable import OrqPlugins

private actor Fake {
    var calls: [(String, [String: JSONValue])] = []
    var navigateFails = true
    var listFails = false, rowLimit = Int.max
    /// While held, `artifact.remove` waits for `release()`.
    var holdRemove = false, removeWaiter: CheckedContinuation<Void, Never>?
    func set(fails: Bool, rowLimit: Int = .max) { listFails = fails; self.rowLimit = rowLimit }
    func hold() { holdRemove = true }
    func release() { holdRemove = false; removeWaiter?.resume(); removeWaiter = nil }
    func handle(_ cmd: String, _ a: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        calls.append((cmd, a))
        switch cmd {
        case "browser.navigate" where navigateFails: throw ProtocolError(code: .notFound, message: "Panel not found")
        case "artifact.list":
            if listFails { throw ProtocolError(code: .internal, message: "boom") }
            func row(_ id: String, _ kind: String, _ status: String, file: String? = nil, source: String? = nil, error: String? = nil) -> JSONValue {
                .object(["id": .string(id), "kind": .string(kind), "title": .string("T \(id)"), "file": file.map { .string($0) } ?? .null,
                         "source": source.map { .string($0) } ?? .null, "importError": error.map { .string($0) } ?? .null,
                         "node": .null, "by": .string("app"), "at": .string("2026-10-21T10:00:00Z"), "version": .number(1),
                         "url": .string("orq-artifact://app/\(id)/v1/index.html"), "path": .string("/x"), "thumbnail": .null,
                         "status": .string(status), "warnings": .array([.string("w")])])
            }
            return .array(Array([row("a", "export", "current", file: "Site"), row("b", "export", "stale", file: "Site"), row("c", "export", "missing"),
                           row("d", "export", "unknown", file: "Site"), row("e", "agent", "pending"),
                           row("f", "export", "current", file: "Imp", source: "orq-artifact://app/f/source/index.html"),
                           row("g", "agent", "importing"), row("h", "agent", "failed", source: "orq-artifact://app/h/source/index.html", error: "Orq app is not running")].prefix(rowLimit)))
        case "artifact.remove":
            if holdRemove { await withCheckedContinuation { removeWaiter = $0 } }
            return .object([:])
        default: return .object([:])
        }
    }
    func listCount() -> Int { calls.filter { $0.0 == "artifact.list" }.count }
    func names() -> [String] { calls.map(\.0) }
    func last(_ c: String) -> [String: JSONValue]? { calls.last { $0.0 == c }?.1 }
}

@MainActor private func make(window: Duration = .milliseconds(500)) -> (ArtifactsModel, Fake) {
    let f = Fake()
    return (ArtifactsModel(call: { c, a throws(ProtocolError) in try await f.handle(c, a) }, window: window), f)
}

@MainActor @Suite struct ArtifactsPanelTests {
    @Test func eventsCoalesce() async throws {
        let (m, f) = make(window: .milliseconds(500))
        await m.handleEvent("browser.loaded")   // not ours
        #expect(await f.names().isEmpty)
        for _ in 0..<20 { await m.handleEvent("artifact.imported") }
        #expect(await f.listCount() == 1)   // the first, at once
        #expect(await pollUntil { await f.listCount() == 2 })   // one more at the window's end
        try await Task.sleep(for: .milliseconds(300))
        #expect(await f.listCount() == 2)   // and only one
    }

    @Test func eventRefreshKeepsErrorAndBusy() async throws {
        let (m, f) = make(window: .milliseconds(50))
        await f.set(fails: true)
        await m.refresh()
        #expect(m.error == "boom")
        await f.set(fails: false)
        await m.handleEvent("artifact.imported")   // succeeds, but does not clear what the user saw
        #expect(m.error == "boom" && !m.rows.isEmpty)
        // an action in flight: the event refresh finishing does not end its busy
        await f.hold()
        let row = try #require(m.rows.first)
        let action = Task { await m.remove(row) }
        #expect(await pollUntil { m.busy })
        await f.set(fails: false, rowLimit: 1)   // marks the event refresh's rows
        await m.handleEvent("artifact.imported")   // refreshes (now, or at the window's end) while the removal waits
        #expect(await pollUntil { m.rows.count == 1 })   // that refresh is done
        #expect(m.busy)
        await f.release()
        await action.value
        #expect(!m.busy)
    }

    @Test func closedPanelDoesNotRefresh() async throws {
        let (m, f) = make(window: .milliseconds(50))
        m.stop()
        await m.handleEvent("artifact.imported")
        try await Task.sleep(for: .milliseconds(200))
        #expect(await f.listCount() == 0)
    }

    @Test func artifactSchemeServesOnlyArtifacts() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("art-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let page = base.appendingPathComponent("artifacts/abc/v1")
        try FileManager.default.createDirectory(at: page, withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: page.appendingPathComponent("index.html"))
        try Data("secret".utf8).write(to: base.appendingPathComponent("secret.txt"))
        let removed = base.appendingPathComponent("artifacts/.removed/old")
        try FileManager.default.createDirectory(at: removed, withIntermediateDirectories: true)
        try Data("<p>old</p>".utf8).write(to: removed.appendingPathComponent("index.html"))
        try Data("[]".utf8).write(to: base.appendingPathComponent("artifacts/artifacts.json"))
        let h = DesignSchemeHandler(root: base.appendingPathComponent("artifacts"), artifacts: true)
        func req(_ u: String, main: String? = "orq-artifact://app/abc/v1/index.html") -> URLRequest {
            var r = URLRequest(url: URL(string: u)!); r.mainDocumentURL = main.flatMap(URL.init(string:)); return r
        }
        let (s, type, _) = h.serve(req("orq-artifact://app/abc/v1/index.html"))
        #expect(s == 200 && type.hasPrefix("text/html"))
        for u in ["orq-artifact://app/../secret.txt", "orq-artifact://app/%2e%2e/secret.txt", "orq-artifact://app/artifacts.json",
                  "orq-artifact://app/.removed/old/index.html", "orq-artifact://app/%2eremoved/old/index.html"] {
            #expect(h.serve(req(u)).0 == 404, "\(u)")
        }
        // a subresource of a web page (or of nothing): refused
        #expect(h.serve(req("orq-artifact://app/abc/v1/index.html", main: "https://x/")).0 == 403)
        #expect(h.serve(req("orq-artifact://app/abc/v1/index.html", main: nil)).0 == 403)
        // the Design panel's handler keeps serving without a main document
        let web = base.appendingPathComponent("artifacts/abc/v1")
        #expect(DesignSchemeHandler(root: web).serve(URLRequest(url: URL(string: "orq-design://app/index.html")!)).0 == 200)
    }

    @Test func modelRemovesThenRefreshes() async throws {
        let (m, f) = make()
        await m.refresh()
        let row = try #require(m.rows.last)
        await m.remove(row)
        #expect(await f.last("artifact.remove") == ["id": .string("h")])
        #expect(Array(await f.names().suffix(2)) == ["artifact.remove", "artifact.list"])
    }

    @Test func modelOpensBrowserThenFallsBack() async throws {
        let (m, f) = make()
        await m.refresh()
        let row = try #require(m.rows.first)
        await m.openInBrowser(row)
        #expect(await f.names() == ["artifact.list", "browser.navigate", "panel.open"])
        #expect(await f.last("browser.navigate") == ["panel": .string("Prévia"), "url": .string(row.url)])
        #expect(await f.last("panel.open") == ["plugin": .string("browser"), "name": .string("Prévia"), "url": .string(row.url)])
        #expect(m.error == nil)
    }

    @Test func modelOpensDesignAndReexports() async throws {
        let (m, f) = make()
        await m.refresh()
        let row = try #require(m.rows.first)
        await m.openInDesign(row)
        #expect(await f.last("panel.open") == ["plugin": .string("design"), "file": .string("Site")])
        await m.reexport(row)
        #expect(await f.last("artifact.reexport") == ["id": .string("a")])
        #expect(Array(await f.names().suffix(2)) == ["artifact.reexport", "artifact.list"])
    }

    @Test func rowsDecodeStatuses() async {
        let (m, _) = make()
        await m.refresh()
        #expect(m.rows.prefix(5).map(\.statusLabel) == ["atual", "desatualizado", "origem removida", "desconhecido", "aguardando importação"])
        #expect(m.rows.prefix(5).map(\.origin) == ["tela Site", "tela Site", "tela removida", "tela Site", "HTML do agente"])
        #expect(m.rows[0].warnings == ["w"] && m.rows[0].version == 1)
    }

    @Test func rowsShowImportStates() async {
        let (m, _) = make()
        await m.refresh()
        let (f, g, h) = (m.rows[5], m.rows[6], m.rows[7])
        #expect([f, g, h].map(\.statusLabel) == ["atual", "importando…", "falha na importação"])
        #expect(f.source == "orq-artifact://app/f/source/index.html" && f.importError == nil)
        #expect(g.source == nil && h.importError == "Orq app is not running")
        #expect(m.rows[0].source == nil)
    }

    @Test func modelReimportsThenRefreshes() async throws {
        let (m, f) = make()
        await m.refresh()
        await m.reimport(m.rows[5])   // not failed: nothing sent
        #expect(await f.names() == ["artifact.list"])
        let failed = m.rows[7]
        await m.reimport(failed)
        #expect(await f.last("artifact.import") == ["id": .string("h")])
        #expect(Array(await f.names().suffix(2)) == ["artifact.import", "artifact.list"])
        await m.openSource(failed)
        #expect(await f.last("panel.open") == ["plugin": .string("browser"), "name": .string("Prévia"), "url": .string("orq-artifact://app/h/source/index.html")])
        #expect(m.error == nil)
        // a pending agent page (a 2C page, or an import cut by a restart) imports too
        await m.reimport(m.rows[4])
        #expect(await f.last("artifact.import") == ["id": .string("e")])
    }
}
