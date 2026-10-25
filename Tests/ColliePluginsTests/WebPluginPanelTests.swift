import AppKit
import Darwin
import Foundation
import Testing
import WebKit
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit
@testable import ColliePlugins

private let notasSource = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Examples/plugins/notas")

/// A page that misbehaves on purpose (Review Focus 3), plus a few API probes.
private let hostileJS = #"""
collie.onCommand(async (name, args) => {
  switch (name) {
  case "hang": case "wait": return new Promise(() => {});
  case "big": return "x".repeat(2 * 1024 * 1024);
  case "ping": return "pong";
  case "probe": {
    const port = args.port, out = {};
    try { await fetch(`http://127.0.0.1:${port}/f`); out.fetch = "ok" } catch (e) { out.fetch = "blocked" }
    out.img = await new Promise(r => { const i = new Image(); i.onload = () => r("ok"); i.onerror = () => r("blocked"); i.src = `http://127.0.0.1:${port}/i.png` });
    try {
      const w = new WebSocket(`ws://127.0.0.1:${port}/w`);
      out.ws = await new Promise(r => { w.onopen = () => r("ok"); w.onerror = () => r("blocked"); setTimeout(() => r("blocked"), 2000) });
    } catch (e) { out.ws = "blocked" }
    out.open = window.open(`http://127.0.0.1:${port}/o`) ? "ok" : "blocked";
    return out;
  }
  case "leave": setTimeout(() => { location.href = "file:///etc/passwd" }, 0); return "went";
  case "emit": {
    const r = {};
    try { await collie.emit("other.x", {}); r.bad = "sent" } catch (e) { r.bad = "refused" }
    try { await collie.emit("hostil.ok", { n: 1 }); r.good = "sent" } catch (e) { r.good = "refused" }
    return r;
  }
  case "fakepath": return { path: "/etc/hosts" };
  case "bigstate": try { await collie.state.set({ s: "x".repeat(300 * 1024) }); return "stored" } catch (e) { return "refused" }
  case "rtc": {
    if (typeof RTCPeerConnection === "undefined" && typeof webkitRTCPeerConnection === "undefined") return "none";
    const pc = new RTCPeerConnection({ iceServers: [{ urls: `stun:127.0.0.1:${args.port}` }] });
    pc.createDataChannel("x");
    await pc.setLocalDescription(await pc.createOffer());
    await new Promise(r => setTimeout(r, 1500));
    pc.close(); return "tried";
  }
  case "media": {
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) return "none";
    try { await navigator.mediaDevices.getUserMedia({ video: true, audio: true }); return "granted" } catch (e) { return "denied" }
  }
  case "two": { await collie.files.output("a.txt", btoa("1")); return collie.files.output("a.txt", btoa("2")) }
  case "many": { let last; for (let i = 0; i < 102; i++) last = await collie.files.output(`f${i}.txt`, btoa(String(i))); return last }
  case "out1": try { return await collie.files.output("a.txt", btoa("x")) } catch (e) { return { refused: String(e.message || e) } }
  case "nav": setTimeout(() => { location.href = "index.html" }, 0); return "ok";
  case "ver": return window.V;
  case "theme": return collie.theme.scheme + " " + getComputedStyle(document.documentElement).getPropertyValue("--collie-text").trim();
  }
  throw new Error("unknown " + name);
});
"""#

/// Plug-ins installed into a temp root (the daemon's store, as the user's install would) and registered in this
/// process, panels hosted in an off-screen window.
@MainActor @Suite(.serialized) struct WebPluginPanelTests {
    final class Emits: @unchecked Sendable {
        private let lock = NSLock(); private var list: [String] = []
        func add(_ n: String) { lock.withLock { list.append(n) } }
        var all: [String] { lock.withLock { list } }
    }
    let root = URL(fileURLWithPath: "/tmp/collie-wp-\(UUID().uuidString.prefix(8))")
    let emits = Emits()
    var store: PluginStore { PluginStore(root: root) }

    func hostil(version: String = "0.1.0") throws -> URL {
        let d = root.appendingPathComponent("src-hostil-\(version)")
        try FileManager.default.createDirectory(at: d.appendingPathComponent("ui"), withIntermediateDirectories: true)
        func c(_ n: String, timeout: Int = 30, out: Bool = false, params: [[String: Any]] = []) -> [String: Any] {
            ["name": n, "summary": n, "runs": "ui", "timeout": timeout, "outputFile": out, "params": params]
        }
        let m: [String: Any] = ["apiVersion": 1, "id": "hostil", "name": "Hostil", "version": version, "ui": "ui/index.html",
                                "events": ["hostil.ok"], "commands": [c("hang", timeout: 1), c("wait"), c("big"), c("ping"), c("leave"), c("emit"),
                                c("rtc", params: [["name": "port", "type": "int"]]), c("media", timeout: 5), c("two"), c("many"), c("out1"), c("nav"), c("ver"),
                                c("probe", params: [["name": "port", "type": "int"]]), c("fakepath", out: true), c("bigstate"), c("theme")]]
        try JSONSerialization.data(withJSONObject: m).write(to: d.appendingPathComponent("collie-plugin.json"))
        try "<!doctype html><html><body><script>window.V = \"\(version)\"</script><script src=\"app.js\"></script></body></html>".write(to: d.appendingPathComponent("ui/index.html"), atomically: true, encoding: .utf8)
        try hostileJS.write(to: d.appendingPathComponent("ui/app.js"), atomically: true, encoding: .utf8)
        return d
    }

    /// Installs and registers what the store then has loaded.
    func install(_ src: URL) async throws {
        let s = PluginStore(root: root)
        _ = try await s.install(from: src)
        PluginManifest.register(await s.loaded().map(\.0))
    }
    func uninstall(_ id: String) async throws {
        let s = PluginStore(root: root)
        try await s.uninstall(id)
        PluginManifest.register(await s.loaded().map(\.0))
    }

    func open(_ pluginId: String, id: UUID = UUID()) -> (WebPluginPanel, NSWindow) {
        _ = NSApplication.shared
        let panel = Panel(id: id, name: pluginId, pluginId: pluginId, placement: .canvas)
        let e = emits
        let host = PanelHostContext(panel: panel, root: root, workspaceId: nil, call: { _, _ in .null }, emit: { n, _ in e.add(n) })
        let p = PluginViews.make(panel, host: host) as! WebPluginPanel
        let w = BrowserInput.HostWindow(contentRect: CGRect(x: -20000, y: -20000, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        p.view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        w.contentView?.addSubview(p.view)
        return (p, w)
    }
    func cleanup(_ ps: [(WebPluginPanel, NSWindow)]) {
        for (p, w) in ps { p.close(); w.close() }
        PluginRegistry.setExternal([])
        PluginStore.removeTree(root)
    }
    func code(_ body: () async throws -> Void) async -> ProtocolError? {
        do { try await body(); return nil } catch let e as ProtocolError { return e } catch { return ProtocolError(code: .internal, message: "\(error)") }
    }
    func obj(_ v: JSONValue) -> [String: JSONValue] { if case .object(let o) = v { return o }; return [:] }

    @Test func notasAddThenList() async throws {
        try await PluginRegistry.exclusively { () async throws in
        try await install(notasSource)
        let x = open("notas"); defer { cleanup([x]) }
        let added = obj(try await x.0.handle("notas.add", ["text": .string("comprar café")]))
        #expect(added["text"] == .string("comprar café") && added["id"] == .number(1))
        guard case .array(let notes) = try await x.0.handle("notas.list", [:]) else { Issue.record("not a list"); return }
        #expect(notes.count == 1)
        #expect(await pollUntil { emits.all.contains("notas.changed") })
        }
    }

    @Test func commandTimeout() async throws {
        try await PluginRegistry.exclusively { () async throws in
        try await install(try hostil())
        let x = open("hostil"); defer { cleanup([x]) }
        _ = try await x.0.handle("hostil.ping", [:])   // loaded
        let t0 = ContinuousClock.now
        let e = await code { _ = try await x.0.handle("hostil.hang", [:]) }
        let took = ContinuousClock.now - t0
        #expect(e?.code == .timeout && took >= .seconds(1) && took < .seconds(4), "\(String(describing: e)) \(took)")
        #expect(try await x.0.handle("hostil.ping", [:]) == .string("pong"))   // still responsive
        }
    }

    @Test func resultOver1MiBRefused() async throws {
        try await PluginRegistry.exclusively { () async throws in
        try await install(try hostil())
        let x = open("hostil"); defer { cleanup([x]) }
        let e = await code { _ = try await x.0.handle("hostil.big", [:]) }
        #expect(e?.code == .invalidArgs && e?.message.contains("1 MiB") == true, "\(String(describing: e))")
        #expect(try await x.0.handle("hostil.ping", [:]) == .string("pong"))
        }
    }

    /// Review Focus 3: no request leaves the page (a local listener sees no connection), no window opens, no navigation
    /// away from the plug-in.
    @Test func networkBlocked() async throws {
        try await PluginRegistry.exclusively { () async throws in
        let fd = socket(AF_INET, SOCK_STREAM, 0); defer { Darwin.close(fd) }
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        listen(fd, 8)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let port = Int(UInt16(bigEndian: addr.sin_port))

        try await install(try hostil())
        let x = open("hostil"); defer { cleanup([x]) }
        let r = obj(try await x.0.handle("hostil.probe", ["port": .number(Double(port))]))
        #expect(r["fetch"] == .string("blocked") && r["img"] == .string("blocked") && r["ws"] == .string("blocked") && r["open"] == .string("blocked"), "\(r)")
        #expect(accept(fd, nil, nil) < 0 && errno == EAGAIN, "a request reached the listener")
        _ = try await x.0.handle("hostil.leave", [:])
        try await Task.sleep(for: .milliseconds(500))
        #expect(x.0.webView?.url?.scheme == "collie-plugin", "\(String(describing: x.0.webView?.url))")
        #expect(try await x.0.handle("hostil.ping", [:]) == .string("pong"))
        }
    }

    @Test func schemeRefusesTraversal() throws {
        let ui = root.appendingPathComponent("plugins/notas/0.1.0/ui")
        try FileManager.default.createDirectory(at: ui, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "<html></html>".write(to: ui.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "[]".write(to: root.appendingPathComponent("plugins/installed.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: ui.appendingPathComponent("l.json").path, withDestinationPath: root.appendingPathComponent("plugins/installed.json").path)
        let h = PluginSchemeHandler(id: "notas", uiRoot: ui)
        func serve(_ u: String, _ m: String = "GET") -> Int { var r = URLRequest(url: URL(string: u)!); r.httpMethod = m; return h.serve(r).0 }
        #expect(serve("collie-plugin://notas/index.html") == 200 && h.serve(URLRequest(url: URL(string: "collie-plugin://notas/index.html")!)).1.hasPrefix("text/html"))
        for u in ["collie-plugin://notas/../../installed.json", "collie-plugin://notas/%2e%2e/%2e%2e/installed.json", "collie-plugin://notas/%2E%2E%2F%2E%2E%2Finstalled.json",
                  "collie-plugin://notas/l.json", "collie-plugin://other/index.html", "collie-plugin://notas/", "collie-plugin://notas/missing.js"] {
            #expect(serve(u) == 404, "\(u)")
        }
        #expect(serve("collie-plugin://notas/index.html", "POST") == 405)
    }

    @Test func undeclaredEventRefused() async throws {
        try await PluginRegistry.exclusively { () async throws in
        try await install(try hostil())
        let x = open("hostil"); defer { cleanup([x]) }
        let r = obj(try await x.0.handle("hostil.emit", [:]))
        #expect(r["bad"] == .string("refused") && r["good"] == .string("sent"), "\(r)")
        #expect(emits.all == ["hostil.ok"])
        }
    }

    @Test func stateRoundTripAndDeletedWithPanel() async throws {
        try await PluginRegistry.exclusively { () async throws in
        try await install(notasSource)
        let id = UUID()
        let a = open("notas", id: id)
        _ = try await a.0.handle("notas.add", ["text": .string("um")])
        a.0.close(); a.1.close()
        let b = open("notas", id: id); defer { cleanup([b]) }
        guard case .array(let notes) = try await b.0.handle("notas.list", [:]) else { Issue.record("not a list"); return }
        #expect(notes.count == 1)   // restored from the panel's state file
        let f = WebPluginPanel.stateFile(b.0.panel, root: root)
        #expect(FileManager.default.fileExists(atPath: f.path))
        #expect((try FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try await install(try hostil())
        let h = open("hostil"); defer { h.0.close(); h.1.close() }
        #expect(try await h.0.handle("hostil.bigstate", [:]) == .string("refused"))   // > 256 KiB
        WebPluginPanel.panelRemoved(b.0.panel, host: b.0.host)
        #expect(!FileManager.default.fileExists(atPath: f.path))
        }
    }

    @Test func outputFileReturnsPathUnderPluginsOut() async throws {
        try await PluginRegistry.exclusively { () async throws in
        try await install(notasSource)
        let x = open("notas"); defer { cleanup([x]) }
        _ = try await x.0.handle("notas.add", ["text": .string("comprar café")])
        guard case .string(let p)? = obj(try await x.0.handle("notas.export", ["format": .string("md")]))["path"] else { Issue.record("no path"); return }
        let screens = root.appendingPathComponent("plugins-out/notas").path + "/"
        #expect(p.hasPrefix(screens) && URL(fileURLWithPath: p).lastPathComponent.hasPrefix(x.0.panel.id.uuidString + "-") && p.hasSuffix("notas.md"), "\(p)")
        #expect(try String(contentsOfFile: p, encoding: .utf8).contains("- comprar café"))
        #expect(!p.dropFirst(screens.count).contains("/"))   // directly in plugins-out/notas/: the router hands over only these (R6)
        // an output command can't hand over a path of its own choosing
        try await install(try hostil())
        let h = open("hostil"); defer { h.0.close(); h.1.close() }
        #expect(await code { _ = try await h.0.handle("hostil.fakepath", [:]) }?.code == .invalidArgs)
        WebPluginPanel.panelRemoved(x.0.panel, host: x.0.host)
        #expect(!FileManager.default.fileExists(atPath: p))
        }
    }

    @Test func missingPluginShowsPlaceholder() async throws {
        try await PluginRegistry.exclusively { () async throws in
        let x = open("ghost"); defer { cleanup([x]) }
        #expect(x.0.webView == nil && x.0.view.subviews.contains { ($0 as? NSTextField)?.stringValue == "Plug-in ghost não está instalado" })
        #expect(await code { _ = try await x.0.handle("ghost.add", [:]) }?.code == .unavailable)
        #expect(x.0.version == nil)
        }
    }

    /// Review Focus 1 and 2: removal fails the call in flight and shows the placeholder; a new version reloads.
    @Test func uninstallDuringCallFailsUnavailable() async throws {
        try await PluginRegistry.exclusively { () async throws in
        try await install(try hostil())
        let x = open("hostil"); defer { cleanup([x]) }
        #expect(try await x.0.handle("hostil.ping", [:]) == .string("pong"))
        let p = x.0
        let call = Task { @MainActor in await code { _ = try await p.handle("hostil.wait", [:]) } }
        try await Task.sleep(for: .milliseconds(300))
        let t0 = ContinuousClock.now
        try await uninstall("hostil")
        let e = await call.value
        #expect(e?.code == .unavailable && e?.message == "plug-in removido" && ContinuousClock.now - t0 < .seconds(3), "\(String(describing: e))")
        #expect(await pollUntil { x.0.webView == nil && x.0.version == nil })
        #expect(x.0.view.subviews.contains { ($0 as? NSTextField)?.stringValue == "Plug-in hostil não está instalado" })
        try await install(try hostil(version: "0.2.0"))
        #expect(await pollUntil { x.0.version == "0.2.0" })
        #expect(try await x.0.handle("hostil.ping", [:]) == .string("pong"))
        try await install(try hostil(version: "0.3.0"))
        #expect(await pollUntil { x.0.version == "0.3.0" })
        guard case .string(let theme) = try await x.0.handle("hostil.theme", [:]) else { Issue.record("no theme"); return }
        #expect((theme.hasPrefix("light #") || theme.hasPrefix("dark #")) && theme.count == "light #000000".count + (theme.hasPrefix("dark") ? -1 : 0), "\(theme)")
        }
    }

    /// Task 3 review C1: WebRTC (ICE over UDP) gets past content rules and CSP; it must not exist in the page.
    @Test func webRTCBlocked() async throws {
        try await PluginRegistry.exclusively { () async throws in
        let fd = socket(AF_INET, SOCK_DGRAM, 0); defer { Darwin.close(fd) }
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        try await install(try hostil())
        let x = open("hostil"); defer { cleanup([x]) }
        let r = try await x.0.handle("hostil.rtc", ["port": .number(Double(UInt16(bigEndian: addr.sin_port)))])
        var buf = [UInt8](repeating: 0, count: 512)
        #expect(recv(fd, &buf, buf.count, 0) < 0 && errno == EAGAIN, "a datagram reached the listener")
        #expect(r == .string("none"), "\(r)")
        // and the camera and microphone are never granted
        let m = try await x.0.handle("hostil.media", [:])
        #expect(m == .string("none") || m == .string("denied"), "\(m)")
        }
    }

    /// M1, M2, M8: unique names in plugins-out/<id>, the newest 100 kept, a linked dir refused.
    @Test func outputFilesUniqueCappedNoFollow() async throws {
        try await PluginRegistry.exclusively { () async throws in
        try await install(try hostil())
        let x = open("hostil"); defer { cleanup([x]) }
        let dir = root.appendingPathComponent("plugins-out/hostil")
        _ = try await x.0.handle("hostil.two", [:])
        let two = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let bodies = Set(try two.map { try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) })
        #expect(two.count == 2 && bodies == ["1", "2"], "\(two)")
        _ = try await x.0.handle("hostil.many", [:])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 100)
        try FileManager.default.removeItem(at: dir)
        let elsewhere = root.appendingPathComponent("elsewhere"); try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dir.path, withDestinationPath: elsewhere.path)
        let r = obj(try await x.0.handle("hostil.out1", [:]))
        #expect(r["refused"] != nil, "\(r)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        }
    }

    /// M3: a navigation inside the plug-in waits for the new page's handler; M5: a new version answers at once.
    @Test func navigationAndVersionSwap() async throws {
        try await PluginRegistry.exclusively { () async throws in
        try await install(try hostil())
        let x = open("hostil"); defer { cleanup([x]) }
        #expect(try await x.0.handle("hostil.nav", [:]) == .string("ok"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(try await x.0.handle("hostil.ping", [:]) == .string("pong"))
        try await install(try hostil(version: "0.2.0"))
        #expect(try await x.0.handle("hostil.ver", [:]) == .string("0.2.0"))   // no window where the old page answers
        }
    }

    /// M4: a page whose process keeps dying is reloaded a few times, then left as a placeholder.
    @Test func crashLoopStops() async throws {
        try await PluginRegistry.exclusively { () async throws in
        try await install(try hostil())
        let x = open("hostil"); defer { cleanup([x]) }
        _ = try await x.0.handle("hostil.ping", [:])
        for _ in 0..<4 { if let w = x.0.webView { x.0.webViewWebContentProcessDidTerminate(w) } }
        #expect(x.0.webView == nil && x.0.view.subviews.contains { ($0 as? NSTextField)?.stringValue.contains("parou várias vezes") == true })
        }
    }
}
