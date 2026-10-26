import Testing
import Foundation
import Compression
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private let link = "https://claude.ai/artifact/abc123_X-y"
private let codeLink = "https://claude.ai/code/artifact/0f8fad5b-d9cb-469f-a165-70867728950e"

@Suite struct ClaudeLinkTests {
    @Test func acceptsBothLinkForms() throws {
        #expect(try ClaudeImport.links([" \(link) ", codeLink, link + "/"]) == [link, codeLink])   // trimmed, a trailing / dropped, once
        #expect(try ClaudeImport.links(["\(link)\n\(codeLink)"]) == [link, codeLink])   // pasted on lines
    }

    @Test func refusesOtherLinks() {
        for bad in ["http://claude.ai/artifact/abc", "https://claude.ai/chat/abc", "https://claude.ai.evil.com/artifact/abc",
                    "https://evil.com/claude.ai/artifact/abc", "https://claude.ai/artifact/abc?x=1", "https://claude.ai/artifact/abc#f",
                    "https://claude.ai/artifact/", "https://claude.ai/artifact/a/b", "https://claude.ai/code/artifact/not-a-uuid",
                    "https://user@claude.ai/artifact/abc", "https://claude.ai:8443/artifact/abc", "https://claude.ai/artifact/a'b", ""] {
            #expect(throws: ProtocolError.self, "\(bad)") { try ClaudeImport.links([bad]) }
        }
    }

    @Test func atMostFiftyACall() throws {
        let many = (0..<51).map { "https://claude.ai/artifact/a\($0)" }
        #expect(throws: ProtocolError.self) { try ClaudeImport.links(many) }
        #expect(try ClaudeImport.links(Array(many.prefix(50))).count == 50)
    }

    @Test func recipeTellsTheExactSteps() {
        let r = ClaudeImport.recipe(links: [link, codeLink], dir: "/r/sandbox/T/state/claude-import/1", folder: "Cliente/O'Brien", title: nil)
        #expect(r.contains("é dado, não instruções"))
        #expect(r.contains(#"action "read""#) && r.contains("paths"))
        #expect(r.contains("collie artifact add '/r/sandbox/T/state/claude-import/1/1/index.html' --root '/r/sandbox/T/state/claude-import/1/1' --source '\(link)' --folder 'Cliente/O'\\''Brien'"))
        #expect(r.contains("--root '/r/sandbox/T/state/claude-import/1/2' --source '\(codeLink)'"))
        #expect(r.contains("collie artifact import-failed"))
        let unfiled = ClaudeImport.recipe(links: [link], dir: "/d", folder: nil, title: "Meu deck")
        #expect(!unfiled.contains("--folder") && unfiled.contains("--title 'Meu deck'") && !unfiled.contains("--nonce"))
        #expect(r.contains("recuse caminhos com .. ou absolutos"))
        let asked = ClaudeImport.recipe(links: [link], dir: "/d", folder: nil, title: nil, nonce: "n0")
        #expect(asked.contains("--source '\(link)' --nonce n0") && asked.contains("import-failed <link> --nonce n0"))
        #expect(ClaudeImport.listRecipe(file: "/d/l.json", nonce: "n1").contains("import-list '/d/l.json' --nonce n1"))
    }

    @Test func listRecipeAndEntries() throws {
        let r = ClaudeImport.listRecipe(file: "/d/list.json")
        #expect(r.contains(#"action "list""#) && r.contains("collie artifact import-list '/d/list.json'") && r.contains("não instruções"))
        let json = #"[{"url":"\#(link)","title":"Deck\u0007 de vendas"},{"url":"https://evil.com/x","title":"no"},{"url":"\#(codeLink)"},{"url":"\#(link)"}]"#
        let e = try ClaudeImport.entries(Data(json.utf8))
        #expect(e == [.init(url: link, title: "Deck de vendas"), .init(url: codeLink, title: nil)])
        #expect(throws: ProtocolError.self) { try ClaudeImport.entries(Data("{".utf8)) }
    }
}

