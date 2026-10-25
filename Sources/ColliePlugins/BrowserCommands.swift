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

    /// R8: an agent's command never leaves a visible panel holding the user's keyboard focus. Trusted Tab, a click into
    /// a field or a page `focus()` make the web view its window's first responder; the window's previous one (the
    /// user's terminal) gets it back. The page keeps its own focus (`activeElement`, `:focus-visible`).
    public func handle(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        guard !container.headless, let window = container.window else { return try await run(command, args) }
        let before = window.firstResponder
        defer {
            restoreFocus(window, before)
            // ponytail: WebKit can take first responder a turn late; one more check covers it
            DispatchQueue.main.async { [weak self, weak window, weak before] in
                MainActor.assumeIsolated { if let window { self?.restoreFocus(window, before) } }
            }
        }
        return try await run(command, args)
    }

    /// Gives `before` back its first responder status when it was outside this panel and the page has taken it.
    private func restoreFocus(_ window: NSWindow, _ before: NSResponder?) {
        func inPanel(_ r: NSResponder?) -> Bool { (r as? NSView)?.isDescendant(of: container) == true }
        guard window.firstResponder !== before, inPanel(window.firstResponder), !inPanel(before) else { return }
        window.makeFirstResponder(before)
    }

    /// WebKit edits text only while the web view is first responder: it holds it until the keys settle, then `handle`
    /// gives it back. Taken right before the keys (the page's own focus update then lands after them).
    /// ponytail: keys the user types during that window (≤ the settle timeout) reach the page.
    private func keyboard(_ web: WKWebView) { web.window?.makeFirstResponder(web) }

    private func run(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
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
            return try await pointer(try Self.string(args, "ref"), .click)
        case "browser.hover":
            return try await pointer(try Self.string(args, "ref"), .move)
        case "browser.fill":
            return .object(try await page("fill", [try Self.string(args, "ref"), try Self.string(args, "text")]))
        case "browser.type":
            let text = try Self.string(args, "text")
            try BrowserInput.checkLength(text)
            guard let web = try trustedInput() else { return Self.untrusted(try await page("type", [text])) }
            return try await settle("keyup", text.count, ms: 1000 + 20 * text.count) { () throws(ProtocolError) in keyboard(web); try BrowserInput.type(web, text) }
        case "browser.key":
            let key = try BrowserInput.parse(try Self.string(args, "key"))
            guard let web = try trustedInput() else { return Self.untrusted(try await page("key", [key.name])) }
            return try await settle("keyup", 1) { keyboard(web); BrowserInput.press(web, key) }
        case "browser.scroll":
            let ref = try? Self.string(args, "ref"), dy = try Self.int(args, "dy")
            guard ref != nil || dy != nil else { throw ProtocolError(code: .invalidArgs, message: "give --ref or --dy") }
            return .object(try await page("scroll", [ref ?? NSNull(), dy ?? 0]))
        case "browser.wait":
            return try await waitFor(args)
        case "browser.eval":
            return try await eval(try Self.string(args, "js"))
        case "browser.screenshot":
            return try await screenshot(args)
        case "browser.console":
            let n = min(max(try Self.int(args, "lines") ?? 100, 1), Self.consoleCap)
            return await BrowserAutomation.boundedOffMain(["output": .string(consoleLines.suffix(n).joined(separator: "\n"))], key: "output")
        case "browser.resize":
            return try resize(args)
        case "browser.emulate":
            return try await emulate(args)
        case "browser.reload":
            return try await reload(hard: args["hard"] == .bool(true))
        case "browser.storage":
            return try await storage(args)
        case "browser.init-script":
            return try await initScript(args)
        default:
            throw ProtocolError(code: .invalidArgs, message: "unknown browser command: \(command)")
        }
    }

    private func page(_ fn: String, _ args: [Any]) async throws(ProtocolError) -> [String: JSONValue] {
        try await BrowserAutomation.call(try live(), fn, args)
    }

    /// The web view when it is in a window (visible, or headless in a `BrowserInput.HostWindow`): AppKit events reach
    /// it as the user's own. Without one, the JS path dispatches synthetic events (`trusted: false`).
    private func trustedInput() throws(ProtocolError) -> WKWebView? {
        let web = try live()
        return web.window == nil ? nil : web
    }

    private static func untrusted(_ r: [String: JSONValue]) -> JSONValue { .object(r.merging(["trusted": .bool(false)]) { $1 }) }

    /// Sends trusted events and replies once the page has seen `count` trusted `event`s, so the next command sees their
    /// effect; after `ms` (a disabled control, a move to where the pointer already is, a busy page) `settled: false`.
    /// A reply signal only: our key events are dropped on re-send by their timestamp (`BrowserInput.sentinel`).
    private func settle(_ event: String, _ count: Int, ms: Int = 1000, _ send: () throws(ProtocolError) -> Void) async throws(ProtocolError) -> JSONValue {
        _ = try await page("arm", [event, count, ms])
        try send()
        let r = try await page("settled", [])
        return .object(["ok": .bool(true), "trusted": .bool(true), "settled": r["seen"] ?? .bool(false)])
    }

    /// Click or hover at the center of the ref's visible box (scrolled into view first).
    private func pointer(_ ref: String, _ kind: BrowserInput.MouseKind) async throws(ProtocolError) -> JSONValue {
        guard let web = try trustedInput() else { return Self.untrusted(try await page(kind == .click ? "click" : "hover", [ref])) }
        let r = try await page("rect", [ref])
        guard case .number(let x)? = r["x"], case .number(let y)? = r["y"], case .number(let w)? = r["width"], case .number(let h)? = r["height"] else {
            throw ProtocolError(code: .internal, message: "browser: bad rect reply")
        }
        return try await settle(kind == .click ? "mouseup" : "mousemove", 1) {
            BrowserInput.mouse(web, at: CGPoint(x: x + w / 2, y: y + h / 2), kind: kind)
        }
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

    /// 16384 output pixels: past this a PNG is unwieldy (and CGContext/WebKit start failing).
    static let screenshotMaxPixels = 16384
    static let screenshotMaxBytes = 512 << 20

    /// PNG `<root>/screens/<panelId>-<uuid>.png` (dir 0700; removed with the panel); only the newest `screenshotKeep` are kept. Encoding, writing and pruning
    /// run off the main actor (a large page is a large PNG). `--clip x,y,w,h` (viewport CSS px) or `--ref` crops; `--full-page` tiles the document.
    private func screenshot(_ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        let web = try live()
        let clip = try? Self.string(args, "clip"), ref = try? Self.string(args, "ref")
        let full = args["full-page"] == .bool(true)
        guard clip == nil || ref == nil else { throw ProtocolError(code: .invalidArgs, message: "give --clip or --ref, not both") }
        guard !full || (clip == nil && ref == nil) else { throw ProtocolError(code: .invalidArgs, message: "--full-page cannot combine with --clip or --ref") }
        container.offscreenFrame()
        let cg: CGImage
        if full { cg = try await Self.fullPage(web) }
        else if let clip { cg = try await Self.snapshot(web, rect: try Self.clipRect(clip, in: web.bounds.size)) }
        else if let ref {
            // a screenshot must not move the viewport: the scroll before is restored, also on error
            let before = try await Self.pageNumbers(web, "return [scrollX, scrollY]")
            let restore = "scrollTo({ left: \(before[0]), top: \(before[1]), behavior: 'instant' }); return [0]"
            let r: [String: JSONValue]
            do throws(ProtocolError) { r = try await page("rect", [ref]) } catch { _ = try? await Self.pageNumbers(web, restore); throw error }
            guard case .number(let x)? = r["x"], case .number(let y)? = r["y"], case .number(let w)? = r["width"], case .number(let h)? = r["height"] else {
                throw ProtocolError(code: .internal, message: "browser: bad rect reply")
            }
            do throws(ProtocolError) { cg = try await Self.snapshot(web, rect: CGRect(x: x, y: y, width: w, height: h)) }
            catch { _ = try? await Self.pageNumbers(web, restore); throw error }
            _ = try? await Self.pageNumbers(web, restore)
        } else { cg = try await Self.snapshot(web, rect: nil) }
        let dir = host.root.appendingPathComponent("screens", isDirectory: true)
        let prefix = panel.id.uuidString + "-"
        return try await BrowserAutomation.offMain { Self.savePNG(cg, in: dir, prefix: prefix) }.get()
    }

    static func snapshot(_ web: WKWebView, rect: CGRect?) async throws(ProtocolError) -> CGImage {
        let config = WKSnapshotConfiguration()
        if let rect { config.rect = rect }   // the web view's bounds are the page viewport (1:1 with CSS px)
        let image: NSImage
        do { image = try await web.takeSnapshot(configuration: config) } catch {
            throw ProtocolError(code: .unavailable, message: "screenshot failed: \(error.localizedDescription)")
        }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ProtocolError(code: .unavailable, message: "screenshot: the page has no size")
        }
        return cg
    }

    /// `x,y,w,h` in viewport CSS px, cut to the viewport.
    static func clipRect(_ s: String, in viewport: CGSize) throws(ProtocolError) -> CGRect {
        let n = s.split(separator: ",", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard n.count == 4, !n.contains(where: { $0 == nil || !$0!.isFinite }), n[2]! > 0, n[3]! > 0 else {
            throw ProtocolError(code: .invalidArgs, message: "--clip must be x,y,w,h (numbers, w and h > 0)")
        }
        let r = CGRect(x: n[0]!, y: n[1]!, width: n[2]!, height: n[3]!).intersection(CGRect(origin: .zero, size: viewport))
        guard !r.isNull, !r.isEmpty else { throw ProtocolError(code: .invalidArgs, message: "--clip is outside the viewport (\(Int(viewport.width))x\(Int(viewport.height)))") }
        return r
    }

    /// Tiles: scroll by the viewport height, snapshot each, stitch at backing scale; the frame is never resized (`vh` keeps its
    /// meaning) and the scroll position is restored. The last tile is the partial one: the page clamps its scroll, so it overlaps
    /// the previous tile and is drawn at its real offset.
    /// ponytail: the height is measured once at the start (content that grows while capturing, lazy/infinite, is cut; re-measure per tile if needed); viewport width only (no horizontal tiling); fixed/sticky elements repeat per tile; scrolling inside a nested container is not followed.
    static func fullPage(_ web: WKWebView) async throws(ProtocolError) -> CGImage {
        let vh = Int(web.bounds.height)
        let doc = try await Self.pageNumbers(web, "return [Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0), scrollX, scrollY]")
        let height = max(doc[0], vh)
        var ctx: CGContext?
        var scale = 0.0
        var result: ProtocolError?
        let tiles = (height + vh - 1) / vh
        tileLoop: for i in 0..<tiles {
            do throws(ProtocolError) {
                let y = try await Self.pageNumbers(web, """
                    scrollTo({ top: \(i * vh), left: 0, behavior: 'instant' });
                    await new Promise(r => { requestAnimationFrame(() => requestAnimationFrame(r)); setTimeout(r, 150); });
                    return [scrollY]
                    """)[0]
                let tile = try await Self.snapshot(web, rect: nil)
                if ctx == nil {
                    scale = Double(tile.width) / web.bounds.width
                    let h = Int((Double(height) * scale).rounded())
                    guard tile.width * h * 4 <= Self.screenshotMaxBytes else {
                        throw ProtocolError(code: .invalidArgs, message: "--full-page: \(tile.width)x\(h) px is too large (over 512 MiB); use --clip or --ref")
                    }
                    guard h <= Self.screenshotMaxPixels else {
                        throw ProtocolError(code: .invalidArgs, message: "--full-page: the page is \(h) px tall, over the \(Self.screenshotMaxPixels) px cap; use --clip or --ref")
                    }
                    ctx = CGContext(data: nil, width: tile.width, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: tile.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
                    guard ctx != nil else { throw ProtocolError(code: .internal, message: "screenshot: cannot allocate \(tile.width)x\(h)") }
                }
                let top = Int((Double(y) * scale).rounded())
                ctx!.draw(tile, in: CGRect(x: 0, y: ctx!.height - top - tile.height, width: tile.width, height: tile.height))
            } catch { result = error; break tileLoop }
        }
        _ = try? await Self.pageNumbers(web, "scrollTo({ top: \(doc[2]), left: \(doc[1]), behavior: 'instant' }); return [0]")
        if let result { throw result }
        guard let cg = ctx?.makeImage() else { throw ProtocolError(code: .unavailable, message: "screenshot: the page has no size") }
        return cg
    }

    /// Runs `body` (async function body returning an array of numbers) in the page world.
    static func pageNumbers(_ web: WKWebView, _ body: String) async throws(ProtocolError) -> [Int] {
        do {
            let r = try await web.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page) as? [Any]
            return (r ?? []).map { Int(($0 as? NSNumber)?.doubleValue.rounded() ?? 0) }
        } catch { throw ProtocolError(code: .unavailable, message: "screenshot failed: \(BrowserAutomation.jsMessage(error))") }
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
        let counts = (try? await web.evaluateJavaScript("window.__collieMotion ? [window.__collieMotion.uncovered(), window.__collieMotion.closedRoots()] : [0, 0]", in: nil, contentWorld: .page)) as? [Int]
        return .object(["colorScheme": .string(colorScheme ?? "system"), "reducedMotion": .string(reducedMotion ?? "system"),
                        "uncoveredSheets": .number(Double(counts?[0] ?? 0)),
                        "uncoveredShadowRoots": .number(Double(counts?[1] ?? 0))])
    }

    private func reload(hard: Bool) async throws(ProtocolError) -> JSONValue {
        let web = try live()
        appLoad = web.url   // an artifact page reloads like the load the app asked for
        try await wait(for: hard ? web.reloadFromOrigin() : web.reload())
        let title = (try? await web.evaluateJavaScript("document.title", in: nil, contentWorld: .page)) as? String
        return .object(["url": .string(web.url?.absoluteString ?? ""), "title": .string(title ?? web.title ?? "")])
    }

    // MARK: storage

    /// `get`/`set` act on the localStorage of the page's origin; `clear` on the origin's local/session storage and on the
    /// cookies of this panel's own data store (never another panel's, never the user's other browsers). Values travel as
    /// call arguments (JSON-encoded by WebKit), never spliced into the script. Runs in the automation world: the page
    /// can't tamper with the Storage prototype, and the storage itself is the page's.
    private func storage(_ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        let web = try live()
        let action = try Self.string(args, "action")
        func storageJS(_ body: String, _ a: [String: Any] = [:]) async throws(ProtocolError) -> Any? {
            let origin = try? await web.evaluateJavaScript("location.origin", in: nil, contentWorld: BrowserAutomation.world) as? String
            guard let origin, origin != "null", !origin.isEmpty else {
                throw ProtocolError(code: .invalidArgs, message: "storage needs a page with an origin (not about:blank); navigate first")
            }
            do { return try await web.callAsyncJavaScript(body, arguments: a, in: nil, contentWorld: BrowserAutomation.world) }
            catch { throw ProtocolError(code: .invalidArgs, message: BrowserAutomation.jsMessage(error)) }
        }
        switch action {
        case "get":
            let v = try await storageJS("return localStorage.getItem(key)", ["key": try Self.string(args, "key")])
            return .object(["value": BrowserAutomation.json(v)])
        case "set":
            _ = try await storageJS("localStorage.setItem(key, value)", ["key": try Self.string(args, "key"), "value": try Self.string(args, "value")])
            return .object(["ok": .bool(true)])
        case "clear":
            let any = ["local", "session", "cookies"].contains { args[$0] == .bool(true) }
            func want(_ k: String) -> Bool { !any || args[k] == .bool(true) }
            var cleared: [String] = [], cookies = 0
            if want("local") { _ = try await storageJS("localStorage.clear()"); cleared.append("local") }
            if want("session") { _ = try await storageJS("sessionStorage.clear()"); cleared.append("session") }
            if want("cookies") { cookies = try await clearCookies(web); cleared.append("cookies") }
            return .object(["cleared": .array(cleared.map { .string($0) }), "cookies": .number(Double(cookies))])
        default:
            throw ProtocolError(code: .invalidArgs, message: "storage action must be clear, set or get")
        }
    }

    /// An isolated panel owns its whole store: every cookie goes. A workspace or global store is shared with other
    /// panels: only the current site's cookies (the cookie domain covers the page host).
    private func clearCookies(_ web: WKWebView) async throws(ProtocolError) -> Int {
        let store = web.configuration.websiteDataStore.httpCookieStore
        var cookies = await store.allCookies()
        if Self.scope(panel) != .isolated {
            guard let host = web.url?.host?.lowercased() else {
                throw ProtocolError(code: .invalidArgs, message: "--cookies on a shared store clears the current site's cookies: navigate first")
            }
            cookies = cookies.filter { c in
                let d = c.domain.lowercased().drop { $0 == "." }
                return host == d || host.hasSuffix("." + d)
            }
        }
        for c in cookies { await store.deleteCookie(c) }
        return cookies.count
    }

    static let initScriptMaxBytes = 64 << 10, initScriptMax = 32

    /// `add --js` (→ `{id}`), `list`, `clear [--id]`: user scripts run at document start in every later main-frame load of
    /// this panel (page world, before the page's own scripts); not run on the current page, not persisted.
    private func initScript(_ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        _ = try live()
        switch try Self.string(args, "action") {
        case "add":
            let js = try Self.string(args, "js")
            guard js.utf8.count <= Self.initScriptMaxBytes else { throw ProtocolError(code: .invalidArgs, message: "--js is over \(Self.initScriptMaxBytes) bytes") }
            guard initScripts.count < Self.initScriptMax else { throw ProtocolError(code: .invalidArgs, message: "at most \(Self.initScriptMax) init scripts; clear some") }
            nextInitScript += 1
            let id = "s\(nextInitScript)"
            initScripts.append((id, js))
            installScripts()
            return .object(["id": .string(id)])
        case "list":
            return .object(["scripts": .array(initScripts.map { .object(["id": .string($0.id), "js": .string(String($0.js.prefix(200)))]) })])
        case "clear":
            if let id = try? Self.string(args, "id") {
                guard initScripts.contains(where: { $0.id == id }) else { throw ProtocolError(code: .invalidArgs, message: "--id: no init script \(id)") }
                initScripts.removeAll { $0.id == id }
            } else { initScripts = [] }
            installScripts()
            return .object(["ok": .bool(true), "remaining": .number(Double(initScripts.count))])
        default:
            throw ProtocolError(code: .invalidArgs, message: "init-script action must be add, list or clear")
        }
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
