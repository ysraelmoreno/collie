import AppKit
import ImageIO
import CollieProtocol
import WebKit

/// `browser.*` commands (specs in CollieProtocol `PluginRegistry.browser`). Text results use the `output` key, which
/// the CLI and MCP print as-is, and are cut to fit the daemon's 1 MiB reply cap (`truncated: true`).
extension BrowserPanel {
    nonisolated static let screenshotKeep = 50
    /// `browser.wait` stays below its 120 s command timeout so the reply (found or not) still gets back.
    static let waitMaxSeconds = 115

    public func handle(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        switch command {
        case "browser.navigate":
            let web = try live()
            let url = try Self.url(try Self.string(args, "url"))
            appLoad = url
            try await wait(for: web.load(URLRequest(url: url)), fragmentOf: Self.isFragmentOnly(from: web.url, to: url) ? url : nil)
            let title = (try? await web.evaluateJavaScript("document.title", in: nil, contentWorld: .page)) as? String
            return .object(["url": .string(web.url?.absoluteString ?? ""), "title": .string(title ?? web.title ?? "")])
        case "browser.snapshot":
            return await BrowserAutomation.boundedOffMain(try await page("snapshot", [BrowserAutomation.resultCap]), key: "output")
        case "browser.text":
            return await BrowserAutomation.boundedOffMain(try await page("text", [BrowserAutomation.resultCap]), key: "output")
        case "browser.click":
            return .object(try await page("click", [try Self.string(args, "ref")]))
        case "browser.fill":
            return .object(try await page("fill", [try Self.string(args, "ref"), try Self.string(args, "text")]))
        case "browser.type":
            return .object(try await page("type", [try Self.string(args, "text")]))
        case "browser.key":
            return .object(try await page("key", [try Self.string(args, "key")]))
        case "browser.scroll":
            let ref = try? Self.string(args, "ref"), dy = try Self.int(args, "dy")
            guard ref != nil || dy != nil else { throw ProtocolError(code: .invalidArgs, message: "give --ref or --dy") }
            return .object(try await page("scroll", [ref ?? NSNull(), dy ?? 0]))
        case "browser.wait":
            return try await waitFor(args)
        case "browser.eval":
            return try await eval(try Self.string(args, "js"))
        case "browser.screenshot":
            return try await screenshot()
        case "browser.console":
            let n = min(max(try Self.int(args, "lines") ?? 100, 1), Self.consoleCap)
            return await BrowserAutomation.boundedOffMain(["output": .string(consoleLines.suffix(n).joined(separator: "\n"))], key: "output")
        case "browser.resize":
            return try resize(args)
        case "browser.emulate":
            return try await emulate(args)
        default:
            throw ProtocolError(code: .invalidArgs, message: "unknown browser command: \(command)")
        }
    }

    private func page(_ fn: String, _ args: [Any]) async throws(ProtocolError) -> [String: JSONValue] {
        try await BrowserAutomation.call(try live(), fn, args)
    }

    static func waitSeconds(_ args: [String: JSONValue]) throws(ProtocolError) -> Int {
        min(max(try int(args, "timeout") ?? 10, 1), waitMaxSeconds)
    }

    private func waitFor(_ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        let text = try? Self.string(args, "text"), selector = try? Self.string(args, "selector")
        guard (text == nil) != (selector == nil) else {
            throw ProtocolError(code: .invalidArgs, message: "give exactly one of --text or --selector")
        }
        let secs = try Self.waitSeconds(args)
        let r = try await page("wait", [text ?? NSNull(), selector ?? NSNull(), secs * 1000])
        guard r["found"] == .bool(true) else {
            throw ProtocolError(code: .timeout, message: "\(text.map { "text '\($0)'" } ?? "selector '\(selector!)'") not found within \(secs) s")
        }
        return .object(r)
    }

    /// A JS exception is `invalidArgs` with its message; a value JSON can't hold comes back described.
    private func eval(_ js: String) async throws(ProtocolError) -> JSONValue {
        let web = try live()
        let value: JSONValue
        do {
            value = BrowserAutomation.json(try await web.evaluateJavaScript(js, in: nil, contentWorld: .page))
        } catch let e as NSError where e.domain == WKError.errorDomain && e.code == WKError.javaScriptResultTypeIsUnsupported.rawValue {
            value = .string("<result of a type JSON cannot hold>")
        } catch {
            throw ProtocolError(code: .invalidArgs, message: BrowserAutomation.jsMessage(error))
        }
        return await BrowserAutomation.offMain {
            let r: [String: JSONValue] = ["value": value]
            guard BrowserAutomation.encodedSize(.object(r)) > BrowserAutomation.resultCap else { return .object(r) }
            // too big: as JSON text, cut
            let text = (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return BrowserAutomation.bounded(["value": .string(text)], key: "value")
        }
    }

    /// PNG `<root>/screens/<panelId>-<uuid>.png` (dir 0700; removed with the panel); only the newest `screenshotKeep` are kept. Encoding, writing and pruning
    /// run off the main actor (a large page is a large PNG).
    private func screenshot() async throws(ProtocolError) -> JSONValue {
        let web = try live()
        container.offscreenFrame()
        let image: NSImage
        do { image = try await web.takeSnapshot(configuration: nil) } catch {
            throw ProtocolError(code: .unavailable, message: "screenshot failed: \(error.localizedDescription)")
        }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ProtocolError(code: .unavailable, message: "screenshot: the page has no size")
        }
        let dir = host.root.appendingPathComponent("screens", isDirectory: true)
        let prefix = panel.id.uuidString + "-"
        return try await BrowserAutomation.offMain { Self.savePNG(cg, in: dir, prefix: prefix) }.get()
    }