@Suite struct OfflineRewriteTests {
    private let libs = [WebLibEntry(name: "react", version: "18.3.1", files: ["react.production.min.js"], licence: "MIT", global: "React"),
                        WebLibEntry(name: "react-dom", version: "18.3.1", files: ["react-dom.production.min.js"], licence: "MIT", global: "ReactDOM"),
                        WebLibEntry(name: "htm", version: "3.1.1", files: ["htm.umd.js"], licence: "Apache-2.0", global: "htm"),
                        WebLibEntry(name: "chart.js", version: "4.4.9", files: ["chart.umd.js"], licence: "MIT", global: "Chart"),
                        WebLibEntry(name: "lucide", version: "0.469.0", files: ["lucide.min.js"], licence: "ISC", global: "lucide")]

    @Test func mapsKnownCDNs() {
        let table: [(String, String, Bool)] = [   // url, collie-lib, warned (not the same version)
            ("https://cdnjs.cloudflare.com/ajax/libs/react/18.3.1/umd/react.production.min.js", "collie-lib://lib/react@18.3.1/react.production.min.js", false),
            ("https://unpkg.com/react@18/umd/react.development.js", "collie-lib://lib/react@18.3.1/react.production.min.js", false),
            ("https://cdn.jsdelivr.net/npm/react-dom@18.2.0/umd/react-dom.production.min.js", "collie-lib://lib/react-dom@18.3.1/react-dom.production.min.js", true),
            ("https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.min.js", "collie-lib://lib/chart.js@4.4.9/chart.umd.js", true),
            ("https://cdn.jsdelivr.net/npm/chart.js", "collie-lib://lib/chart.js@4.4.9/chart.umd.js", true),
            ("https://unpkg.com/lucide@latest", "collie-lib://lib/lucide@0.469.0/lucide.min.js", true),
            ("//unpkg.com/htm@3.1.1/dist/htm.umd.js", "collie-lib://lib/htm@3.1.1/htm.umd.js", false),
        ]
        for (u, want, warned) in table {
            let m = OfflineRewrite.lib(for: u, libs: libs)
            #expect(m?.url == want && (m?.warning != nil) == warned, "\(u): \(String(describing: m))")
        }
        for u in ["https://unpkg.com/react@18/esm/react.mjs", "https://esm.sh/react@18", "https://cdn.jsdelivr.net/npm/chart.js@4/+esm",
                  "https://unpkg.com/vue@3", "https://example.com/react.js", "https://unpkg.com/htm@3?module"] {
            #expect(OfflineRewrite.lib(for: u, libs: libs) == nil, "\(u)")
        }
    }

