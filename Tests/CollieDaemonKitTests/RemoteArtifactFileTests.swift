import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// Remote API slice 9 (spec §3.9): artifact.file serves an artifact's files and the offline libs/fonts, chunked and
/// confined, to a phone's WKWebView scheme handler.
private func obj(_ v: JSONValue?) -> [String: JSONValue] { if case .object(let o)? = v { o } else { [:] } }
private func str(_ v: JSONValue?) -> String { if case .string(let s)? = v { s } else { "" } }
private func num(_ v: JSONValue?) -> Int { if case .number(let n)? = v { Int(n) } else { -1 } }

/// The whole file, chunk by chunk (each next ask carries the first reply's etag); the first reply's fields.
private func fetch(_ ph: RemotePhone, _ url: String) async throws -> (data: Data, first: [String: JSONValue], chunks: Int) {
    var data = Data(), first: [String: JSONValue] = [:], chunks = 0
    while true {
        var args: [String: JSONValue] = ["url": .string(url), "offset": .number(Double(data.count))]
        if chunks > 0 { args["etag"] = first["etag"] }
        let r = try await ph.call("artifact.file", args)
        guard r.ok else { throw r.error ?? ProtocolError(code: .internal, message: "\(r)") }
        let o = obj(r.result)
        if chunks == 0 { first = o }
        #expect(num(o["offset"]) == data.count)
        data += Data(base64Encoded: str(o["d"])) ?? Data()
        chunks += 1
        if o["done"] == .bool(true) { return (data, first, chunks) }
    }
}

/// Writes into an artifact's folder (the store leaves it read-only), replacing what is there.
private func put(_ d: Data, _ f: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.deletingLastPathComponent().path)
    try? FileManager.default.removeItem(at: f)
    try d.write(to: f)
}

private func random(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }

