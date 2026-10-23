import Foundation
import Network
import Testing
import WebKit
import CollieCore
import CollieProtocol
@testable import ColliePlugins

/// A loopback HTTP server (a real origin for storage, a real cache for `reload --hard`). `/sub.js` is cacheable for an
/// hour and answers `window.sub = <hit count>`; `/` is a page that reads `window.__x` in its first inline script.
final class LoopServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var hits = 0
    private(set) var port: UInt16 = 0
    var subHits: Int { lock.withLock { hits } }

    init() async throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        port = try await withCheckedThrowingContinuation { (k: CheckedContinuation<UInt16, any Error>) in
            let once = NSLock(); nonisolated(unsafe) var done = false
            listener.stateUpdateHandler = { [listener] st in
                once.lock(); defer { once.unlock() }
                guard !done else { return }
                if case .ready = st { done = true; k.resume(returning: listener.port!.rawValue) }
                if case .failed(let e) = st { done = true; k.resume(throwing: e) }
            }
            listener.start(queue: .global())
        }
    }
    deinit { listener.cancel() }
    var base: String { "http://127.0.0.1:\(port)" }

    private func serve(_ c: NWConnection) {
        c.start(queue: .global())
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8) else { c.cancel(); return }
            let path = req.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            var type = "text/html", cache = "no-store", body = """
            <!doctype html><title>t</title><script>window.seen = window.__x === undefined ? 'missing' : window.__x</script><script src="/sub.js"></script><p id=p>hi</p>
            """
            if path.hasPrefix("/sub.js") {
                let n = lock.withLock { hits += 1; return hits }
                type = "text/javascript"; cache = "max-age=3600"; body = "window.sub = \(n)"
            }
            let head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nCache-Control: \(cache)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
            c.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in c.cancel() })
        }
    }
}

/// `browser.storage`, `browser.reload`, `browser.init-script`. Local HTML / loopback only.
@MainActor @Suite(.serialized) struct BrowserStorageTests {
    func browser(storage: String? = nil) -> BrowserPanel {
        let state: [String: JSONValue] = storage.map { ["storage": .string($0)] } ?? [:]
        let panel = Panel(id: UUID(), name: "b", pluginId: "browser", placement: .dockRight, state: state)
        return BrowserPanel(panel: panel, host: PanelHostContext(panel: panel, root: FileManager.default.temporaryDirectory,
                                                                 workspaceId: UUID(), call: { _, _ in .null }) { _, _ in })
    }