    @Test func rewritesScriptsAndFontsInTheCopy() {
        let page = """
        <head><link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
        <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;700&amp;family=Roboto+Mono:ital,wght@0,400;1,500&display=swap" rel="stylesheet">
        <script src="https://unpkg.com/react@18/umd/react.production.min.js" integrity="sha384-x" crossorigin="anonymous"></script>
        <script src="https://cdn.example.com/x.js"></script>
        <style>@import url('https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@300..700'); body{background:url(https://img.example.com/bg.png?t=1)}</style>
        </head><body><a href="https://claude.ai">link</a><img src="https://img.example.com/a.png"></body>
        """
        let (out, r) = OfflineRewrite.html(page, libs: libs)!
        #expect(out.contains(#"<script src="collie-lib://lib/react@18.3.1/react.production.min.js"></script>"#), "\(out)")
        #expect(out.contains(#"href="collie-lib://fonts/css?family=Inter:400,700&family=Roboto%20Mono:400,500""#), "\(out)")
        #expect(out.contains(#"@import url("collie-lib://fonts/css?family=Space%20Grotesk")"#), "\(out)")
        #expect(!out.contains("preconnect") && !out.contains("integrity") && !out.contains("fonts.googleapis"), "\(out)")
        #expect(r.fonts == [.init(family: "Inter", weights: [400, 700]), .init(family: "Roboto Mono", weights: [400, 500]),
                            .init(family: "Space Grotesk", weights: nil)])
        // what still needs the network: listed without queries (the <a> is a link, not a resource)
        #expect(r.remote == ["https://cdn.example.com/x.js", "https://img.example.com/bg.png", "https://img.example.com/a.png"], "\(r.remote)")
        #expect(r.warnings.isEmpty, "\(r.warnings)")
        #expect(OfflineRewrite.html("<p>nada</p>", libs: libs)! == ("<p>nada</p>", OfflineRewrite.Report()))
    }

    /// Tags that never close (and one tag of many unclosed attributes) cost linear time, not quadratic.
    @Test func unclosedTagsStayLinear() {
        for s in ["<a ", "<link ", "<script ", "<img src=\"", "url(//"].map({ String(repeating: $0, count: 8000) })
                 + ["<img" + String(repeating: " src=\"", count: 8000) + ">"] {
            let t0 = ContinuousClock.now
            _ = OfflineRewrite.html(s, libs: libs)
            #expect(ContinuousClock.now - t0 < .milliseconds(200), "\(s.prefix(12)): \(ContinuousClock.now - t0)")
        }
    }

    @Test func overBudgetKeepsTheCopyAsIs() {
        let rw = OfflineRewriter(libs: libs, budget: .zero)
        let d = Data(#"<script src="https://unpkg.com/react@18/umd/react.production.min.js"></script>"#.utf8)
        #expect(rw.rewrite(d, ext: "html") == d && rw.report.warnings.count == 1, "\(rw.report)")
    }

    @Test func fontWeightsAreHundreds() {
        let g = OfflineRewrite.googleFonts("https://fonts.googleapis.com/css2?family=Inter:wght@150;151;400;700;950")
        #expect(g?.fonts == [OfflineRewrite.FontAsk(family: "Inter", weights: [400, 700])])
    }

    @Test func cssImportsAndRemote() {
        let (out, r) = OfflineRewrite.css("@import \"https://fonts.googleapis.com/css?family=Open+Sans:400,700italic|Lato\";\nh1{background:url('https://x.example.com/i.svg')}")
        #expect(out.hasPrefix(#"@import url("collie-lib://fonts/css?family=Open%20Sans:400,700&family=Lato");"#), "\(out)")
        #expect(r.fonts.map(\.family) == ["Open Sans", "Lato"] && r.remote == ["https://x.example.com/i.svg"])
    }
}

@Suite struct ZipCheckTests {
    private func tmp() -> URL { URL(fileURLWithPath: "/tmp/collie-zip-\(UUID().uuidString.prefix(8))") }

    @Test func listsAPlainZip() throws {
        let z = TestZip.make([("index.html", Data("<p>x</p>".utf8), 0o100644), ("css/", Data(), 0o040755), ("css/a.css", Data("a{}".utf8), 0o100644)])
        #expect(try ZipCheck.entries(z).map(\.name) == ["index.html", "css/", "css/a.css"])
    }

    @Test func refusesTraversalLinksAndSize() {
        for bad in ["../x.html", "/etc/x.html", "a/../../x", "a\\..\\x", "C:/x"] {
            #expect(throws: ProtocolError.self, "\(bad)") { try ZipCheck.entries(TestZip.make([(bad, Data("x".utf8), 0o100644)])) }
        }
        #expect(throws: ProtocolError.self) { try ZipCheck.entries(TestZip.make([("l.html", Data("/etc/passwd".utf8), 0o120777)])) }
        #expect(throws: ProtocolError.self) { try ZipCheck.entries(TestZip.make([("big.bin", Data(), 0o100644)], claimedSize: 65 << 20)) }
        #expect(throws: ProtocolError.self) { try ZipCheck.entries(TestZip.make((0...2000).map { ("f\($0).css", Data(), 0o100644) })) }
        #expect(throws: ProtocolError.self) { try ZipCheck.entries(Data("not a zip".utf8)) }
    }

