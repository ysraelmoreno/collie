import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// A fake Google Fonts: answers from `files` by URL (never the network) and records what was asked.
final class FakeFontFetch: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [URL] = []
    private var inFlight = 0, peak = 0
    var files: [String: Data] = [:]
    var delay: Duration = .zero
    var urls: [URL] { lock.withLock { asked } }
    var maxInFlight: Int { lock.withLock { peak } }
    var fetch: FontFetch {
        { [self] url, _ in
            lock.withLock { asked.append(url); inFlight += 1; peak = max(peak, inFlight) }
            defer { lock.withLock { inFlight -= 1 } }
            if delay > .zero { try await Task.sleep(for: delay) }
            guard let d = lock.withLock({ files[url.absoluteString] }) else { throw ProtocolError(code: .notFound, message: "404 \(url)") }
            return d
        }
    }
    static let css = """
        /* latin-ext */
        @font-face {
          font-family: 'Inter';
          font-style: normal;
          font-weight: 400;
          font-display: swap;
          src: url(https://fonts.gstatic.com/s/inter/v18/ext.woff2) format('woff2');
          unicode-range: U+0100-02BA, U+02BD-02C5;
        }
        /* latin */
        @font-face {
          font-family: 'Inter';
          font-style: normal;
          font-weight: 400;
          font-display: swap;
          src: url(https://fonts.gstatic.com/s/inter/v18/latin.woff2) format('woff2');
          unicode-range: U+0000-00FF, U+0131;
        }
        @font-face {
          font-family: 'Inter';
          font-style: normal;
          font-weight: 700;
          font-display: swap;
          src: url(https://fonts.gstatic.com/s/inter/v18/latin.woff2) format('woff2');
          unicode-range: U+0000-00FF, U+0131;
        }
        """
    static let cssURL = "https://fonts.googleapis.com/css2?family=Inter:wght@400;700&display=swap"
    static func inter() -> FakeFontFetch {
        let f = FakeFontFetch()
        f.files = [cssURL: Data(css.utf8), "https://fonts.gstatic.com/s/inter/v18/ext.woff2": Data("ext".utf8),
                   "https://fonts.gstatic.com/s/inter/v18/latin.woff2": Data("latin".utf8)]
        return f
    }
}