    func run(_ b: BrowserPanel, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> [String: JSONValue] {
        guard case .object(let o) = try await b.handle(cmd, args) else { return [:] }
        return o
    }

    func js(_ b: BrowserPanel, _ code: String) async throws -> JSONValue? { try await run(b, "browser.eval", ["js": .string(code)])["value"] }

    func goto(_ b: BrowserPanel, _ url: String) async throws { _ = try await run(b, "browser.navigate", ["url": .string(url)]) }

    @Test func setGetAndClearLocalStorage() async throws {
        let s = try await LoopServer(), b = browser(); defer { b.close() }
        try await goto(b, s.base)
        _ = try await run(b, "browser.storage", ["action": .string("set"), "key": .string("k"), "value": .string("v")])
        #expect(try await run(b, "browser.storage", ["action": .string("get"), "key": .string("k")])["value"] == .string("v"))
        #expect(try await js(b, "localStorage.getItem('k')") == .string("v"))
        _ = try await js(b, "sessionStorage.setItem('s', '1')")
        let r = try await run(b, "browser.storage", ["action": .string("clear"), "local": .bool(true)])
        #expect(r["cleared"] == .array([.string("local")]))
        #expect(try await js(b, "localStorage.length") == .number(0))
        #expect(try await js(b, "sessionStorage.length") == .number(1))   // only what was asked
        _ = try await run(b, "browser.storage", ["action": .string("clear")])
        #expect(try await js(b, "sessionStorage.length") == .number(0))
    }

    @Test func valuesAreNeverCode() async throws {
        let s = try await LoopServer(), b = browser(); defer { b.close() }
        try await goto(b, s.base)
        let evil = "'); window.pwned = 1; ('\"\\`${1}"
        _ = try await run(b, "browser.storage", ["action": .string("set"), "key": .string(evil), "value": .string(evil)])
        #expect(try await js(b, "window.pwned") == .null)
        #expect(try await run(b, "browser.storage", ["action": .string("get"), "key": .string(evil)])["value"] == .string(evil))
        #expect(try await run(b, "browser.storage", ["action": .string("get"), "key": .string("none")])["value"] == .null)
    }

    @Test func storageNeedsAnOrigin() async throws {
        let b = browser(); defer { b.close() }
        _ = try await run(b, "browser.navigate", ["url": .string("about:blank")])
        await #expect(throws: ProtocolError.self) { _ = try await b.handle("browser.storage", ["action": .string("get"), "key": .string("k")]) }
        await #expect(throws: ProtocolError.self) { _ = try await b.handle("browser.storage", ["action": .string("nope")]) }
    }

    @Test func setThenReloadPersists() async throws {
        let s = try await LoopServer(), b = browser(); defer { b.close() }
        try await goto(b, s.base)
        _ = try await run(b, "browser.storage", ["action": .string("set"), "key": .string("k"), "value": .string("kept")])
        let r = try await run(b, "browser.reload")
        #expect(r["url"] == .string(s.base + "/"))
        #expect(try await js(b, "localStorage.getItem('k')") == .string("kept"))
    }

    @Test func hardReloadBypassesCache() async throws {
        let s = try await LoopServer(), b = browser(); defer { b.close() }
        try await goto(b, s.base)
        #expect(try await js(b, "window.sub") == .number(1))
        _ = try await run(b, "browser.reload", ["hard": .bool(true)])
        #expect(try await js(b, "window.sub") == .number(2))
        #expect(s.subHits == 2)
    }

    @Test func cookiesClearedPerStore() async throws {
        let s = try await LoopServer(), b = browser(storage: "isolated"); defer { b.close() }
        try await goto(b, s.base)
        _ = try await js(b, "document.cookie = 'a=1; path=/'")
        let store = b.webView!.configuration.websiteDataStore.httpCookieStore
        #expect(await store.allCookies().count == 1)
        let r = try await run(b, "browser.storage", ["action": .string("clear"), "cookies": .bool(true)])
        #expect(r["cookies"] == .number(1))
        #expect(await store.allCookies().isEmpty)
        b.close(); await BrowserPanel.removeStore(b.panel.id)
    }

    @Test func sharedStoreClearsOnlyTheCurrentSite() async throws {
        let s = try await LoopServer(), b = browser(storage: "workspace"); defer { b.close() }
        let store = b.webView!.configuration.websiteDataStore.httpCookieStore
        let other = HTTPCookie(properties: [.name: "o", .value: "1", .domain: "other.test", .path: "/"])!
        await store.setCookie(other)
        try await goto(b, s.base)
        _ = try await js(b, "document.cookie = 'a=1; path=/'")
        let r = try await run(b, "browser.storage", ["action": .string("clear"), "cookies": .bool(true)])
        #expect(r["cookies"] == .number(1))
        #expect(await store.allCookies().map(\.name) == ["o"])
        await store.deleteCookie(other)
        b.close(); await BrowserPanel.removeStore(b.host.workspaceId!)   // the test's own store, not the user's
    }

    @Test func initScriptRunsBeforePage() async throws {
        let s = try await LoopServer(), b = browser(); defer { b.close() }
        let id = try await run(b, "browser.init-script", ["action": .string("add"), "js": .string("window.__x = 'early'")])["id"]
        #expect(id != nil)
        try await goto(b, s.base)
        #expect(try await js(b, "window.seen") == .string("early"))
    }

    @Test func initScriptSurvivesNavigation() async throws {
        let s = try await LoopServer(), b = browser(); defer { b.close() }
        _ = try await run(b, "browser.init-script", ["action": .string("add"), "js": .string("window.__x = 'one'")])
        _ = try await run(b, "browser.init-script", ["action": .string("add"), "js": .string("window.__x += '+two'")])
        try await goto(b, s.base)
        try await goto(b, s.base + "/again")
        #expect(try await js(b, "window.seen") == .string("one+two"))
        // the built-ins still work after the rebuild
        #expect(try await run(b, "browser.snapshot")["output"] != nil)
        _ = try await js(b, "console.log('still')")
        #expect(try await run(b, "browser.console")["output"].map { "\($0)" }?.contains("still") == true)
    }

    @Test func clearInitScripts() async throws {
        let s = try await LoopServer(), b = browser(); defer { b.close() }
        let a = try await run(b, "browser.init-script", ["action": .string("add"), "js": .string("window.__x = 'a'")])["id"]
        let c = try await run(b, "browser.init-script", ["action": .string("add"), "js": .string("window.__x = 'c'")])["id"]
        #expect(a != c)
        guard case .array(let l)? = try await run(b, "browser.init-script", ["action": .string("list")])["scripts"] else { Issue.record("no list"); return }
        #expect(l.count == 2)
        _ = try await run(b, "browser.init-script", ["action": .string("clear"), "id": a ?? .null])
        try await goto(b, s.base)
        #expect(try await js(b, "window.seen") == .string("c"))   // only the cleared one is gone
        _ = try await run(b, "browser.init-script", ["action": .string("clear")])
        try await goto(b, s.base + "/x")
        #expect(try await js(b, "window.seen") == .string("missing"))
        await #expect(throws: ProtocolError.self) { _ = try await b.handle("browser.init-script", ["action": .string("clear"), "id": .string("nope")]) }
    }
}
