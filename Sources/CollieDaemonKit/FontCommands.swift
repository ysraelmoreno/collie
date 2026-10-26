import Foundation
import CollieCore
import CollieProtocol

/// One GET for `font.add` with that User-Agent: at most `cap` bytes (more: an error). The daemon's is `GoogleFonts.fetch`;
/// tests inject a fake.
public typealias FontFetch = @Sendable (_ url: URL, _ cap: Int, _ userAgent: String) async throws -> Data

/// Google Fonts, downloaded once by the daemon (never by a page): the css2 API on fonts.googleapis.com, then each woff2 on
/// fonts.gstatic.com; https only, never redirected off those hosts. Pages then load them from `collie-lib://fonts`.
/// The same css2 URL asked with `ttfUserAgent` names full TTFs (FigCraft reads no woff2): kept in `<family>/ttf/`.
public enum GoogleFonts {
    static let hosts: Set<String> = ["fonts.googleapis.com", "fonts.gstatic.com"]
    public static let fileCap = 2 << 20, familyCap = 20 << 20
    /// All of `<root>/fonts`: bytes and families; and `font.add`s per terminal-wide hour (the app has no limit).
    public static let totalCap = 200 << 20, maxFamilies = 40, addsPerHour = 20
    /// The css2 answer names woff2 files only for a current browser.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    /// Not a browser: css2 then names one full TrueType file per face (no unicode-range subsets).
    static let ttfUserAgent = "Collie/1 (TrueType for FigCraft)"

    /// https on one of Google Fonts' hosts, default port, no credentials.
    public static func allowed(_ u: URL) -> Bool {
        u.scheme?.lowercased() == "https" && hosts.contains(u.host?.lowercased() ?? "") && u.port == nil && u.user == nil && u.password == nil
    }

    static func cssURL(family: String, weights: [Int], italic: Bool) -> URL {
        let axes = italic ? "ital,wght@" + ([0, 1].flatMap { i in weights.map { "\(i),\($0)" } }).joined(separator: ";")
            : "wght@" + weights.map(String.init).joined(separator: ";")
        return URL(string: "https://fonts.googleapis.com/css2?family=\(family.replacingOccurrences(of: " ", with: "+")):\(axes)&display=swap")!
    }

    /// The `@font-face` blocks of a css2 answer: style, weight, `ext` file URL (on fonts.gstatic.com) and unicode-range.
    static func faces(_ css: String, ext: String = "woff2") throws(ProtocolError) -> [(style: String, weight: String, url: URL, range: String?)] {
        try css.matches(of: /@font-face\s*\{([^}]*)\}/).map { m throws(ProtocolError) in
            let b = String(m.1)
            guard let src = b.firstMatch(of: /src:\s*url\(\s*['"]?([^'")\s]+)['"]?\s*\)/).flatMap({ URL(string: String($0.1)) }),
                  allowed(src), src.host?.lowercased() == "fonts.gstatic.com", src.pathExtension.lowercased() == ext else {
                throw ProtocolError(code: .unavailable, message: "o Google Fonts respondeu uma fonte fora de fonts.gstatic.com ou que não é \(ext)")
            }
            let weight = b.firstMatch(of: /font-weight:\s*(\d{1,4}(?: \d{1,4})?)\s*;/).map { String($0.1) } ?? "400"
            let style = b.contains(/font-style:\s*italic/) ? "italic" : "normal"
            return (style, weight, src, b.firstMatch(of: /unicode-range:\s*([^;]+);/).map { String($0.1).trimmingCharacters(in: .whitespaces) })
        }
    }

    /// The daemon's fetch: an ephemeral session (no cookies, no cache), the redirect refused unless `allowed`, the body
    /// read up to `cap`.
    public static let fetch: FontFetch = { url, cap, userAgent in
        guard allowed(url) else { throw ProtocolError(code: .invalidArgs, message: "endereço fora do Google Fonts: \(url.absoluteString)") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let dl = Download(cap: cap)
        let session = URLSession(configuration: .ephemeral, delegate: dl, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, resp) = try await withCheckedThrowingContinuation { c in dl.start(c, session.dataTask(with: req)) }
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200, let final = http.url, allowed(final) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw ProtocolError(code: code == 400 || code == 404 ? .notFound : .unavailable, message: "o Google Fonts respondeu \(code)")
        }
        return data
    }

    /// One GET read in the chunks URLSession hands over, cancelled past `cap`; a redirect only to `allowed`.
    private final class Download: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let cap: Int, lock = NSLock()
        private var data = Data(), over = false, done: CheckedContinuation<(Data, URLResponse?), any Error>?
        init(cap: Int) { self.cap = cap }
        func start(_ c: CheckedContinuation<(Data, URLResponse?), any Error>, _ task: URLSessionDataTask) {
            lock.withLock { done = c }; task.resume()
        }
        func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest: URLRequest) async -> URLRequest? {
            newRequest.url.map(GoogleFonts.allowed) == true ? newRequest : nil
        }
        func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            let stop = lock.withLock { data.append(chunk); over = over || data.count > cap || dataTask.response?.expectedContentLength ?? 0 > Int64(cap); return over }
            if stop { dataTask.cancel() }
        }
        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: (any Error)?) {
            let (c, d, o) = lock.withLock { () -> (CheckedContinuation<(Data, URLResponse?), any Error>?, Data, Bool) in defer { done = nil }; return (done, data, over) }
            if o { c?.resume(throwing: ProtocolError(code: .tooMany, message: "acima do limite")) }
            else if let e { c?.resume(throwing: e) } else { c?.resume(returning: (d, task.response)) }
        }
    }
}