    @Test func extractsAndFindsThePage() async throws {
        let dir = tmp(), zip = tmp().appendingPathExtension("zip"); defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: zip) }
        // the archive's own modes (a closed folder, an unreadable file) are not kept: 0755 / 0644
        try TestZip.make([("site/", Data(), 0o040000), ("site/index.html", Data("<p>x</p>".utf8), 0o100000),
                          ("site/a.css", Data(String(repeating: "a{}", count: 500).utf8), 0o100644)], deflate: true).write(to: zip)
        let page = try await ZipCheck.extract(zip, into: dir)
        #expect(page.path == dir.appendingPathComponent("site/index.html").path)
        #expect(FileManager.default.contents(atPath: dir.appendingPathComponent("site/a.css").path) == Data(String(repeating: "a{}", count: 500).utf8))
        let modes = try ["site", "site/index.html"].map { try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent($0).path)[.posixPermissions] as? Int }
        #expect(modes == [0o755, 0o644])
    }

    /// A bomb: 16 MiB of zeros deflated, its sizes declared as 1 byte. Extraction stops at what was declared.
    @Test func bombStopsAtTheDeclaredSize() async throws {
        let dir = tmp(), zip = tmp().appendingPathExtension("zip"); defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: zip) }
        try TestZip.make([("index.html", Data(count: 16 << 20), 0o100644)], claimedSize: 1, deflate: true).write(to: zip)
        await #expect(throws: ProtocolError.self) { try await ZipCheck.extract(zip, into: dir) }
        let written = (FileManager.default.subpaths(atPath: dir.path) ?? []).reduce(0) { t, f in
            t + ((try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(f).path)[.size] as? Int) ?? 0)
        }
        #expect(written < 1 << 20, "\(written)")
    }

    @Test func refusesAFifoOrALinkedZip() async throws {
        let d = tmp(); defer { try? FileManager.default.removeItem(at: d) }
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let fifo = d.appendingPathComponent("f.zip"), real = d.appendingPathComponent("r.zip"), link = d.appendingPathComponent("l.zip")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        try TestZip.make([("index.html", Data("x".utf8), 0o100644)]).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        for z in [fifo, link] { await #expect(throws: ProtocolError.self) { try await ZipCheck.extract(z, into: d.appendingPathComponent("out-\(z.lastPathComponent)")) } }
    }

    @Test func pageOfAFolder() throws {
        let d = tmp(); defer { try? FileManager.default.removeItem(at: d) }
        try FileManager.default.createDirectory(at: d.appendingPathComponent("only"), withIntermediateDirectories: true)
        try Data().write(to: d.appendingPathComponent("only/deck.html"))
        #expect(try ZipCheck.page(in: d).lastPathComponent == "deck.html")
        try Data().write(to: d.appendingPathComponent("only/other.html"))
        #expect(throws: ProtocolError.self) { try ZipCheck.page(in: d) }   // two pages, no index.html
        try Data().write(to: d.appendingPathComponent("only/index.html"))
        #expect(try ZipCheck.page(in: d).lastPathComponent == "index.html")
    }
}

