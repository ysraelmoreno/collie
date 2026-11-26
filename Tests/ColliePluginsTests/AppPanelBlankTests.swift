import AppKit
import Foundation
import Network
import Testing
import WebKit
import CollieCore
import CollieProtocol
@testable import ColliePlugins

/// Serves a few fixed paths on loopback (an app do cercado's service); `port` fixed: the same port again, after a
/// listener on it was cancelled (the service coming up where the panel already points).
private final class RouteServer: @unchecked Sendable {
    let listener: NWListener
    let port: UInt16
    init(_ routes: [String: (String, String)], port fixed: UInt16? = nil) async throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: fixed.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { c in
            c.start(queue: .global())
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first ?? ""
                let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let (status, type, body) = routes[path].map { ("200 OK", $0.0, Data($0.1.utf8)) } ?? ("404 Not Found", "text/plain", Data())
                let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
            }
        }
        port = try await withCheckedThrowingContinuation { (k: CheckedContinuation<UInt16, any Error>) in
            let once = NSLock(); nonisolated(unsafe) var done = false
            l.stateUpdateHandler = { [l] st in
                once.lock(); defer { once.unlock() }
                guard !done else { return }
                if case .ready = st { done = true; k.resume(returning: l.port!.rawValue) }
                if case .failed(let e) = st { done = true; k.resume(throwing: e) }
            }
            l.start(queue: .global())
        }
        listener = l
    }
    var base: String { "http://127.0.0.1:\(port)" }
    /// Stops listening; returns once the listener is cancelled (its port free again).
    func stop() async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            let once = NSLock(); nonisolated(unsafe) var done = false
            listener.stateUpdateHandler = { st in
                once.lock(); defer { once.unlock() }
                guard !done, case .cancelled = st else { return }
                done = true; k.resume()
            }
            listener.cancel()
        }
    }
}