extension CommandRouter {
    /// `font.*`: add and list for the app and every terminal; remove is the app's. `font.add` only while Preferências →
    /// "Baixar fontes do Google Fonts" is on (`admin.fonts`).
    func fontCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        let caller = try await principal(r, peer: peer)   // nil = admin
        let dir = config.paths.root.appendingPathComponent("fonts")
        func invalid(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        func family() throws(ProtocolError) -> String {
            let f = try need(r, "family")
            guard Fonts.validFamily(f) else { throw invalid("nome de fonte inválido: use letras, números e espaços (até 64)") }
            return f
        }
        switch r.command {
        case "font.list":
            let fonts = try await UnixSocketClient.offPool { () -> [FontFamily] in
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
                return names.compactMap { Fonts.downloaded($0, in: dir) }
            }
            func row(_ f: FontFamily, _ source: String) -> JSONValue {
                .object(["family": .string(f.family), "source": .string(source), "css": .string(Fonts.cssURL([f.family])),
                         "weights": .array(Array(Set(f.faces.map(\.weight))).sorted().map { .string($0) }),
                         "italic": .bool(f.faces.contains { $0.style == "italic" }), "licence": f.licence.map { .string($0) } ?? .null])
            }
            let mine = Set(fonts.map(\.family))
            return .array(fonts.map { row($0, "google") } + Fonts.bundled.filter { !mine.contains($0.family) }.map { row($0, "bundled") })
        case "font.remove":
            guard caller == nil else { throw ProtocolError(code: .unauthorized, message: "'font.remove' é só do app") }
            let f = try family()
            guard try await UnixSocketClient.offPool({ Fonts.downloaded(f, in: dir) != nil }) else {
                throw ProtocolError(code: .notFound, message: Fonts.bundled.contains { $0.family == f } ? "\(f) vem com o Collie e não sai" : "fonte \(f) não baixada")
            }
            try await UnixSocketClient.offPool { try FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
            await fontsChanged()
            return .object(["family": .string(f)])
        case "font.add":
            var f = try family()
            var weights = [400, 700]
            if let w = str(r, "weights") {
                let parts = w.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let ns = parts.compactMap { Int($0) }.filter { (100...900).contains($0) }
                guard !parts.isEmpty, ns.count == parts.count, ns.count <= 9 else { throw invalid("--weights: números de 100 a 900, separados por vírgula (ex.: 400,700)") }
                weights = Array(Set(ns)).sorted()
            }
            guard googleFonts else {
                throw ProtocolError(code: .unavailable, message: "Baixar fontes do Google Fonts está desligado nas Preferências do Collie; peça ao usuário para ligar")
            }
            // one at a time (a call's downloads held in memory): the next waits. ponytail: 100 ms polling, as herd.apply
            while addingFont { try await Task.sleep(for: .milliseconds(100)) }
            addingFont = true; defer { addingFont = false }
            if caller != nil {   // terminals: 20 adds an hour, all together; the app: no limit
                let hour = ContinuousClock.now - .seconds(3600)
                fontAdds.removeAll { $0 < hour }
                guard fontAdds.count < GoogleFonts.addsPerHour else {
                    throw ProtocolError(code: .tooMany, message: "limite de \(GoogleFonts.addsPerHour) fontes por hora para os terminais; tente mais tarde ou baixe pelas Preferências")
                }
                fontAdds.append(.now)
            }
            // the folder already there under any case keeps its spelling; its faces are kept (merged), never dropped
            let asked = f
            let (stored, hasTTF, used) = try await UnixSocketClient.offPool { () -> (FontFamily?, Bool, (bytes: Int, families: [String: Int])) in
                let fm = FileManager.default
                var fams: [String: Int] = [:], bytes = 0
                for n in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !n.hasPrefix(".") {
                    let sub = dir.appendingPathComponent(n)
                    let size = ((try? fm.subpathsOfDirectory(atPath: sub.path)) ?? []).reduce(0) { t, p in
                        t + (((try? fm.attributesOfItem(atPath: sub.appendingPathComponent(p).path))?[.size] as? Int) ?? 0)
                    }
                    bytes += size; fams[n] = size
                }
                let match = fams.keys.first { $0.caseInsensitiveCompare(asked) == .orderedSame }
                let ttf = match.map { fm.fileExists(atPath: dir.appendingPathComponent($0).appendingPathComponent("ttf").path) } ?? false
                return (match.flatMap { Fonts.downloaded($0, in: dir) }, ttf, (bytes, fams))
            }
            var italic = flag(r, "italic")
            if let stored {
                let have = Set(stored.faces.flatMap { $0.weight.split(separator: " ").compactMap { Int($0) } })
                let hasItalic = stored.faces.contains { $0.style == "italic" }
                if Set(weights).isSubset(of: have), !italic || hasItalic, hasTTF {   // nothing new (TTFs too): no download
                    return .object(["family": .string(stored.family), "faces": .number(Double(stored.faces.count)), "css": .string(Fonts.cssURL([stored.family])), "already": .bool(true)])
                }
                f = stored.family
                weights = Array(have.union(weights).filter { (100...900).contains($0) }).sorted()
                italic = italic || hasItalic
                guard weights.count <= 9 else { throw invalid("\(f) já tem pesos demais; remova a família nas Preferências e baixe de novo") }
            } else if used.families.count >= GoogleFonts.maxFamilies {
                throw ProtocolError(code: .tooMany, message: "já há \(GoogleFonts.maxFamilies) famílias baixadas; remova algumas em Preferências → Fontes")
            }
            let budget = GoogleFonts.totalCap - used.bytes + (stored.map { used.families[$0.family] ?? 0 } ?? 0)
            guard budget > 0 else {
                throw ProtocolError(code: .tooMany, message: "as fontes baixadas já ocupam \(GoogleFonts.totalCap >> 20) MiB; remova algumas em Preferências → Fontes")
            }
            let (added, warning) = try await downloadFont(f, weights: weights, italic: italic, into: dir, budget: budget)
            await fontsChanged()
            var out: [String: JSONValue] = ["family": .string(f), "faces": .number(Double(added.faces.count)), "css": .string(Fonts.cssURL([f]))]
            if let warning { out["warning"] = .string(warning) }
            return .object(out)
        default:
            throw ProtocolError(code: .internal, message: "'\(r.command)' not implemented yet")
        }
    }

    /// Design panels' editors add the downloaded TTFs again (`DesignPanel`).
    private func fontsChanged() async {
        for p in ws.panels where p.pluginId == "design" { await pluginEmitted(panel: p.id, name: "fonts.changed", payload: .object([:])) }
    }

    /// The css2 answer, then each distinct woff2 once (≤ 2 MiB each, ≤ 20 MiB in all), then the same for the TTFs (in
    /// `ttf/`, the same caps counting the woff2), into a fresh folder that then replaces `<dir>/<family>` (0700, files
    /// 0600); any failure leaves nothing behind, except a TTF one: the family without `ttf/` and a warning.
    /// `budget`: what `<root>/fonts` may still take (the 200 MiB in all, the family it replaces freed).
    private func downloadFont(_ family: String, weights: [Int], italic: Bool, into dir: URL, budget: Int) async throws -> (FontFamily, String?) {
        let fetch = config.fontFetch
        let css = GoogleFonts.cssURL(family: family, weights: weights, italic: italic)
        func get(_ u: URL, _ cap: Int, _ what: String, _ ua: String = GoogleFonts.userAgent) async throws -> Data {
            let d: Data
            do { d = try await fetch(u, cap, ua) } catch let e as ProtocolError where e.code == .tooMany {
                throw ProtocolError(code: .tooMany, message: "\(what) passa de \(cap >> 20) MiB")
            } catch let e as ProtocolError where e.code == .notFound {
                throw ProtocolError(code: .notFound, message: "o Google Fonts não tem \(family) com esses pesos")
            } catch let e as ProtocolError { throw e } catch {
                throw ProtocolError(code: .unavailable, message: "não consegui baixar do Google Fonts: \(error.localizedDescription)")
            }
            guard d.count <= cap else { throw ProtocolError(code: .tooMany, message: "\(what) passa de \(cap >> 20) MiB") }
            return d
        }
        let faces = try GoogleFonts.faces(String(decoding: try await get(css, GoogleFonts.fileCap, "a resposta do Google Fonts"), as: UTF8.self))
        guard !faces.isEmpty else { throw ProtocolError(code: .notFound, message: "o Google Fonts não tem \(family) com esses pesos") }
        var files: [URL: String] = [:], blobs: [(String, Data)] = [], total = 0
        var meta = FontFamily(family: family, faces: [], source: css.absoluteString,
                              licence: "SIL OFL 1.1 ou Apache 2.0, conforme a família: https://fonts.google.com/specimen/\(family.replacingOccurrences(of: " ", with: "+"))/license")
        for face in faces {
            if files[face.url] == nil {
                let name = "\(face.style)-\(face.weight.replacingOccurrences(of: " ", with: "-"))-\(files.count).woff2"
                let d = try await get(face.url, GoogleFonts.fileCap, "um arquivo da fonte")
                total += d.count
                guard total <= GoogleFonts.familyCap else { throw ProtocolError(code: .tooMany, message: "a família passa de 20 MiB; peça menos pesos") }
                guard total <= budget else {
                    throw ProtocolError(code: .tooMany, message: "as fontes baixadas passariam de \(GoogleFonts.totalCap >> 20) MiB; remova algumas em Preferências → Fontes")
                }
                files[face.url] = name; blobs.append((name, d))
            }
            meta.faces.append(.init(style: face.style, weight: face.weight, file: files[face.url]!, unicodeRange: face.range))
        }
        var ttfs: [(String, Data)] = [], warning: String?
        do {
            var seen: Set<URL> = [], sum = total
            let answer = try await get(css, GoogleFonts.fileCap, "a resposta do Google Fonts", GoogleFonts.ttfUserAgent)
            for face in try GoogleFonts.faces(String(decoding: answer, as: UTF8.self), ext: "ttf") where seen.insert(face.url).inserted {
                let d = try await get(face.url, GoogleFonts.fileCap, "um TTF da fonte", GoogleFonts.ttfUserAgent)
                sum += d.count
                guard sum <= GoogleFonts.familyCap, sum <= budget else { throw ProtocolError(code: .tooMany, message: "os TTF passam do limite") }
                ttfs.append(("ttf/\(face.style)-\(face.weight.replacingOccurrences(of: " ", with: "-"))-\(ttfs.count).ttf", d))
            }
            if ttfs.isEmpty { throw ProtocolError(code: .notFound, message: "sem TTF") }
        } catch {
            ttfs = []
            warning = "o FigCraft não vai usar \(family) (as páginas sim): \((error as? ProtocolError)?.message ?? error.localizedDescription)"
        }
        let licence = "\(family)\nFonte: \(css.absoluteString)\nLicença: \(meta.licence ?? "")\nBaixada em: \(ISO8601DateFormatter().string(from: Date()))\n"
        let out = meta, written = blobs + ttfs + [(Fonts.metaFile, try JSONEncoder().encode(meta)), ("LICENSE.txt", Data(licence.utf8))]
        try await UnixSocketClient.offPool {
            let fm = FileManager.default
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let tmp = dir.appendingPathComponent(".new-\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: tmp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                if written.contains(where: { $0.0.hasPrefix("ttf/") }) {
                    try fm.createDirectory(at: tmp.appendingPathComponent("ttf"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                }
                for (name, d) in written {
                    let u = tmp.appendingPathComponent(name)
                    guard fm.createFile(atPath: u.path, contents: d, attributes: [.posixPermissions: 0o600]) else {
                        throw ProtocolError(code: .internal, message: "não consegui gravar \(u.path)")
                    }
                }
                let final = dir.appendingPathComponent(family)
                try? fm.removeItem(at: final)
                try fm.moveItem(at: tmp, to: final)
            } catch { try? fm.removeItem(at: tmp); throw error }
        }
        return (out, warning)
    }

    /// `admin.fonts`: nil reads; on|off saves "Baixar fontes do Google Fonts" (Collie-wide).
    func setGoogleFonts(_ v: String?) throws -> JSONValue {
        if let v {
            guard let on = ["on": true, "off": false][v] else { throw ProtocolError(code: .invalidArgs, message: "download must be on or off") }
            var s = CollieSettings.load(config.paths.root); s.googleFonts = on
            try s.save(config.paths.root)
            googleFonts = on
        }
        return .object(["download": .bool(googleFonts)])
    }
}
