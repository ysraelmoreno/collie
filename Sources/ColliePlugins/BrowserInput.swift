import AppKit
import CollieProtocol
import WebKit

/// Trusted input: AppKit events handed straight to the web view, which WebKit takes as the user's own (`isTrusted`,
/// Tab focus navigation, default actions). It needs the web view in a window (no window: the JS path in
/// `BrowserAutomation` is the fallback), and `:hover` / `:focus-visible` also need that window to be key (WebKit's
/// "window active" state); first responder doesn't matter. Spike results: plan 2K progress.md, "Task 4 spike".
@MainActor enum BrowserInput {
    enum MouseKind { case move, click }

    /// Hosts a page that is never shown (headless): reports itself key so WebKit treats the page as active (`:hover`,
    /// `:focus-visible`, mouse moves) while AppKit's real key window stays the user's (it can't become key or main).
    /// Never order it in, and never use it for a visible panel: that one keeps its real window's key state.
    final class HostWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        override var isKeyWindow: Bool { true }
        override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
            super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
            isExcludedFromWindowsMenu = true
            isReleasedWhenClosed = false
        }
    }

    /// `name`: the DOM `key` value (what the JS fallback takes).
    struct Key: Equatable { var name: String; var chars: String; var code: UInt16; var mods: NSEvent.ModifierFlags = [] }

    static let named: [(String, String, UInt16)] = [
        ("Enter", "\r", 36), ("Tab", "\t", 48), ("Escape", "\u{1b}", 53), ("Backspace", "\u{7f}", 51), ("Space", " ", 49),
        ("Delete", "\u{F728}", 117), ("ArrowUp", "\u{F700}", 126), ("ArrowDown", "\u{F701}", 125), ("ArrowLeft", "\u{F702}", 123),
        ("ArrowRight", "\u{F703}", 124), ("Home", "\u{F729}", 115), ("End", "\u{F72B}", 119), ("PageUp", "\u{F72C}", 116),
        ("PageDown", "\u{F72D}", 121),
    ]
    static let modifiers: [String: NSEvent.ModifierFlags] = [
        "shift": .shift, "ctrl": .control, "control": .control, "alt": .option, "option": .option,
        "meta": .command, "cmd": .command, "command": .command,
    ]

    /// `Tab`, `Shift+Tab`, `Meta+a`, `ArrowDown`, a single character… (names and modifiers in any case).
    static func parse(_ spec: String) throws(ProtocolError) -> Key {
        var parts = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if spec.hasSuffix("+") && parts.count > 1 { parts.removeLast(2); parts.append("+") }   // `Shift++`
        let name = parts.removeLast()
        var mods: NSEvent.ModifierFlags = []
        for m in parts {
            guard let f = modifiers[m.lowercased()] else { throw ProtocolError(code: .invalidArgs, message: "key: unknown modifier '\(m)' (Shift, Ctrl, Alt, Meta)") }
            mods.insert(f)
        }
        if let (key, chars, code) = named.first(where: { $0.0.lowercased() == name.lowercased() }) {
            var k = Key(name: key == "Space" ? " " : key, chars: chars, code: code, mods: mods)
            if code >= 123 && code <= 126 { k.mods.formUnion([.numericPad, .function]) }   // arrows, as AppKit sends them
            return k
        }
        guard name.count == 1 else {
            throw ProtocolError(code: .invalidArgs, message: "key: unknown key '\(name)' (Enter, Tab, Escape, Backspace, Delete, Space, arrows, Home, End, PageUp, PageDown or one character)")
        }
        if mods.contains(.command), ["c", "x", "v"].contains(name.lowercased()) {
            throw ProtocolError(code: .invalidArgs, message: "key: \(spec) is not supported (the clipboard is the user's)")
        }
        return Key(name: name, chars: name, code: 0, mods: mods)
    }

    /// Meta+a: its menu re-send is dropped (see `ours`), so select-all is done on the web view itself.
    static func isSelectAll(_ k: Key) -> Bool { k.mods.intersection([.command, .control, .option, .shift]) == .command && k.name.lowercased() == "a" }

    @discardableResult static func key(_ web: WKWebView, _ spec: String) throws(ProtocolError) -> Int { try press(web, try parse(spec)) }

    @discardableResult static func press(_ web: WKWebView, _ k: Key) throws(ProtocolError) -> Int {
        let s = try send(web, [k])
        if isSelectAll(k) { web.selectAll(nil) }
        return s
    }

    /// One key press per character (`\n` is Enter).
    /// ponytail: keyCode 0 for characters (the page's `event.code` is wrong for them; `key` is right); map a layout if it matters.
    static let typeMax = 1024
    static func checkLength(_ text: String) throws(ProtocolError) {
        guard text.count <= typeMax else { throw ProtocolError(code: .invalidArgs, message: "--text is over \(typeMax) characters; split it") }
    }
    @discardableResult static func type(_ web: WKWebView, _ text: String) throws(ProtocolError) -> Int {
        try checkLength(text)
        return try send(web, text.map { $0 == "\n" ? Key(name: "Enter", chars: "\r", code: 36) : Key(name: String($0), chars: String($0), code: 0) })
    }

    /// `at` in page CSS px (viewport coordinates). `.click` moves there first, as a pointer would.
    static func mouse(_ web: WKWebView, at p: CGPoint, kind: MouseKind) {
        let loc = windowPoint(web, p), n = web.window?.windowNumber ?? 0
        func event(_ t: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: n, context: nil, eventNumber: 0, clickCount: t == .mouseMoved ? 0 : 1,
                               pressure: t == .leftMouseDown ? 1 : 0)
        }
        // WebKit ignores mouseMoved sent to the view itself: moves come in through its tracking area's owner, as AppKit sends them
        if let move = event(.mouseMoved) {
            let owners = web.trackingAreas.filter { $0.options.contains(.mouseMoved) }.compactMap { $0.owner as AnyObject? }
            for o in owners where o.responds(to: #selector(NSResponder.mouseMoved(with:))) {
                _ = o.perform(#selector(NSResponder.mouseMoved(with:)), with: move)
            }
        }
        guard kind == .click, let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        web.mouseDown(with: down)
        web.mouseUp(with: up)
    }

    /// Page CSS px → window coordinates: the web view's bounds are the viewport in CSS px and `Container.page`'s
    /// bounds/frame carry the fit-to-slot scale, so AppKit's conversion does the scale and the flip.
    static func windowPoint(_ web: WKWebView, _ p: CGPoint) -> CGPoint { web.convert(p, to: nil) }

    /// Sends the keys; returns the serial of the last keyDown (for `resolve(through:in:)`). Refused while `keep` keyDowns
    /// are unresolved: an entry is never evicted (fail closed).
    @discardableResult static func send(_ web: WKWebView, _ keys: [Key]) throws(ProtocolError) -> Int {
        guard sent.count + keys.count <= keep else {
            throw ProtocolError(code: .unavailable, message: "too many pending keys (the page hasn't answered \(sent.count)); wait and retry")
        }
        installMonitor()
        let n = web.window?.windowNumber ?? 0
        for k in keys {
            for t in [NSEvent.EventType.keyDown, .keyUp] {
                guard let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: k.mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: n, context: nil, characters: k.chars, charactersIgnoringModifiers: k.chars,
                                               isARepeat: false, keyCode: k.code) else { continue }
                if t == .keyDown { serial += 1; sent.append((serial, ObjectIdentifier(web), e)); web.keyDown(with: e) } else { web.keyUp(with: e) }
            }
        }
        return serial
    }

    /// A keyDown the page doesn't handle goes back to `NSApp.sendEvent` (WebKit re-sends the same object, however
    /// late the page answers), which hands it to the app's key window (the user's terminal) or its menus: ours are
    /// dropped there. Only keyDowns are re-sent. An entry is resolved when its re-send is dropped, or by
    /// `resolve(through:in:)` once that page has seen a later trusted keyup: WebKit answers key events in order and
    /// re-sends synchronously on the answer, so every keyDown before it is done (handled, or re-sent and dropped).
    static var keep = 4096
    private static var sent: [(serial: Int, web: ObjectIdentifier, event: NSEvent)] = []
    private static var serial = 0
    private static var monitor: Any?
    private(set) static var dropped = 0
    static var pending: Int { sent.count }

    /// Only `web`'s own: another page's late answer says nothing about this one's.
    static func resolve(through s: Int, in web: WKWebView) {
        let id = ObjectIdentifier(web)
        sent.removeAll { $0.web == id && $0.serial <= s }
    }

    private static func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { e in
            let id = ObjectIdentifier(e)
            let drop = MainActor.assumeIsolated {
                guard let i = sent.firstIndex(where: { ObjectIdentifier($0.event) == id }) else { return false }
                sent.remove(at: i)
                dropped += 1
                return true
            }
            return drop ? nil : e
        }
    }
}