    nonisolated static func removeScreenshots(in dir: URL, prefix: String) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(prefix) && name.hasSuffix(".png") {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    nonisolated static func savePNG(_ cg: CGImage, in dir: URL, prefix: String) -> Result<JSONValue, ProtocolError> {
        let fm = FileManager.default
        let file = dir.appendingPathComponent("\(prefix)\(UUID().uuidString).png")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            guard let dest = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil) else {
                return .failure(ProtocolError(code: .internal, message: "screenshot: cannot create \(file.path)"))
            }
            CGImageDestinationAddImage(dest, cg, nil)
            guard CGImageDestinationFinalize(dest) else {
                return .failure(ProtocolError(code: .internal, message: "screenshot: PNG encoding failed"))
            }
        } catch {
            return .failure(ProtocolError(code: .internal, message: "screenshot: \(error.localizedDescription)"))
        }
        let old = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "png" }
            .sorted { mtime($0) > mtime($1) }
            .dropFirst(screenshotKeep)
        for u in old { try? fm.removeItem(at: u) }
        return .success(.object(["path": .string(file.path), "width": .number(Double(cg.width)), "height": .number(Double(cg.height))]))
    }

    nonisolated private static func mtime(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// The page's viewport, independent of the panel: the container shows it scaled down to fit its slot.
    /// `--reset` goes back to filling the slot.
    private func resize(_ args: [String: JSONValue]) throws(ProtocolError) -> JSONValue {
        let web = try live()
        if case .bool(true)? = args["reset"] {
            container.viewport = nil
        } else {
            let current = container.viewport ?? web.frame.size
            func dim(_ key: String, _ fallback: CGFloat) throws(ProtocolError) -> CGFloat {
                guard let v = try Self.int(args, key) else { return max(fallback.rounded(), 200) }
                guard (200...4096).contains(v) else { throw ProtocolError(code: .invalidArgs, message: "--\(key) must be 200-4096") }
                return CGFloat(v)
            }
            container.viewport = CGSize(width: try dim("width", current.width), height: try dim("height", current.height))
        }
        container.layoutSubtreeIfNeeded()
        let size = container.viewport ?? web.frame.size
        return .object(["width": .number(size.width), "height": .number(size.height), "scale": .number(Double(container.scale))])
    }

    /// `--color-scheme` is the web view's appearance (public API); `--reduced-motion` has no public override, so it is a
    /// user script (see `BrowserAutomation.motionScript`), also run on the current page (main frame; other frames
    /// pick it up on their next load). Both persist for the panel until changed.
    private func emulate(_ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        let web = try live()
        func choice(_ key: String, _ allowed: [String]) throws(ProtocolError) -> String? {
            guard let v = args[key], v != .null else { return nil }
            guard case .string(let s) = v, allowed.contains(s) else {
                throw ProtocolError(code: .invalidArgs, message: "--\(key) must be \(allowed.joined(separator: ", "))")
            }
            return s
        }
        let scheme = try choice("color-scheme", ["light", "dark", "system"])
        let motion = try choice("reduced-motion", ["reduce", "no-preference", "system"])
        if let scheme {
            colorScheme = scheme == "system" ? nil : scheme
            web.appearance = scheme == "light" ? NSAppearance(named: .aqua) : scheme == "dark" ? NSAppearance(named: .darkAqua) : nil
        }
        if let motion {
            reducedMotion = motion == "system" ? nil : motion
            installScripts()
            _ = try? await web.evaluateJavaScript(BrowserAutomation.motionScript(reducedMotion ?? "system"), in: nil, contentWorld: .page)
        }
        let uncovered = (try? await web.evaluateJavaScript("window.__collieMotion ? window.__collieMotion.uncovered() : 0", in: nil, contentWorld: .page)) as? Int
        return .object(["colorScheme": .string(colorScheme ?? "system"), "reducedMotion": .string(reducedMotion ?? "system"),
                        "uncoveredSheets": .number(Double(uncovered ?? 0))])
    }

    /// Same document, other fragment: WebKit navigates in place, without didFinish.
    static func isFragmentOnly(from current: URL?, to target: URL) -> Bool {
        guard let current, target.fragment != nil else { return false }
        func base(_ u: URL) -> String { u.absoluteString.split(separator: "#", maxSplits: 1).first.map(String.init) ?? "" }
        return base(current) == base(target)
    }

    // MARK: args

    static func string(_ args: [String: JSONValue], _ key: String) throws(ProtocolError) -> String {
        guard case .string(let s)? = args[key] else { throw ProtocolError(code: .invalidArgs, message: "missing \(key)") }
        return s
    }

    /// A number, or a string holding one (MCP clients send either).
    static func int(_ args: [String: JSONValue], _ key: String) throws(ProtocolError) -> Int? {
        switch args[key] {
        case nil, .null?: return nil
        case .number(let n)? where n.rounded() == n && abs(n) < 1e9: return Int(n)
        case .string(let s)? where Int(s) != nil: return Int(s)
        default: throw ProtocolError(code: .invalidArgs, message: "\(key) must be an integer")
        }
    }
}