@Suite struct ClaudeSourceStoreTests {
    private func tmp() -> URL { URL(fileURLWithPath: "/tmp/collie-src-\(UUID().uuidString.prefix(8))") }
    private func unlock(_ u: URL) {
        for case let f as URL in FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil) ?? NSEnumerator() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        }
    }

    @Test func sameSourceIsTheNextVersion() async throws {
        let root = tmp(); defer { unlock(root); try? FileManager.default.removeItem(at: root) }
        let s = ArtifactStore(root: root)
        let a = try await s.addAgent(page: Data("<p>1</p>".utf8), title: "A", paddockId: nil, by: "W", inFolder: "Cliente", origin: link)
        let other = try await s.addAgent(page: Data("<p>o</p>".utf8), title: "O", paddockId: nil, by: "W", origin: codeLink)
        let b = try await s.addAgent(page: Data("<p>2</p>".utf8), title: "A2", paddockId: nil, by: "W", origin: link)
        #expect(b.id == a.id && b.version == 2 && b.title == "A2" && b.inFolder == "Cliente" && b.origin == link)
        #expect(try await s.list().count == 2 && other.id != a.id)
        let dir = root.appendingPathComponent("artifacts")
        #expect(FileManager.default.contents(atPath: dir.appendingPathComponent(b.source!).path) == Data("<p>2</p>".utf8))
        #expect(FileManager.default.contents(atPath: dir.appendingPathComponent(a.source!).path) == Data("<p>1</p>".utf8))   // v1 kept
        // its design import exports as that version, not over v1
        let (e, folder) = try await s.convertToExport(b.id, fileId: "f", node: "1", page: nil)
        #expect(e.version == 2 && folder.lastPathComponent == "v2")
        try Data("<p>e</p>".utf8).write(to: folder.appendingPathComponent("index.html"))
        #expect(try await s.commit(e))
        // an imported page later made a design screen: the link again is still its next version
        let c = try await s.addAgent(page: Data("<p>3</p>".utf8), title: "A3", paddockId: nil, by: "W", origin: link)
        #expect(c.id == a.id && c.version == 3 && c.kind == .agent && c.origin == link)
        #expect(try await ArtifactStore(root: root).get(a.id).origin == link)
    }

    /// A terminal versions only its own artifact from a link; the app (no byId) versions any.
    @Test func onlyTheOwnerOrTheAppVersions() async throws {
        let root = tmp(); defer { unlock(root); try? FileManager.default.removeItem(at: root) }
        let s = ArtifactStore(root: root), ta = UUID(), tb = UUID()
        let a = try await s.addAgent(page: Data("<p>a</p>".utf8), title: "A", paddockId: nil, by: "A", byId: ta, inFolder: "Cliente", origin: link)
        let b = try await s.addAgent(page: Data("<p>b</p>".utf8), title: "B", paddockId: nil, by: "B", byId: tb, origin: link)
        #expect(b.id != a.id && b.version == 1 && b.inFolder == nil)
        let kept = try await s.get(a.id)
        #expect(kept.title == "A" && kept.byId == ta)
        let again = try await s.addAgent(page: Data("<p>a2</p>".utf8), title: "A2", paddockId: nil, by: "A", byId: ta, origin: link)
        #expect(again.id == a.id && again.version == 2)
        let app = try await s.addAgent(page: Data("<p>c</p>".utf8), title: "C", paddockId: nil, by: "app", origin: codeLink)
        let byApp = try await s.addAgent(page: Data("<p>c2</p>".utf8), title: "C2", paddockId: nil, by: "app", origin: codeLink)
        #expect(byApp.id == app.id && byApp.version == 2)
    }

    @Test func rewriteRecordsNetworkAndWarnings() async throws {
        let root = tmp(), src = tmp(); defer { unlock(root); for u in [root, src] { try? FileManager.default.removeItem(at: u) } }
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data(#"<link rel="stylesheet" href="a.css"><script src="https://unpkg.com/react@17/umd/react.production.min.js"></script>"#.utf8)
            .write(to: src.appendingPathComponent("index.html"))
        try Data("h1{background:url(https://x.example.com/i.png)}".utf8).write(to: src.appendingPathComponent("a.css"))
        let rw = OfflineRewriter(libs: [WebLibEntry(name: "react", version: "18.3.1", files: ["react.production.min.js"], licence: "MIT", global: "React")])
        let s = ArtifactStore(root: root)
        let a = try await s.addAgent(root: src, page: src.appendingPathComponent("index.html"), title: "T", paddockId: nil, by: "W", rewriter: rw)
        #expect(a.needsNetwork == ["https://x.example.com/i.png"] && a.warnings.count == 1, "\(a)")
        let copy = try String(contentsOf: root.appendingPathComponent("artifacts/\(a.source!)"), encoding: .utf8)
        #expect(copy.contains("collie-lib://lib/react@18.3.1/") && !copy.contains("unpkg"))
        #expect(try String(contentsOf: src.appendingPathComponent("index.html"), encoding: .utf8).contains("unpkg"))   // the original untouched
    }
}