/// M13.4: an app panel opened right after `collie app attach` (the service still `starting`) stayed all white.
/// Hypothesis 1 (the load runs before the service listens) and 2 (the origin's rule list blocks the page's own
/// `app.js` / `style.css` on first use), each as a scenario; the page reports through `collie.context` that its
/// script ran and its stylesheet applied.
@MainActor @Suite(.serialized, .pt) struct AppPanelBlankTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock(); private var list: [(String, [String: JSONValue])] = []
        func add(_ c: String, _ a: [String: JSONValue]) { lock.withLock { list.append((c, a)) } }
        var contexts: [JSONValue] { lock.withLock { list.filter { $0.0 == "admin.app.context" }.compactMap { $0.1["context"] } } }
    }

    /// Like the Quadro: relative `<script src>` and `<link rel=stylesheet>`.
    static let routes: [String: (String, String)] = [
        "/": ("text/html; charset=utf-8", #"<!doctype html><html><head><link rel="stylesheet" href="style.css"></head><body><h1 id="t">Quadro</h1><script src="app.js"></script></body></html>"#),
        "/style.css": ("text/css", "h1 { color: rgb(255, 0, 0) }"),
        "/app.js": ("text/javascript", #"window.collie.context({ js: true, color: getComputedStyle(document.getElementById("t")).color })"#)]
    static let rendered: JSONValue = .object(["js": .bool(true), "color": .string("rgb(255, 0, 0)")])

    func open(_ base: String, calls: Calls) throws -> (WebPluginPanel, NSWindow) {
        let m = try PluginManifest.decode(try JSONSerialization.data(withJSONObject: [
            "apiVersion": 2, "id": "quadro", "name": "Quadro", "version": "0.1.0", "placements": ["canvas"],
            "ui": base + "/", "service": ["base": base]] as [String: Any]))
        PluginManifest.register([m])
        _ = NSApplication.shared
        let panel = Panel(id: UUID(), name: "quadro-1", pluginId: "quadro", placement: .canvas)
        let host = PanelHostContext(panel: panel, root: FileManager.default.temporaryDirectory.appendingPathComponent("collie-blank-\(UUID().uuidString.prefix(8))"),
                                    workspaceId: nil, call: { c, a in calls.add(c, a); return .object([:]) }, emit: { _, _ in })
        let p = PluginViews.make(panel, host: host) as! WebPluginPanel
        let w = BrowserInput.HostWindow(contentRect: CGRect(x: -20000, y: -20000, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        p.view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        w.contentView?.addSubview(p.view)
        return (p, w)
    }
    func label(_ p: WebPluginPanel) -> String? { (p.view as? WebPluginPanel.Box).flatMap { $0.label.isHidden ? nil : $0.label.stringValue } }
    func retryShown(_ p: WebPluginPanel) -> Bool { p.view.subviews.contains { ($0 as? NSButton)?.title == "Tentar de novo" && !$0.isHidden } }

    /// Hypothesis 1: the panel opens while nothing listens yet; the service then comes up and the daemon says `running`.
    @Test func serviceComesUpAfterThePanelOpened() async throws {
        try await PluginRegistry.exclusively { () async throws in
            let probe = try await RouteServer(Self.routes)
            let port = probe.port
            await probe.stop()   // the port the service will take, nothing on it yet
            let calls = Calls()
            let (p, w) = try open("http://127.0.0.1:\(port)", calls: calls)
            defer { p.close(); w.close(); PluginRegistry.setExternal([]) }

            #expect(await pollUntil(10) { label(p) != nil }, "the load before the service listens shows a line, never a blank page")
            #expect(label(p) == "Iniciando Quadro…", "\(label(p) ?? "nil")")
            let svc = try await RouteServer(Self.routes, port: port)
            defer { svc.listener.cancel() }
            p.receive(event: "collie.service", payload: .object(["state": .string("running")]))
            #expect(await pollUntil(10) { calls.contexts.contains(Self.rendered) }, "the page loads by itself once the service is up")
            #expect(label(p) == nil && p.webView?.isHidden == false)
        }
    }

    /// Hypothesis 2: the service already answers; the page's own `app.js` and `style.css` load on the first open.
    @Test func relativeScriptAndStylesheetLoadOnFirstOpen() async throws {
        try await PluginRegistry.exclusively { () async throws in
            let svc = try await RouteServer(Self.routes)
            defer { svc.listener.cancel() }
            let calls = Calls()
            let (p, w) = try open(svc.base, calls: calls)
            defer { p.close(); w.close(); PluginRegistry.setExternal([]) }
            #expect(await pollUntil(10) { calls.contexts.contains(Self.rendered) }, "\(calls.contexts)")
            #expect(label(p) == nil)
        }
    }

    /// A service that goes down after the page loaded: "não está respondendo", with Tentar de novo (unchanged).
    @Test func serviceDownAfterLoadSaysNotResponding() async throws {
        try await PluginRegistry.exclusively { () async throws in
            let svc = try await RouteServer(Self.routes)
            let calls = Calls()
            let (p, w) = try open(svc.base, calls: calls)
            defer { p.close(); w.close(); PluginRegistry.setExternal([]) }
            #expect(await pollUntil(10) { calls.contexts.contains(Self.rendered) })
            await svc.stop()
            p.webView?.reload()
            #expect(await pollUntil(10) { label(p) != nil })
            #expect(label(p) == "Quadro não está respondendo em 127.0.0.1:\(svc.port)", "\(label(p) ?? "nil")")
            #expect(retryShown(p))
        }
    }

    /// Review A3: the daemon says `running` but nothing answers (wrong port, a process that does not listen): the line
    /// says "não está respondendo em <endereço>", never "Iniciando" again.
    @Test func runningButNotAnsweringSaysNotResponding() async throws {
        try await PluginRegistry.exclusively { () async throws in
            let probe = try await RouteServer(Self.routes)
            let port = probe.port
            await probe.stop()
            let calls = Calls()
            let (p, w) = try open("http://127.0.0.1:\(port)", calls: calls)
            defer { p.close(); w.close(); PluginRegistry.setExternal([]) }
            #expect(await pollUntil(10) { label(p) == "Iniciando Quadro…" }, "\(label(p) ?? "nil")")
            p.receive(event: "collie.service", payload: .object(["state": .string("running")]))
            #expect(await pollUntil(10) { label(p) == "Quadro não está respondendo em 127.0.0.1:\(port)" }, "\(label(p) ?? "nil")")
            #expect(retryShown(p))
        }
    }
}
