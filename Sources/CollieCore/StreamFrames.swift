import Foundation
import CollieProtocol

// Lives in CollieCore (not CollieProtocol): events carry TerminalRecord/Connection, and CollieCore already depends on CollieProtocol.

public enum StatusBadge: String, Codable, Sendable { case idle, working, attention, stopped }

/// One JSON object per line on a `ui.*` stream; "t" is the type tag, `Data` is base64.
public enum StreamFrame: Codable, Sendable, Equatable {
    case out(Data)                       // daemon -> UI
    case replay(Data, truncated: Bool)   // first frame after attach: current in-memory scrollback
    case `in`(Data)                      // UI -> daemon (keyboard), written verbatim
    case resize(cols: UInt16, rows: UInt16)
    case event(WorkspaceEvent)           // daemon -> UI (events stream)
    case exited(code: Int32)
    case overflow                        // daemon cut the stream (send queue full); reattach
    // `ui.host`: the daemon forwards a plugin command to the app hosting the panel; the app answers by `id`
    case call(id: String, panel: UUID, command: String, args: [String: JSONValue], timeoutSeconds: Double)   // daemon -> host
    case reply(id: String, result: JSONValue?, error: ProtocolError?)                                       // host -> daemon
    case emit(panel: UUID, name: String, payload: JSONValue)                                                // host -> daemon
    case replaced                        // daemon -> host: another host took over; do not reconnect
    // `ui.device` (daemon -> app); the app's `in` frames there are scrcpy control messages (Android) or `SimInput` JSON (iOS)
    case videoMeta(width: UInt32, height: UInt32)
    case video(Data, pts: UInt64, config: Bool, key: Bool)   // one H.264 packet (Annex B)
    case jpeg(Data)                                          // one whole JPEG (iOS Simulator)
    case deviceStatus(state: String, message: String?)      // connecting | streaming | ended | error

    private enum K: String, CodingKey { case t, d, truncated, cols, rows, code, e, id, panel, command, args, timeout, result, error, name, payload,
                                 width, height, pts, config, key, state, message }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .t) {
        case "out": self = .out(try c.decode(Data.self, forKey: .d))
        case "replay": self = .replay(try c.decode(Data.self, forKey: .d), truncated: try c.decode(Bool.self, forKey: .truncated))
        case "in": self = .in(try c.decode(Data.self, forKey: .d))
        case "resize": self = .resize(cols: try c.decode(UInt16.self, forKey: .cols), rows: try c.decode(UInt16.self, forKey: .rows))
        case "event": self = .event(try c.decode(WorkspaceEvent.self, forKey: .e))
        case "exited": self = .exited(code: try c.decode(Int32.self, forKey: .code))
        case "overflow": self = .overflow
        case "replaced": self = .replaced
        case "videoMeta": self = .videoMeta(width: try c.decode(UInt32.self, forKey: .width), height: try c.decode(UInt32.self, forKey: .height))
        case "video":
            self = .video(try c.decode(Data.self, forKey: .d), pts: try c.decode(UInt64.self, forKey: .pts),
                          config: try c.decode(Bool.self, forKey: .config), key: try c.decode(Bool.self, forKey: .key))
        case "jpeg": self = .jpeg(try c.decode(Data.self, forKey: .d))
        case "deviceStatus":
            self = .deviceStatus(state: try c.decode(String.self, forKey: .state), message: try c.decodeIfPresent(String.self, forKey: .message))
        case "call":
            self = .call(id: try c.decode(String.self, forKey: .id), panel: try c.decode(UUID.self, forKey: .panel),
                         command: try c.decode(String.self, forKey: .command), args: try c.decode([String: JSONValue].self, forKey: .args),
                         timeoutSeconds: try c.decode(Double.self, forKey: .timeout))
        case "reply":
            self = .reply(id: try c.decode(String.self, forKey: .id), result: try c.decodeIfPresent(JSONValue.self, forKey: .result),
                          error: try c.decodeIfPresent(ProtocolError.self, forKey: .error))
        case "emit":
            self = .emit(panel: try c.decode(UUID.self, forKey: .panel), name: try c.decode(String.self, forKey: .name),
                         payload: try c.decode(JSONValue.self, forKey: .payload))
        case let t: throw DecodingError.dataCorruptedError(forKey: .t, in: c, debugDescription: "unknown frame '\(t)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .out(let d): try c.encode("out", forKey: .t); try c.encode(d, forKey: .d)
        case .replay(let d, let tr):
            try c.encode("replay", forKey: .t); try c.encode(d, forKey: .d); try c.encode(tr, forKey: .truncated)
        case .in(let d): try c.encode("in", forKey: .t); try c.encode(d, forKey: .d)
        case .resize(let cols, let rows):
            try c.encode("resize", forKey: .t); try c.encode(cols, forKey: .cols); try c.encode(rows, forKey: .rows)
        case .event(let e): try c.encode("event", forKey: .t); try c.encode(e, forKey: .e)
        case .exited(let code): try c.encode("exited", forKey: .t); try c.encode(code, forKey: .code)
        case .overflow: try c.encode("overflow", forKey: .t)
        case .replaced: try c.encode("replaced", forKey: .t)
        case .videoMeta(let w, let h): try c.encode("videoMeta", forKey: .t); try c.encode(w, forKey: .width); try c.encode(h, forKey: .height)
        case .video(let d, let pts, let config, let key):
            try c.encode("video", forKey: .t); try c.encode(d, forKey: .d); try c.encode(pts, forKey: .pts)
            try c.encode(config, forKey: .config); try c.encode(key, forKey: .key)
        case .jpeg(let d): try c.encode("jpeg", forKey: .t); try c.encode(d, forKey: .d)
        case .deviceStatus(let state, let message):
            try c.encode("deviceStatus", forKey: .t); try c.encode(state, forKey: .state); try c.encodeIfPresent(message, forKey: .message)
        case .call(let id, let panel, let command, let args, let timeout):
            try c.encode("call", forKey: .t); try c.encode(id, forKey: .id); try c.encode(panel, forKey: .panel)
            try c.encode(command, forKey: .command); try c.encode(args, forKey: .args); try c.encode(timeout, forKey: .timeout)
        case .reply(let id, let result, let error):
            try c.encode("reply", forKey: .t); try c.encode(id, forKey: .id)
            try c.encodeIfPresent(result, forKey: .result); try c.encodeIfPresent(error, forKey: .error)
        case .emit(let panel, let name, let payload):
            try c.encode("emit", forKey: .t); try c.encode(panel, forKey: .panel); try c.encode(name, forKey: .name)
            try c.encode(payload, forKey: .payload)
        }
    }

    /// The frame as one wire line (JSON + "\n").
    public var line: Data {
        var d = (try? JSONEncoder().encode(self)) ?? Data()
        d.append(10)
        return d
    }
}

