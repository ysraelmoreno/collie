import Foundation
import CollieProtocol

/// The Android device helper's line protocol (Helpers/android-device/README.md; spec 2026-11-22-device-helper-design.md, H1):
/// one JSON request per line, one JSON answer per line with the request `id` echoed, and `{ev,t}` events after `subscribe`.
/// Pure: requests encoded, answers and events decoded, and the `enabled_accessibility_services` list edited.
public enum HelperProtocol {
    /// The helper this build expects (`HelperService.VERSION`); an older one is reinstalled.
    /// v2: a new instance takes over the socket from an old one still holding it (Helpers/android-device/README.md).
    /// v3: each instance closes only its own socket (the v2 race), and the dump reads the app's windows.
    public static let version = 3
    /// The abstract socket the helper listens on (`adb forward tcp:N localabstract:<socket>`).
    public static let socket = "collie-helper"
    public static let package = "com.collie.helper"
    /// The accessibility service, as `enabled_accessibility_services` lists it.
    public static let service = "com.collie.helper/.HelperService"

    public enum Request: Equatable, Sendable {
        case hello, dump, subscribe
        case tap(x: Double, y: Double)
        case swipe(x1: Double, y1: Double, x2: Double, y2: Double, ms: Int)
        /// `ACTION_CLICK` on the node at `path` (from `dump`), or its clickable ancestor.
        case click(path: [Int])
        /// `ACTION_SET_TEXT` on the focused field.
        case text(String)
        case scroll(path: [Int], forward: Bool)
        /// back, home, recents or notifications.
        case global(String)
    }

    /// One request line (JSON and a newline).
    public static func encode(_ r: Request, id: Int) -> Data {
        var o: [String: Any] = ["id": id]
        switch r {
        case .hello: o["op"] = "hello"
        case .dump: o["op"] = "dump"
        case .subscribe: o["op"] = "subscribe"
        case .tap(let x, let y): o["op"] = "tap"; o["x"] = x; o["y"] = y
        case .swipe(let x1, let y1, let x2, let y2, let ms):
            o["op"] = "swipe"; o["x1"] = x1; o["y1"] = y1; o["x2"] = x2; o["y2"] = y2; o["ms"] = ms
        case .click(let p): o["op"] = "click"; o["path"] = p
        case .text(let v): o["op"] = "text"; o["value"] = v
        case .scroll(let p, let fwd): o["op"] = "scroll"; o["path"] = p; o["dir"] = fwd ? "fwd" : "back"
        case .global(let a): o["op"] = "global"; o["action"] = a
        }
        // ponytail: only strings, numbers and int arrays go in, which JSONSerialization always encodes
        var d = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        d.append(0x0A)
        return d
    }

    /// The fields every answer has.
    public struct Reply: Decodable, Equatable, Sendable {
        public let id: Int?
        public let ok: Bool
        public let error: String?
    }
    /// A pushed event (after `subscribe`): `window` or `content`, `t` the device's epoch ms.
    public struct Event: Decodable, Equatable, Sendable {
        public let ev: String
        public let t: Int64
    }
    public enum Message: Equatable, Sendable { case reply(Reply), event(Event) }

    public struct Hello: Decodable, Equatable, Sendable {
        public let version: Int
        public let sdk: Int
        public let w: Int
        public let h: Int
    }

    /// A node of `dump`, in tree order; `path` is the child indices from the root (for `click`/`scroll`).
    public struct Node: Decodable, Equatable, Sendable {
        public let path: [Int]
        public let text, desc, id, cls: String
        /// left, top, right, bottom in screen pixels.
        public let bounds: [Int]
        public let clickable, selected, checked, enabled, focused, scrollable, password: Bool
        enum CodingKeys: String, CodingKey {
            case path = "p", text, desc, id, cls, bounds = "b", clickable = "clk", selected = "sel", checked = "chk"
            case enabled = "en", focused = "foc", scrollable = "scr", password = "pw"
        }
    }
    /// `root` false: no active window yet (right after an enable the first dump can also come back with no nodes).
    public struct Dump: Decodable, Equatable, Sendable {
        public let root: Bool
        public let nodes: [Node]
    }

    /// One line from the helper: an event (it has `ev`) or an answer.
    public static func message(_ line: Data) throws(ProtocolError) -> Message {
        if let e = try? JSONDecoder().decode(Event.self, from: line) { return .event(e) }
        guard let r = try? JSONDecoder().decode(Reply.self, from: line) else { throw bad(line) }
        return .reply(r)
    }

    /// The answer's body as `T`; an event or `ok: false` (the helper's `error`) throws.
    public static func decode<T: Decodable>(_ line: Data, as: T.Type) throws(ProtocolError) -> T {
        guard case .reply(let r) = try message(line) else {
            throw ProtocolError(code: .internal, message: "helper sent an event where an answer was due")
        }
        guard r.ok else { throw ProtocolError(code: .internal, message: "helper: \(r.error ?? "failed")") }
        guard let v = try? JSONDecoder().decode(T.self, from: line) else { throw bad(line) }
        return v
    }

    private static func bad(_ line: Data) -> ProtocolError {
        ProtocolError(code: .internal, message: "helper sent an unreadable line: \(String(decoding: line.prefix(200), as: UTF8.self))")
    }

    // MARK: enabled_accessibility_services

    /// The services in a `settings get secure enabled_accessibility_services` output (`null` or empty: none).
    public static func services(_ setting: String) -> [String] {
        let s = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        return s == "null" ? [] : s.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    /// The setting with the helper appended; every other service stays, in order (never overwritten).
    public static func enabling(_ setting: String) -> String {
        let all = services(setting)
        return (all.contains(where: isHelper) ? all : all + [service]).joined(separator: ":")
    }

    /// The setting without the helper; every other service stays.
    public static func removing(_ setting: String) -> String {
        services(setting).filter { !isHelper($0) }.joined(separator: ":")
    }

    /// The helper in its short or full component form.
    static func isHelper(_ s: String) -> Bool { s == service || s == "\(package)/\(package).HelperService" }
}