/// A stored (uncompressed) zip, written by hand: names, data and Unix modes as given (`claimedSize`: the sizes it states).
enum TestZip {
    static func make(_ entries: [(String, Data, UInt32)], claimedSize: UInt32? = nil, deflate: Bool = false) -> Data {
        var out = Data(), central = Data()
        func u16(_ v: Int, _ d: inout Data) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        func u32(_ v: UInt32, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        for (name, data, mode) in entries {
            let packed = deflate && !data.isEmpty ? Self.deflate(data) : data, method = deflate && !data.isEmpty ? 8 : 0
            let n = Data(name.utf8), crc = claimedSize == nil ? crc32(data) : 0, size = claimedSize ?? UInt32(data.count), at = UInt32(out.count)
            let csize = claimedSize.map { _ in UInt32(packed.count) } ?? (method == 8 ? UInt32(packed.count) : size)
            u32(0x04034b50, &out); u16(20, &out); u16(0, &out); u16(method, &out); u16(0, &out); u16(0, &out)
            u32(crc, &out); u32(csize, &out); u32(size, &out); u16(n.count, &out); u16(0, &out); out += n; out += packed
            u32(0x02014b50, &central); u16(0x031e, &central); u16(20, &central); u16(0, &central); u16(method, &central); u16(0, &central); u16(0, &central)
            u32(crc, &central); u32(csize, &central); u32(size, &central); u16(n.count, &central); u16(0, &central); u16(0, &central)
            u16(0, &central); u16(0, &central); u32(mode << 16, &central); u32(at, &central); central += n
        }
        let cdAt = UInt32(out.count)
        out += central
        u32(0x06054b50, &out); u16(0, &out); u16(0, &out); u16(entries.count, &out); u16(entries.count, &out)
        u32(UInt32(central.count), &out); u32(cdAt, &out); u16(0, &out)
        return out
    }
    /// Raw deflate (Compression's ZLIB is RFC 1951, no header), as zip's method 8.
    static func deflate(_ d: Data) -> Data {
        let cap = d.count + 4096
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap); defer { dst.deallocate() }
        let n = d.withUnsafeBytes { compression_encode_buffer(dst, cap, $0.bindMemory(to: UInt8.self).baseAddress!, d.count, nil, COMPRESSION_ZLIB) }
        return Data(bytes: dst, count: n)
    }
    static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in d { c ^= UInt32(b); for _ in 0..<8 { c = (c >> 1) ^ (0xEDB88320 & (0 &- (c & 1))) } }
        return ~c
    }
}

extension CommandRouter {
    func testGrantImport(_ link: String, _ t: UUID, _ folder: String?, nonce: String) { claudeImports[link] = (t, folder, nonce) }
}

