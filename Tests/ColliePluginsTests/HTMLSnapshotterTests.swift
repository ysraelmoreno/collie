// Regenerate Tests/Fixtures/html-import/landing-import/ (a copy of the landing page's `.import/`: snapshot.json +
// img-*.png + svg-*.svg; consumed by the importer's mapper tests):
//   COLLIE_REGEN_SNAPSHOT=1 swift test --filter HTMLSnapshotterTests/regenerateLandingSnapshot
import AppKit
import Foundation
import Testing
import CollieProtocol
@testable import ColliePlugins

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/html-import")

/// Real WKWebView; pages served from a temp `artifacts/<id>/source/` folder through `collie-artifact://app/`.
@MainActor @Suite(.serialized) struct HTMLSnapshotterTests {
    struct Site { let root: URL; let id: String; let url: URL; var importDir: URL { root.appendingPathComponent("\(id)/.import") } }

    /// A temp artifacts root with `files` written under `<id>/source/`.
    func site(_ files: [String: Data] = [:], copying dir: URL? = nil) throws -> Site {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString)/artifacts")
        let id = UUID().uuidString.lowercased(), source = root.appendingPathComponent("\(id)/source")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let dir { try FileManager.default.copyItem(at: dir, to: source) }
        else { try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true) }
        for (name, data) in files { try data.write(to: source.appendingPathComponent(name)) }
        return Site(root: root, id: id, url: URL(string: "collie-artifact://app/\(id)/source/index.html")!)
    }

    func run(_ s: Site, timeout: Double = 32) async throws(ProtocolError) -> JSONValue {
        try await HTMLSnapshotter.handle(command: "html.snapshot", args: ["id": .string(s.id), "url": .string(s.url.absoluteString)],
                                         artifactsRoot: s.root, timeoutSeconds: timeout)
    }

    /// The landing page through `html.snapshot`: the reply, the snapshot read back from its file, and its folder.
    func landing() async throws -> (JSONValue, [String: JSONValue], URL) {
        let s = try site(copying: fixtures.appendingPathComponent("landing"))
        try FileManager.default.createDirectory(at: s.importDir, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: s.importDir.appendingPathComponent("stale.txt"))
        let reply = try await run(s)
        let data = try Data(contentsOf: s.importDir.appendingPathComponent("snapshot.json"))
        guard case .object(let o) = try JSONDecoder().decode(JSONValue.self, from: data) else { Issue.record("not an object"); return (reply, [:], s.importDir) }
        return (reply, o, s.importDir)
    }

    static func nodes(_ v: JSONValue?) -> [[String: JSONValue]] {
        guard case .object(let o)? = v else { return [] }
        guard case .array(let cs)? = o["children"] else { return [o] }
        return [o] + cs.flatMap { nodes($0) }
    }
    static func str(_ v: JSONValue?) -> String? { if case .string(let s)? = v { return s }; return nil }
    static func style(_ n: [String: JSONValue], _ k: String) -> String? {
        if case .object(let s)? = n["style"] { return str(s[k]) }; return nil
    }
    static func count(_ n: [String: JSONValue]) -> Int { if case .array(let c)? = n["children"] { return c.count }; return 0 }

    @Test func snapshotsLanding() async throws {
        let (reply, snap, dir) = try await landing()
        #expect(reply == .object(["file": .string(".import/snapshot.json"), "blocked": .number(2), "truncated": .bool(false)]))
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("stale.txt").path))   // replaced, not merged
        #expect((try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int) == 0o700)
        let all = Self.nodes(snap["root"])
        guard case .object(let root)? = snap["root"] else { Issue.record("no root"); return }
        #expect(root["w"] == .number(1440))
        let h1 = try #require(all.first { $0["tag"] == .string("h1") })
        #expect(h1["text"] == .string("Construa telas com seus agentes"))
        #expect(Self.style(h1, "fontSize") == "48px")
        #expect(all.first { $0["tag"] == .string("header") }.map { Self.style($0, "display") } == "flex")
        let cards = try #require(all.first { $0["cls"] == .string("cards") })
        #expect(Self.style(cards, "display") == "grid" && Self.count(cards) == 3)
        let hero = try #require(all.first { $0["alt"] == .string("Prévia da tela") })
        guard case .object(let image)? = hero["image"], let file = Self.str(image["file"]),
              let rep = NSBitmapImageRep(data: try Data(contentsOf: dir.appendingPathComponent(file))) else { Issue.record("hero image: \(hero)"); return }
        #expect(image["data"] == nil && rep.pixelsWide == 64 && rep.pixelsHigh == 40)
        #expect(image["w"] == .number(64) && image["h"] == .number(40) && image["fit"] == .string("cover"))
        let logo = try #require(all.first { $0["cls"] == .string("logo") })
        guard case .object(let svg)? = logo["svg"], let svgFile = Self.str(svg["file"]) else { Issue.record("logo: \(logo)"); return }
        #expect(try String(contentsOf: dir.appendingPathComponent(svgFile), encoding: .utf8).hasPrefix("<svg"))
        let p = try #require(all.first { $0["tag"] == .string("p") && Self.str($0["text"])?.hasPrefix("Descreva") == true })
        guard case .array(let runs)? = p["runs"] else { Issue.record("no runs: \(p)"); return }
        #expect(runs.contains { if case .object(let r) = $0 { return r["fontWeight"] == .string("700") }; return false })
        #expect(runs.contains { if case .object(let r) = $0 { return r["href"] == .string("https://example.com") }; return false })
        #expect(all.contains { $0["text"] == .string("carregado por script") })
        #expect(snap["title"] == .string("Ateliê de telas") && snap["truncated"] == .bool(false))
    }

    /// A page taller than the viewport keeps the requested width even when page CSS forces a classic scrollbar.
    @Test func widthIgnoresScrollbars() async throws {
        let s = try site(["index.html": Data("<style>::-webkit-scrollbar{width:8px!important}</style><body style='height:3000px'>x</body>".utf8)])
        _ = try await run(s)
        let data = try Data(contentsOf: s.importDir.appendingPathComponent("snapshot.json"))
        guard case .object(let o) = try JSONDecoder().decode(JSONValue.self, from: data), case .object(let root)? = o["root"] else { Issue.record("no root"); return }
        #expect(root["w"] == .number(1440) && o["width"] == .number(1440))
    }

    /// A absurd scrollbar width widens the view by at most the clamp (64 px).
    @Test func scrollbarGapIsClamped() async throws {
        let s = try site(["index.html": Data("<style>::-webkit-scrollbar{width:100000px!important}</style><body style='height:3000px'>x</body>".utf8)])
        _ = try await run(s)
        let data = try Data(contentsOf: s.importDir.appendingPathComponent("snapshot.json"))
        guard case .object(let o) = try JSONDecoder().decode(JSONValue.self, from: data), case .number(let w)? = o["width"] else { Issue.record("no width"); return }
        #expect(w <= 1440)
    }

    /// A TCP listener on 127.0.0.1 (ephemeral port); `accepted()` drains its backlog without blocking.
    final class Loopback {
        let fd: Int32, port: Int
        init() throws {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1")
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let ok = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && listen(fd, 32) == 0 && getsockname(fd, $0, &len) == 0
            } }
            try #require(fd >= 0 && ok)
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            self.fd = fd
            port = Int(UInt16(bigEndian: a.sin_port))
        }
        deinit { close(fd) }
        func accepted() -> Int {
            var n = 0
            while case let c = accept(fd, nil, nil), c >= 0 { close(c); n += 1 }
            return n
        }
        /// A plain connect, to show the listener counts.
        func poke() {
            let s = socket(AF_INET, SOCK_STREAM, 0)
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
            a.sin_addr.s_addr = inet_addr("127.0.0.1"); a.sin_port = UInt16(port).bigEndian
            _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            close(s)
        }
    }

    @Test func networkIsBlocked() async throws {
        // fetch, img, WebSocket and a navigation after load, all to a live loopback listener: nothing connects
        let l = try Loopback(), base = "http://127.0.0.1:\(l.port)"
        let page = """
            <body><h1>rede</h1><img src="\(base)/i.png" width="10" height="10">
            <script>
            fetch("\(base)/x").catch(() => {});
            try { new WebSocket("ws://127.0.0.1:\(l.port)/"); } catch (e) {}
            addEventListener("load", () => setTimeout(() => { location.href = "\(base)/nav"; }, 50));
            </script></body>
            """
        let s = try site(["index.html": Data(page.utf8)])
        guard case .object(let o) = try await HTMLSnapshotter.snapshot(url: s.url, artifactsRoot: s.root, width: 800, timeout: .seconds(30))
        else { Issue.record("not an object"); return }
        #expect(Self.nodes(o["root"]).contains { $0["text"] == .string("rede") })
        try await Task.sleep(for: .milliseconds(500))
        #expect(l.accepted() == 0)
        l.poke()
        try await Task.sleep(for: .milliseconds(100))
        #expect(l.accepted() == 1)   // the listener does count

        let (_, snap, _) = try await landing()
        guard case .array(let blocked)? = snap["blocked"] else { Issue.record("no blocked"); return }
        let urls = blocked.compactMap { Self.str($0) }
        #expect(urls.contains { $0.hasPrefix("https://fonts.googleapis.com/") }, "\(urls)")
        #expect(urls.contains("https://example.com/remote.png"), "\(urls)")
        #expect(!urls.contains("https://example.com"))   // a link, not a load
        let remote = try #require(Self.nodes(snap["root"]).first { $0["alt"] == .string("Imagem remota") })
        #expect(remote["image"] == nil)
    }

    /// Final review I1: WebRTC (ICE over UDP) gets past the content rules; the snapshot page must not have it.
    @Test func webRTCOff() async throws {
        let page = "<title>t</title><body><script>document.title = typeof RTCPeerConnection + '/' + typeof webkitRTCPeerConnection</script></body>"
        let s = try site(["index.html": Data(page.utf8)])
        guard case .object(let o) = try await HTMLSnapshotter.snapshot(url: s.url, artifactsRoot: s.root, width: 800, timeout: .seconds(30))
        else { Issue.record("not an object"); return }
        #expect(o["title"] == .string("undefined/undefined"))
    }

    @Test func runsKeepOffsetsAcrossCaseAndNbsp() async throws {
        let html = #"<p style="text-transform: uppercase">a\#u{00A0}b <b>forte</b> fim</p>"#
        let s = try site(["index.html": Data(html.utf8)])
        guard case .object(let o) = try await HTMLSnapshotter.snapshot(url: s.url, artifactsRoot: s.root, width: 800, timeout: .seconds(30))
        else { Issue.record("not an object"); return }
        let p = try #require(Self.nodes(o["root"]).first { $0["tag"] == .string("p") })
        let text = try #require(Self.str(p["text"]))
        guard case .array(let runs)? = p["runs"], case .object(let r)? = runs.first,
              case .number(let a)? = r["start"], case .number(let b)? = r["end"] else { Issue.record("no runs: \(p)"); return }
        let u = Array(text.utf16)
        #expect(String(decoding: u[Int(a)..<Int(b)], as: UTF16.self) == "FORTE", "\(text) \(r)")
    }

    @Test func buttonsWithElementsAreContainers() async throws {
        let html = #"""
            <body style="color: rgb(10, 20, 30)">
            <button id="b" style="display: flex; color: rgb(255, 0, 0)"><svg viewBox="0 0 10 10" style="width: 16px; height: 16px"><path d="M0 0h10v10z" fill="currentColor" style="stroke: currentColor"/></svg>Capítulos<span style="display: inline-block; border-radius: 9px">7</span></button>
            <button id="t">Só texto</button>
            <input id="c" type="checkbox"><input id="p" type="password" value="abc"><input id="s" type="search" placeholder="Buscar">
            </body>
            """#
        let s = try site(["index.html": Data(html.utf8)])
        guard case .object(let o) = try await HTMLSnapshotter.snapshot(url: s.url, artifactsRoot: s.root, width: 800, timeout: .seconds(30))
        else { Issue.record("not an object"); return }
        let all = Self.nodes(o["root"])
        let b = try #require(all.first { $0["id"] == .string("b") })
        #expect(b["text"] == nil && Self.style(b, "display") == "flex")
        let kids = Self.nodes(.object(b)).dropFirst()
        #expect(kids.map { Self.str($0["tag"]) } == ["svg", "#text", "span"], "\(kids)")
        let svg = try #require(Self.str(kids.first?["svg"]))
        #expect(!svg.lowercased().contains("currentcolor") && svg.contains("rgb(255, 0, 0)"), "\(svg)")
        #expect(svg.contains(#"width="16""#) && svg.contains(#"height="16""#))
        #expect(kids.last?["text"] == .string("7"))
        #expect(all.first { $0["id"] == .string("t") }?["text"] == .string("Só texto"))
        #expect(all.first { $0["id"] == .string("c") }.map { $0["text"] == nil } == true)
        #expect(all.first { $0["id"] == .string("p") }?["text"] == .string("•••"))
        #expect(all.first { $0["id"] == .string("s") }?["text"] == .string("Buscar"))
    }

    @Test func largePhotosAreDrawnAtTwiceTheirBox() async throws {
        // 3000×2000 of noise: far over the 4 MiB cap at natural size
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3000, pixelsHigh: 2000, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        var g = SystemRandomNumberGenerator()
        let bytes = rep.bytesPerRow * 2000
        for i in 0..<bytes { rep.bitmapData![i] = UInt8.random(in: 0...255, using: &g) }
        let png = try #require(rep.representation(using: .png, properties: [:]))
        #expect(png.count > 4 << 20)
        let html = #"<img src="big.png" style="width: 300px; height: 200px; object-fit: cover">"#
        let s = try site(["index.html": Data(html.utf8), "big.png": png])
        guard case .object(let o) = try await HTMLSnapshotter.snapshot(url: s.url, artifactsRoot: s.root, width: 800, timeout: .seconds(30))
        else { Issue.record("not an object"); return }
        let img = try #require(Self.nodes(o["root"]).first { $0["tag"] == .string("img") })
        guard case .object(let image)? = img["image"], let data = Self.str(image["data"]).flatMap({ Data(base64Encoded: $0) }),
              let back = NSBitmapImageRep(data: data) else { Issue.record("no payload: \(img["w"] ?? .null)"); return }
        #expect(back.pixelsWide == 600 && back.pixelsHigh == 400)
    }

    @Test func capsAndTimeout() async throws {
        let many = "<body>" + String(repeating: "<div>x</div>", count: 5000) + "</body>"
        let big = try site(["index.html": Data(many.utf8)])
        let snap = try await HTMLSnapshotter.snapshot(url: big.url, artifactsRoot: big.root, width: 800, timeout: .seconds(30))
        guard case .object(let o) = snap else { Issue.record("not an object"); return }
        #expect(o["truncated"] == .bool(true))
        #expect(Self.nodes(o["root"]).count <= 3000)

        // hung while loading (no didFinish) and hung after it (the script never runs)
        for page in ["<body><script>while(true){}</script></body>",
                     #"<body><h1>x</h1><script>addEventListener("load", () => setTimeout(() => { for (;;) {} }, 0))</script></body>"#] {
            let loop = try site(["index.html": Data(page.utf8)])
            let t0 = ContinuousClock.now
            await #expect(throws: ProtocolError(code: .timeout, message: "html.snapshot timed out after 5 s")) {
                _ = try await run(loop, timeout: 7)   // the call's 7 s minus 2
            }
            #expect(ContinuousClock.now - t0 <= .seconds(7))
            // the view (and its WebContent process) is let go; the next snapshot gets new ones
            let end = ContinuousClock.now + .seconds(10)
            while HTMLSnapshotter.lastWebView != nil, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(100)) }
            #expect(HTMLSnapshotter.lastWebView == nil, "\(page)")
            let ok = try site(["index.html": Data("<h1>depois</h1>".utf8)])
            guard case .object(let a) = try await HTMLSnapshotter.snapshot(url: ok.url, artifactsRoot: ok.root, width: 800, timeout: .seconds(30))
            else { Issue.record("not an object"); return }
            #expect(Self.nodes(a["root"]).contains { $0["text"] == .string("depois") })
        }
    }

    @Test func refusesBadArgs() async throws {
        let s = try site(["index.html": Data("<h1>x</h1>".utf8)])
        func code(_ cmd: String, _ args: [String: JSONValue]) async -> ErrorCode? {
            do { _ = try await HTMLSnapshotter.handle(command: cmd, args: args, artifactsRoot: s.root, timeoutSeconds: 30); return nil }
            catch { return error.code }
        }
        for u in ["https://example.com/", "file:///etc/hosts"] {
            #expect(await code("html.snapshot", ["id": .string(s.id), "url": .string(u)]) == .invalidArgs)
        }
        #expect(await code("html.other", [:]) == .invalidArgs)
        #expect(await code("html.snapshot", ["id": .string(s.id), "url": .string(s.url.absoluteString), "width": .number(100)]) == .invalidArgs)
        #expect(await code("html.snapshot", ["id": .string("../x"), "url": .string(s.url.absoluteString)]) == .invalidArgs)
        #expect(await code("html.snapshot", ["id": .string(UUID().uuidString), "url": .string(s.url.absoluteString)]) == .notFound)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["COLLIE_REGEN_SNAPSHOT"] != nil))
    func regenerateLandingSnapshot() async throws {
        let (_, snap, dir) = try await landing()
        let out = fixtures.appendingPathComponent("landing-import"), fm = FileManager.default
        try? fm.removeItem(at: out)
        try fm.copyItem(at: dir, to: out)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(JSONValue.object(snap)).write(to: out.appendingPathComponent("snapshot.json"))
    }
}