@Suite(.serialized) struct RemoteArtifactFileTests {
    /// An agent artifact from a folder (page, a stylesheet, a 1.2 MB image in a subfolder): its id, page and folder on disk.
    private func artifact(_ d: Daemon, image: Data) async throws -> (id: String, page: String, dir: URL) {
        let src = URL(fileURLWithPath: "/private/tmp/collie-af-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("img"), withIntermediateDirectories: true)
        try Data("<html><head><title>Loja</title><link rel=stylesheet href=s.css></head><body><img src=img/a.png></body></html>".utf8)
            .write(to: src.appendingPathComponent("index.html"))
        try Data("body{color:red}".utf8).write(to: src.appendingPathComponent("s.css"))
        try image.write(to: src.appendingPathComponent("img/a.png"))
        defer { try? FileManager.default.removeItem(at: src) }
        let a = try await d.router.artifacts.addAgent(root: src, page: src.appendingPathComponent("index.html"), title: "Loja", paddockId: nil, by: "W")
        return (a.id.uuidString.lowercased(), "", await d.router.artifacts.dir.appendingPathComponent(a.folder))
    }

    @Test func servesThePageAndItsFilesInChunks() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true }) { d, p in
            let (ph, _) = try await helloPhone(d, p)
            defer { ph.close() }
            let image = random(1_200_000)
            let (id, _, _) = try await artifact(d, image: image)
            let got = obj(try await ph.call("artifact.get", ["id": .string(id)]).result)
            let page = str(got["page"])
            #expect(page.hasSuffix("index.html") && !page.hasPrefix("/"), "\(got)")   // relative to the artifact: collie-artifact://<id>/<page>
            let html = try await fetch(ph, "collie-artifact://\(id)/\(page)")
            #expect(String(decoding: html.data, as: UTF8.self).contains("<img src=img/a.png>") && html.first["mime"] == "text/html; charset=utf-8")
            // relative links resolve against the page's folder
            let base = (page as NSString).deletingLastPathComponent
            let css = try await fetch(ph, "collie-artifact://\(id)/\(base.isEmpty ? "" : base + "/")s.css")
            #expect(css.data == Data("body{color:red}".utf8) && css.first["mime"] == "text/css")
            let img = try await fetch(ph, "collie-artifact://\(id)/\(base.isEmpty ? "" : base + "/")img/a.png")
            #expect(img.data == image && img.chunks == 3 && num(img.first["size"]) == image.count && img.first["mime"] == "image/png")
            #expect(!str(img.first["etag"]).isEmpty)
            #expect(try await ph.call("artifact.file", ["url": .string("collie-artifact://\(id)/\(page)"), "offset": .number(Double(1 << 30))]).error?.code == .invalidArgs)
        }
    }

    @Test func pathsStayInsideTheArtifact() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true }) { d, p in
            let (ph, _) = try await helloPhone(d, p)
            defer { ph.close() }
            let (id, _, dir) = try await artifact(d, image: Data("png".utf8))
            let (other, _, otherDir) = try await artifact(d, image: Data("secret".utf8))
            // a link inside the artifact that leads out of it
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("out").path, withDestinationPath: "/etc")
            try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("sib.png").path,
                                                       withDestinationPath: otherDir.appendingPathComponent("source/img/a.png").path)
            func code(_ url: String) async throws -> ErrorCode? { try await ph.call("artifact.file", ["url": .string(url)]).error?.code }
            for bad in ["collie-artifact://\(id)/../\(otherDir.lastPathComponent)/source/img/a.png",
                        "collie-artifact://\(id)/%2e%2e/%2e%2e/artifacts.json", "collie-artifact://\(id)/out/hosts",
                        "collie-artifact://\(id)/sib.png", "collie-artifact://\(id)/.hidden", "collie-artifact://\(id)//etc/hosts",
                        "collie-artifact://app/\(dir.lastPathComponent)/source/index.html", "http://example.com/x", "collie-artifact://\(id)"] {
                let c = try await code(bad)
                #expect(c == .invalidArgs || c == .notFound, "\(bad): \(String(describing: c))")
            }
            #expect(try await code("collie-artifact://\(UUID().uuidString.lowercased())/source/index.html") == .notFound)
            #expect(try await code("collie-artifact://\(id)/source/nope.css") == .notFound)
            #expect(try await code("collie-artifact://\(id)/source") == .notFound, "a folder is not a file")
            #expect(try await ph.call("artifact.file", ["url": .string("collie-artifact://\(other)/source/img/a.png")]).ok, "its own files: fine")
        }
    }

    @Test func aFileChangedBetweenChunksConflictsAndBigOnesAreRefused() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true }) { d, p in
            let (ph, _) = try await helloPhone(d, p)
            defer { ph.close() }
            let (id, _, dir) = try await artifact(d, image: random(700_000))
            let url = "collie-artifact://\(id)/source/img/a.png"
            let first = obj(try await ph.call("artifact.file", ["url": .string(url)]).result)
            #expect(first["done"] == .bool(false))
            try put(random(700_001), dir.appendingPathComponent("source/img/a.png"))
            let next = try await ph.call("artifact.file", ["url": .string(url), "offset": 524_288, "etag": first["etag"] ?? .null])
            #expect(next.error?.code == .conflict, "\(next)")
            try put(random((8 << 20) + 1), dir.appendingPathComponent("source/big.bin"))
            #expect(try await ph.call("artifact.file", ["url": .string("collie-artifact://\(id)/source/big.bin")]).error?.code == .invalidArgs)
        }
    }

    @Test func offlineLibsAndFonts() async throws {
        let libs = URL(fileURLWithPath: "/private/tmp/collie-wl-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: libs.appendingPathComponent("htm@3.1.1"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: libs) }
        try Data("export default 1".utf8).write(to: libs.appendingPathComponent("htm@3.1.1/htm.mjs"))
        try Data("not listed".utf8).write(to: libs.appendingPathComponent("htm@3.1.1/extra.js"))
        try JSONEncoder().encode([WebLibEntry(name: "htm", version: "3.1.1", files: ["htm.mjs"], licence: "Apache-2.0", global: "htm")])
            .write(to: libs.appendingPathComponent("manifest.json"))
        try await withDaemon(configure: { $0.remoteAllowLoopback = true; $0.weblibsDir = libs }) { d, p in
            let (ph, _) = try await helloPhone(d, p)
            defer { ph.close() }
            let fonts = p.root.appendingPathComponent("fonts/Inter")
            try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
            try Data("WOFF".utf8).write(to: fonts.appendingPathComponent("inter-400.woff2"))
            try JSONEncoder().encode(FontFamily(family: "Inter", faces: [.init(style: "normal", weight: "400", file: "inter-400.woff2")]))
                .write(to: fonts.appendingPathComponent(Fonts.metaFile))
            let js = try await fetch(ph, "collie-lib://lib/htm@3.1.1/htm.mjs")
            #expect(js.data == Data("export default 1".utf8) && js.first["mime"] == "text/javascript; charset=utf-8")
            let css = try await fetch(ph, "collie-lib://fonts/css?family=Inter:400")
            #expect(String(decoding: css.data, as: UTF8.self).contains("collie-lib://fonts/Inter/inter-400.woff2") && css.first["mime"] == "text/css; charset=utf-8")
            let woff = try await fetch(ph, "collie-lib://fonts/Inter/inter-400.woff2")
            #expect(woff.data == Data("WOFF".utf8) && woff.first["mime"] == "font/woff2")
            for bad in ["collie-lib://lib/htm@3.1.1/extra.js", "collie-lib://lib/../manifest.json", "collie-lib://lib/htm@3.1.1/../manifest.json",
                        "collie-lib://fonts/Inter/font.json", "collie-lib://fonts/../fonts/Inter/inter-400.woff2", "collie-lib://other/x"] {
                let c = try await ph.call("artifact.file", ["url": .string(bad)]).error?.code
                #expect(c == .notFound || c == .invalidArgs, "\(bad): \(String(describing: c))")
            }
        }
    }

    @Test func bytesPerMinuteAreLimited() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true }) { d, p in
            let (ph, _) = try await helloPhone(d, p)
            defer { ph.close() }
            let (id, _, dir) = try await artifact(d, image: Data("x".utf8))
            try put(random(8 << 20), dir.appendingPathComponent("source/big.bin"))
            let url = "collie-artifact://\(id)/source/big.bin"
            var refused: ProtocolError?
            var served = 0
            for _ in 0..<4 where refused == nil {   // 32 MiB asked, 20 MiB a minute allowed
                do { served += try await fetch(ph, url).data.count } catch let e as ProtocolError { refused = e }
            }
            #expect(refused?.code == .tooMany && (refused?.retryAfter ?? 0) > 0, "\(String(describing: refused))")
            #expect(served >= 16 << 20 && served <= 20 << 20, "\(served)")
        }
    }
}