@Suite(.serialized) struct ClaudeImportCommandTests {
    private func call(_ p: Paths, _ id: String, _ token: String, _ cmd: String, _ args: [String: String], cwd: String? = nil) async throws -> Response {
        try await send(p, Request(id: "m", terminalId: id, token: token, command: cmd, args: args.mapValues { .string($0) }, cwd: cwd), timeoutSeconds: 60)
    }
    private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String]) async throws -> Response {
        try await send(p, Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }), timeoutSeconds: 60)
    }

    @Test func terminalGetsTheRecipeAndImportsAsVersions() async throws {
        try await withDaemon { d, p in
            let (id, _) = try await spawn(d, p, "A")
            let tok = try await tokenOf(d, id)
            #expect(try await call(p, id, tok, "artifact.import-claude", ["urls": "https://evil.com/x"]).error?.code == .invalidArgs)
            #expect(try await call(p, id, tok, "artifact.import-claude", ["urls": link, "folder": "Cliente"]).error?.code == .unauthorized)
            #expect(try await call(p, id, tok, "artifact.import-claude", ["urls": link, "terminal": "B"]).error?.code == .unauthorized)
            let r = try await call(p, id, tok, "artifact.import-claude", ["urls": "\(link) \(codeLink)"])
            guard case .object(let o)? = r.result, case .string(let dir)? = o["dir"], case .string(let recipe)? = o["recipe"] else { Issue.record("\(r)"); return }
            #expect(dir.hasPrefix(p.root.appendingPathComponent("sandbox/\(UUID(uuidString: id)!.uuidString)/state/claude-import/").path), "\(dir)")
            #expect(FileManager.default.fileExists(atPath: dir) && recipe.contains("--source '\(codeLink)'") && !recipe.contains("--folder"))

            // the terminal follows it: a page under dir/1, added with --source; again: the next version
            let one = URL(fileURLWithPath: dir).appendingPathComponent("1")
            try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
            try Data(#"<script src="https://unpkg.com/react@18.3.1/umd/react.production.min.js"></script><img src="https://x.example.com/a.png">"#.utf8)
                .write(to: one.appendingPathComponent("index.html"))
            let args = ["path": one.appendingPathComponent("index.html").path, "root": one.path, "source": link]
            #expect(try await call(p, id, tok, "artifact.add", args.merging(["folder": "Cliente"]) { a, _ in a }).error?.code == .unauthorized)
            await d.router.testGrantImport(link, UUID(uuidString: id)!, "Cliente", nonce: "n1")   // the app chose it for this link
            let a = try await call(p, id, tok, "artifact.add", args.merging(["folder": "Cliente"]) { a, _ in a })
            guard case .object(let ao)? = a.result, case .string(let aid)? = ao["id"] else { Issue.record("\(a)"); return }
            // no offline libs in this daemon: the CDN script stays remote too
            #expect(ao["version"] == .number(1) && ao["needsNetwork"] == .array([.string("https://unpkg.com/react@18.3.1/umd/react.production.min.js"),
                                                                                .string("https://x.example.com/a.png")]), "\(ao)")
            #expect(await waitFor(20) { await !d.router.importingArtifacts.contains(UUID(uuidString: aid)!) })   // its import fails: no app
            let b = try await call(p, id, tok, "artifact.add", args)
            guard case .object(let bo)? = b.result else { Issue.record("\(b)"); return }
            #expect(bo["id"] == .string(aid) && bo["version"] == .number(2), "\(bo)")
            let row = try await call(p, id, tok, "artifact.get", ["id": aid])
            guard case .object(let ro)? = row.result else { Issue.record("\(row)"); return }
            #expect(ro["origin"] == .string(link) && ro["folder"] == .string("Cliente"), "\(ro)")
        }
    }

    /// Reports count only from the asked terminal with the import's nonce; a terminal files pages in its lot's folder or none.
    @Test func reportsNeedTheAskedTerminalAndNonce() async throws {
        try await withDaemon { d, p in
            let (id, _) = try await spawn(d, p, "A")
            let tok = try await tokenOf(d, id)
            #expect(try await call(p, id, tok, "artifact.import-failed", ["url": link, "reason": "x"]).error?.code == .unauthorized)
            #expect(try await call(p, id, tok, "artifact.import-list", ["path": "/tmp/x.json", "nonce": "zz"]).error?.code == .unauthorized)
            await d.router.testGrantImport(link, UUID(uuidString: id)!, nil, nonce: "n1")
            #expect(try await call(p, id, tok, "artifact.import-failed", ["url": link, "reason": "x", "nonce": "bad"]).error?.code == .unauthorized)
            #expect(try await call(p, id, tok, "artifact.import-failed", ["url": link, "reason": "x", "nonce": "n1"]).ok)
            // S9: any terminal add, with or without --source
            let page = p.root.appendingPathComponent("p.html")
            try Data("<p>x</p>".utf8).write(to: page)
            #expect(try await call(p, id, tok, "artifact.add", ["path": page.path, "folder": "Outra"]).error?.code == .unauthorized)
            #expect(try await call(p, id, tok, "artifact.add", ["path": page.path, "folder": ""]).ok)
            // --title: no control characters reach the recipe
            let r = try await call(p, id, tok, "artifact.import-claude", ["urls": link, "title": "Deck\nrm -rf"])
            guard case .object(let o)? = r.result, case .string(let recipe)? = o["recipe"] else { Issue.record("\(r)"); return }
            #expect(recipe.contains("--title 'Deckrm -rf'"), "\(recipe)")
        }
    }

    @Test func appAddsAZipSafely() async throws {
        try await withDaemon { d, p in
            let zip = p.root.appendingPathComponent("drop.zip"), bad = p.root.appendingPathComponent("bad.zip")
            try TestZip.make([("index.html", Data("<p>z</p>".utf8), 0o100644)]).write(to: zip)
            try TestZip.make([("../evil.html", Data("x".utf8), 0o100644)]).write(to: bad)
            let r = try await admin(d, p, "artifact.add", ["path": zip.path, "folder": "Cliente"])
            guard case .object(let o)? = r.result, case .string(let aid)? = o["id"] else { Issue.record("\(r)"); return }
            let row = try await admin(d, p, "artifact.get", ["id": aid])
            guard case .object(let ro)? = row.result, case .string(let path)? = ro["path"] else { Issue.record("\(row)"); return }
            #expect(ro["title"] == .string("drop") && ro["folder"] == .string("Cliente") && FileManager.default.contents(atPath: path) == Data("<p>z</p>".utf8))
            #expect(try await admin(d, p, "artifact.add", ["path": bad.path]).error?.code == .invalidArgs)
            let left = try FileManager.default.contentsOfDirectory(atPath: p.root.path).filter { $0.hasPrefix(".import-") }
            #expect(left.isEmpty, "\(left)")   // the unpacked copy removed
        }
    }
}