@Suite struct FontCommandTests {
    private struct Term { var id: String; var token: String }
    private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
        try await send(p, Request(id: "x", token: d.adminToken, command: cmd, args: args), timeoutSeconds: 30)
    }
    private func term(_ d: Daemon, _ p: Paths) async throws -> Term {
        let r = try await send(p, Request(id: "x", token: d.adminToken, command: "admin.spawn",
                                          args: ["name": "W", "preset": "shell", "cwd": "/tmp"]), timeoutSeconds: 60)
        guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
        return Term(id: id, token: try await tokenOf(d, id))
    }
    private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
        try await send(p, Request(id: "t", terminalId: t.id, token: t.token, command: cmd, args: args), timeoutSeconds: 30)
    }
    private func families(_ r: Response) -> [String: [String: JSONValue]] {
        guard case .array(let a)? = r.result else { return [:] }
        return Dictionary(a.compactMap { if case .object(let o) = $0, case .string(let f)? = o["family"] { (f, o) } else { nil } }) { a, _ in a }
    }
    private func perms(_ u: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions]) as? Int) ?? -1 }

    @Test func addDownloadsOnceAndLists() async throws {
        let fake = FakeFontFetch.inter()
        try await withDaemon(configure: { $0.fontFetch = fake.fetch }) { d, p in
            let t = try await term(d, p)
            let r = try await call(p, t, "font.add", ["family": "Inter", "weights": "700,400"])
            #expect(r.ok, "\(r)")
            #expect(fake.urls.map(\.absoluteString) == [FakeFontFetch.cssURL, "https://fonts.gstatic.com/s/inter/v18/ext.woff2",
                                                        "https://fonts.gstatic.com/s/inter/v18/latin.woff2"])   // the shared file once
            let dir = p.root.appendingPathComponent("fonts/Inter")
            let meta = try #require(Fonts.downloaded("Inter", in: dir.deletingLastPathComponent()))
            #expect(meta.faces.count == 3 && meta.source == FakeFontFetch.cssURL && meta.licence?.isEmpty == false)
            #expect(Set(meta.faces.map(\.file)).count == 2 && meta.faces.allSatisfy { Fonts.validFile($0.file) })
            for f in meta.faces { #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(f.file).path)) }
            #expect(meta.faces.first { $0.weight == "700" }?.unicodeRange == "U+0000-00FF, U+0131")
            #expect(perms(p.root.appendingPathComponent("fonts")) == 0o700 && perms(dir) == 0o700)
            for f in try FileManager.default.contentsOfDirectory(atPath: dir.path) { #expect(perms(dir.appendingPathComponent(f)) == 0o600, "\(f)") }
            let lic = try String(contentsOf: dir.appendingPathComponent("LICENSE.txt"), encoding: .utf8)
            #expect(lic.contains(FakeFontFetch.cssURL) && lic.contains("fonts.google.com/specimen/Inter"))
            let list = families(try await call(p, t, "font.list"))
            #expect(list["Inter"]?["source"] == "google" && list["DM Mono"]?["source"] == "bundled")
            #expect(list["Inter"]?["css"] == .string(Fonts.cssURL(["Inter"])))
        }
    }

    @Test func italicAsksBothAxes() async throws {
        let fake = FakeFontFetch()
        try await withDaemon(configure: { $0.fontFetch = fake.fetch }) { d, p in
            _ = try await admin(d, p, "font.add", ["family": "Noto Sans", "italic": true])
            #expect(fake.urls.first?.absoluteString == "https://fonts.googleapis.com/css2?family=Noto+Sans:ital,wght@0,400;0,700;1,400;1,700&display=swap")
        }
    }

    @Test func refusesBadNamesWithoutFetching() async throws {
        let fake = FakeFontFetch.inter()
        try await withDaemon(configure: { $0.fontFetch = fake.fetch }) { d, p in
            for bad in ["../Inter", "Inter;x", "", String(repeating: "a", count: 65), "Açaí"] {
                let e = try await admin(d, p, "font.add", ["family": .string(bad)]).error
                #expect(e?.code == .invalidArgs, "\(bad)")
            }
            for w in ["abc", "50", "1000", "400;700"] {
                let e = try await admin(d, p, "font.add", ["family": "Inter", "weights": .string(w)]).error
                #expect(e?.code == .invalidArgs, "\(w)")
            }
            #expect(fake.urls.isEmpty)
        }
    }

    @Test func capsAndHostsRefused() async throws {
        let big = FakeFontFetch.inter()
        big.files["https://fonts.gstatic.com/s/inter/v18/latin.woff2"] = Data(count: GoogleFonts.fileCap + 1)
        try await withDaemon(configure: { $0.fontFetch = big.fetch }) { d, p in
            let e = try await admin(d, p, "font.add", ["family": "Inter", "weights": "400,700"]).error
            #expect(e?.message.contains("2 MiB") == true, "\(String(describing: e))")
            #expect(!FileManager.default.fileExists(atPath: p.root.appendingPathComponent("fonts/Inter").path))
        }
        // over the family's 20 MiB: eleven files of 2 MB
        let many = FakeFontFetch()
        let blocks = (0..<11).map { "@font-face { font-style: normal; font-weight: 400; src: url(https://fonts.gstatic.com/s/x/\($0).woff2) format('woff2'); }" }
        many.files["https://fonts.googleapis.com/css2?family=Inter:wght@400&display=swap"] = Data(blocks.joined(separator: "\n").utf8)
        for i in 0..<11 { many.files["https://fonts.gstatic.com/s/x/\(i).woff2"] = Data(count: 2_000_000) }
        try await withDaemon(configure: { $0.fontFetch = many.fetch }) { d, p in
            let e = try await admin(d, p, "font.add", ["family": "Inter", "weights": "400"]).error
            #expect(e?.message.contains("20 MiB") == true, "\(String(describing: e))")
            let left = (try? FileManager.default.contentsOfDirectory(atPath: p.root.appendingPathComponent("fonts").path)) ?? []
            #expect(left.isEmpty, "\(left)")   // the partial download is gone
        }
        // a face off fonts.gstatic.com (or not https) is never fetched
        for src in ["http://fonts.gstatic.com/s/a.woff2", "https://evil.example/a.woff2", "https://fonts.gstatic.com.evil.example/a.woff2"] {
            let off = FakeFontFetch()
            off.files["https://fonts.googleapis.com/css2?family=Inter:wght@400&display=swap"] = Data("@font-face { font-style: normal; font-weight: 400; src: url(\(src)) format('woff2'); }".utf8)
            try await withDaemon(configure: { $0.fontFetch = off.fetch }) { d, p in
                let e = try await admin(d, p, "font.add", ["family": "Inter", "weights": "400"]).error
                #expect(e != nil && off.urls.count == 1, "\(src)")
            }
        }
        #expect(GoogleFonts.allowed(URL(string: "https://fonts.googleapis.com/css2?family=A")!) && GoogleFonts.allowed(URL(string: "https://fonts.gstatic.com/s/a.woff2")!))
        for u in ["http://fonts.gstatic.com/a", "https://example.com/a", "https://fonts.gstatic.com:8443/a", "https://u@fonts.gstatic.com/a"] {
            #expect(!GoogleFonts.allowed(URL(string: u)!), "\(u)")
        }
    }

    @Test func removeIsTheApps() async throws {
        let fake = FakeFontFetch.inter()
        try await withDaemon(configure: { $0.fontFetch = fake.fetch }) { d, p in
            let t = try await term(d, p)
            #expect(try await admin(d, p, "font.add", ["family": "Inter", "weights": "400,700"]).ok)
            #expect(try await call(p, t, "font.remove", ["family": "Inter"]).error?.code == .unauthorized)
            #expect(try await admin(d, p, "font.remove", ["family": "DM Mono"]).error != nil)   // bundled
            #expect(try await admin(d, p, "font.remove", ["family": "Inter"]).ok)
            #expect(!FileManager.default.fileExists(atPath: p.root.appendingPathComponent("fonts/Inter").path))
            #expect(families(try await admin(d, p, "font.list"))["Inter"] == nil)
        }
    }

    @Test func toggleOffRefusesAdd() async throws {
        let fake = FakeFontFetch.inter()
        try await withDaemon(configure: { $0.fontFetch = fake.fetch }) { d, p in
            let t = try await term(d, p)
            #expect(try await admin(d, p, "admin.fonts").result == .object(["download": .bool(true)]))   // on by default
            #expect(try await call(p, t, "admin.fonts", ["download": "off"]).error?.code == .unauthorized)
            #expect(try await admin(d, p, "admin.fonts", ["download": "off"]).result == .object(["download": .bool(false)]))
            let e = try await call(p, t, "font.add", ["family": "Inter"]).error
            #expect(e?.code == .unavailable && e?.message.contains("Preferências") == true, "\(String(describing: e))")
            #expect(fake.urls.isEmpty)
            #expect(CollieSettings.load(p.root).googleFonts == false)
        }
    }

    // MARK: review fixes (M1, L1, L2)

    /// A re-add merges weights and italics (never drops a face), under the stored spelling of the family.
    @Test func reAddMergesUnderStoredSpelling() async throws {
        let fake = FakeFontFetch.inter()
        let merged = "https://fonts.googleapis.com/css2?family=Inter:ital,wght@0,400;0,700;1,400;1,700&display=swap"
        fake.files[merged] = Data(FakeFontFetch.css.utf8)
        try await withDaemon(configure: { $0.fontFetch = fake.fetch }) { d, p in
            #expect(try await admin(d, p, "font.add", ["family": "Inter", "weights": "400,700"]).ok)
            let n = fake.urls.count
            let same = try await admin(d, p, "font.add", ["family": "inter", "weights": "700"])   // already there: nothing fetched
            #expect(same.ok && fake.urls.count == n, "\(same)")
            let r = try await admin(d, p, "font.add", ["family": "inter", "weights": "400", "italic": true])
            #expect(r.ok && fake.urls[n].absoluteString == merged, "\(r) \(fake.urls)")
            #expect(try FileManager.default.contentsOfDirectory(atPath: p.root.appendingPathComponent("fonts").path) == ["Inter"])
            #expect(families(try await admin(d, p, "font.list"))["Inter"] != nil)
        }
    }

    /// At most 40 families and 200 MiB under <root>/fonts: refused before any fetch.
    @Test func totalCapsRefuse() async throws {
        let fake = FakeFontFetch.inter()
        try await withDaemon(configure: { $0.fontFetch = fake.fetch }) { d, p in
            let dir = p.root.appendingPathComponent("fonts")
            let big = dir.appendingPathComponent("Big")
            try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
            try JSONEncoder().encode(FontFamily(family: "Big", faces: [])).write(to: big.appendingPathComponent(Fonts.metaFile))
            FileManager.default.createFile(atPath: big.appendingPathComponent("a.woff2").path, contents: nil)
            let h = try FileHandle(forWritingTo: big.appendingPathComponent("a.woff2")); try h.truncate(atOffset: UInt64(GoogleFonts.totalCap)); try h.close()
            let e = try await admin(d, p, "font.add", ["family": "Inter"]).error
            #expect(e?.code == .tooMany && e?.message.contains("200 MiB") == true, "\(String(describing: e))")
            try FileManager.default.removeItem(at: big)
            for i in 0..<GoogleFonts.maxFamilies {
                let f = dir.appendingPathComponent("F\(i)")
                try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
                try JSONEncoder().encode(FontFamily(family: "F\(i)", faces: [])).write(to: f.appendingPathComponent(Fonts.metaFile))
            }
            let e2 = try await admin(d, p, "font.add", ["family": "Inter"]).error
            #expect(e2?.code == .tooMany && e2?.message.contains("40 famílias") == true, "\(String(describing: e2))")
            #expect(fake.urls.isEmpty)
        }
    }

    /// Terminals: 20 adds per hour; the app has no limit.
    @Test func terminalAddsAreRateLimited() async throws {
        let fake = FakeFontFetch.inter()
        try await withDaemon(configure: { $0.fontFetch = fake.fetch }) { d, p in
            let t = try await term(d, p)
            for _ in 0..<GoogleFonts.addsPerHour { #expect(try await call(p, t, "font.add", ["family": "Inter"]).ok) }
            let e = try await call(p, t, "font.add", ["family": "Inter"]).error
            #expect(e?.code == .tooMany && e?.message.contains("por hora") == true, "\(String(describing: e))")
            #expect(try await admin(d, p, "font.add", ["family": "Inter"]).ok)
        }
    }

    /// One add at a time: concurrent calls never fetch in parallel.
    @Test func addsAreSerialized() async throws {
        let fake = FakeFontFetch()
        fake.delay = .milliseconds(50)
        for f in ["A", "B", "C"] {
            fake.files["https://fonts.googleapis.com/css2?family=\(f):wght@400&display=swap"] =
                Data("@font-face { font-style: normal; font-weight: 400; src: url(https://fonts.gstatic.com/s/\(f).woff2) format('woff2'); }".utf8)
            fake.files["https://fonts.gstatic.com/s/\(f).woff2"] = Data(f.utf8)
        }
        try await withDaemon(configure: { $0.fontFetch = fake.fetch }) { d, p in
            let rs = try await withThrowingTaskGroup(of: Response.self) { g in
                for f in ["A", "B", "C"] { g.addTask { try await admin(d, p, "font.add", ["family": .string(f), "weights": "400"]) } }
                return try await g.reduce(into: []) { $0.append($1) }
            }
            #expect(rs.allSatisfy(\.ok) && fake.maxInFlight == 1, "\(rs)")
        }
    }
}