/// `ui.snapshot` result. `badges` is keyed by terminal id (uuid string); every record that is not running is `stopped`.
public struct WorkspaceSnapshot: Codable, Sendable, Equatable {
    public var terminals: [TerminalRecord]
    public var connections: [Connection]
    public var badges: [String: StatusBadge]
    public var paddocks: [Paddock]
    public var panels: [Panel]
    /// `BuildID` of the daemon's executable (nil from a daemon that predates it).
    public var build: String?
    public init(terminals: [TerminalRecord], connections: [Connection], badges: [String: StatusBadge], paddocks: [Paddock] = [], panels: [Panel] = [], build: String? = nil) {
        self.terminals = terminals; self.connections = connections; self.badges = badges; self.paddocks = paddocks; self.panels = panels; self.build = build
    }
    private enum K: String, CodingKey { case terminals, connections, badges, paddocks, panels, build }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        terminals = try c.decode([TerminalRecord].self, forKey: .terminals)
        connections = try c.decode([Connection].self, forKey: .connections)
        badges = try c.decode([String: StatusBadge].self, forKey: .badges)
        paddocks = try c.decodeIfPresent([Paddock].self, forKey: .paddocks) ?? []
        panels = try c.decodeIfPresent([Panel].self, forKey: .panels) ?? []
        build = try c.decodeIfPresent(String.self, forKey: .build)
    }
}

public enum WorkspaceEvent: Codable, Sendable, Equatable {
    case spawned(TerminalRecord), exited(UUID, Int32), removed(UUID),
         connected(Connection), disconnected(Connection),
         attention(UUID, reason: String), status(UUID, StatusBadge),
         paddock(Paddock), paddockRemoved(UUID), notify(UUID, message: String),   // paddock/panel = upsert
         panel(Panel), panelRemoved(UUID), pluginEvent(panel: UUID, name: String, payload: JSONValue),
         terminal(TerminalRecord),   // upsert (edited in place)
         /// A herd was applied: `by` the applying terminal (nil = the app), `anchor` the Shepherd whose frame the
         /// layout is relative to (nil: none), `frames` by terminal/panel id, `paddock` the paddock it created (nil: none).
         /// The app places the nodes.
         herdApplied(by: UUID?, anchor: UUID?, frames: [String: HerdFrame], paddock: UUID?)

    private enum K: String, CodingKey { case t, r, id, code, c, reason, badge, f, message, p, name, payload, by, anchor, frames, paddock }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        func id() throws -> UUID { try c.decode(UUID.self, forKey: .id) }
        switch try c.decode(String.self, forKey: .t) {
        case "spawned": self = .spawned(try c.decode(TerminalRecord.self, forKey: .r))
        case "exited": self = .exited(try id(), try c.decode(Int32.self, forKey: .code))
        case "removed": self = .removed(try id())
        case "connected": self = .connected(try c.decode(Connection.self, forKey: .c))
        case "disconnected": self = .disconnected(try c.decode(Connection.self, forKey: .c))
        case "attention": self = .attention(try id(), reason: try c.decode(String.self, forKey: .reason))
        case "status": self = .status(try id(), try c.decode(StatusBadge.self, forKey: .badge))
        case "paddock": self = .paddock(try c.decode(Paddock.self, forKey: .f))
        case "paddockRemoved": self = .paddockRemoved(try id())
        case "notify": self = .notify(try id(), message: try c.decode(String.self, forKey: .message))
        case "terminal": self = .terminal(try c.decode(TerminalRecord.self, forKey: .r))
        case "panel": self = .panel(try c.decode(Panel.self, forKey: .p))
        case "panelRemoved": self = .panelRemoved(try id())
        case "pluginEvent": self = .pluginEvent(panel: try id(), name: try c.decode(String.self, forKey: .name), payload: try c.decode(JSONValue.self, forKey: .payload))
        case "herdApplied":
            self = .herdApplied(by: try c.decodeIfPresent(UUID.self, forKey: .by), anchor: try c.decodeIfPresent(UUID.self, forKey: .anchor),
                                     frames: try c.decode([String: HerdFrame].self, forKey: .frames),
                                     paddock: try c.decodeIfPresent(UUID.self, forKey: .paddock))
        case let t: throw DecodingError.dataCorruptedError(forKey: .t, in: c, debugDescription: "unknown event '\(t)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .spawned(let r): try c.encode("spawned", forKey: .t); try c.encode(r, forKey: .r)
        case .exited(let id, let code): try c.encode("exited", forKey: .t); try c.encode(id, forKey: .id); try c.encode(code, forKey: .code)
        case .removed(let id): try c.encode("removed", forKey: .t); try c.encode(id, forKey: .id)
        case .connected(let x): try c.encode("connected", forKey: .t); try c.encode(x, forKey: .c)
        case .disconnected(let x): try c.encode("disconnected", forKey: .t); try c.encode(x, forKey: .c)
        case .attention(let id, let r): try c.encode("attention", forKey: .t); try c.encode(id, forKey: .id); try c.encode(r, forKey: .reason)
        case .status(let id, let b): try c.encode("status", forKey: .t); try c.encode(id, forKey: .id); try c.encode(b, forKey: .badge)
        case .paddock(let f): try c.encode("paddock", forKey: .t); try c.encode(f, forKey: .f)
        case .paddockRemoved(let id): try c.encode("paddockRemoved", forKey: .t); try c.encode(id, forKey: .id)
        case .notify(let id, let m): try c.encode("notify", forKey: .t); try c.encode(id, forKey: .id); try c.encode(m, forKey: .message)
        case .terminal(let r): try c.encode("terminal", forKey: .t); try c.encode(r, forKey: .r)
        case .panel(let x): try c.encode("panel", forKey: .t); try c.encode(x, forKey: .p)
        case .panelRemoved(let id): try c.encode("panelRemoved", forKey: .t); try c.encode(id, forKey: .id)
        case .pluginEvent(let id, let n, let pl):
            try c.encode("pluginEvent", forKey: .t); try c.encode(id, forKey: .id); try c.encode(n, forKey: .name); try c.encode(pl, forKey: .payload)
        case .herdApplied(let by, let anchor, let frames, let paddock):
            try c.encode("herdApplied", forKey: .t); try c.encodeIfPresent(by, forKey: .by)
            try c.encodeIfPresent(anchor, forKey: .anchor); try c.encode(frames, forKey: .frames); try c.encodeIfPresent(paddock, forKey: .paddock)
        }
    }
}
