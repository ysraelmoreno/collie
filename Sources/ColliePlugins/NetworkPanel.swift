import AppKit
import Foundation
import CollieCore
import CollieNetwork
import CollieProtocol
import SwiftUI

/// `network.get`: the whole flow plus the daemon's decoded bodies (`reqBodyText`/`resBodyText`, JSON already pretty).
public struct FlowDetail: Decodable, Equatable, Sendable {
    public let flow: Flow
    public let reqText: String?, resText: String?
    enum K: String, CodingKey { case reqBodyText, resBodyText }
    public init(from d: Decoder) throws {
        flow = try Flow(from: d)
        let c = try d.container(keyedBy: K.self)
        reqText = try c.decodeIfPresent(String.self, forKey: .reqBodyText)
        resText = try c.decodeIfPresent(String.self, forKey: .resBodyText)
    }
    public init(flow: Flow, reqText: String? = nil, resText: String? = nil) { self.flow = flow; self.reqText = reqText; self.resText = resText }
}

/// A `network.flow` row: the summary and the emulator it came from (panels are not bound to a serial).
public struct FlowRow: Identifiable, Equatable, Sendable {
    public let serial: String
    public var summary: FlowSummary
    public var id: String { summary.id }
}

/// How a row's status reads: one color per class.
public enum FlowTone: Equatable, Sendable { case success, redirect, clientError, serverError, failed, pending, tunneled }

/// What the body pane shows.
public enum BodyView: Equatable, Sendable { case empty, text(String), hex(String) }

/// State and daemon calls of the Network panel: `device.list`, `network.*` and the `network.flow` events.
@MainActor public final class NetworkPanelModel: ObservableObject {
    /// Online emulators (`device.list`, android `emulator-*` in state `device`).
    @Published public private(set) var emulators: [String] = []
    @Published public var serial: String?
    @Published public private(set) var attached = false
    @Published public private(set) var port: Int?
    /// Packages that must restart to read the CA (attach's `restartSuggested`).
    @Published public private(set) var restartSuggested: [String] = []
    @Published public private(set) var error: String?
    @Published public private(set) var busy = false
    /// Oldest first, every serial.
    @Published public private(set) var rows: [FlowRow] = []
    @Published public var filter = ""
    @Published public private(set) var selected: String?
    @Published public private(set) var detail: FlowDetail?

    // ponytail: same cap as the daemon's store; older rows go first
    static let maxRows = 2000
    private let call: PanelHostContext.Call

    public init(call: @escaping PanelHostContext.Call, serial: String? = nil) { self.call = call; self.serial = serial }

    /// The selected emulator's rows matching `filter` (method, host, path or status; case-insensitive).
    public var visible: [FlowRow] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return rows.filter { r in
            r.serial == serial && (q.isEmpty || [r.summary.method, r.summary.host, r.summary.path, r.summary.status.map(String.init) ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(q) })
        }
    }

    // MARK: events

    /// A `network.flow`: replaces the row with that id (same serial) or appends it.
    public func apply(event: String, payload: JSONValue) {
        guard event == "network.flow", case .object(let o) = payload, case .string(let s)? = o["serial"],
              let summary = Self.decode(FlowSummary.self, payload) else { return }
        if let i = rows.firstIndex(where: { $0.id == summary.id && $0.serial == s }) { rows[i].summary = summary }
        else { rows.append(FlowRow(serial: s, summary: summary)); if rows.count > Self.maxRows { rows.removeFirst(rows.count - Self.maxRows) } }
        if selected == summary.id, s == serial { Task { await loadDetail() } }   // the response arrived
    }

    // MARK: commands

    /// Emulators, then the selected one's capture state (and its flows when attached).
    public func refresh() async {
        struct Dev: Decodable { let serial: String; let state: String; let platform: String? }
        do throws(ProtocolError) {
            emulators = try await fetch([Dev].self, "device.list", [:])
                .filter { $0.platform != "ios" && $0.state == "device" && $0.serial.hasPrefix("emulator-") }.map(\.serial)
        } catch { self.error = Self.describe(error) }
        if serial == nil || !emulators.contains(serial!) && !attached { serial = emulators.first }
        await loadStatus()
    }

    public func select(serial s: String) async {
        serial = s; selected = nil; detail = nil; restartSuggested = []; error = nil
        await loadStatus()
    }

    func loadStatus() async {
        guard let serial else { attached = false; port = nil; return }
        struct Status: Decodable { let attached: Bool; let port: Int? }
        do throws(ProtocolError) {
            let s = try await fetch(Status.self, "network.status", ["serial": .string(serial)])
            attached = s.attached; port = s.port
            if s.attached { await loadList() }
        } catch { self.error = Self.describe(error) }
    }

    /// Seeds the rows with what the daemon already captured (events only bring what comes next).
    private func loadList() async {
        guard let serial, let list = try? await fetch([FlowSummary].self, "network.list", ["serial": .string(serial), "limit": .number(Double(Self.maxRows))])
        else { return }
        rows.removeAll { $0.serial == serial }
        rows += list.map { FlowRow(serial: serial, summary: $0) }
    }

    /// Interceptar / Parar.
    public func toggle() async {
        guard let serial, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        struct Attach: Decodable { let port: Int?; let restartSuggested: [String]? }
        do throws(ProtocolError) {
            if attached {
                _ = try await call("network.detach", ["serial": .string(serial)])
                attached = false; port = nil; restartSuggested = []
            } else {
                let a = try await fetch(Attach.self, "network.attach", ["serial": .string(serial)])
                attached = true; port = a.port; restartSuggested = a.restartSuggested ?? []
                await loadList()
            }
        } catch { self.error = Self.describe(error) }
    }

    public func clear() async {
        guard let serial else { return }
        do throws(ProtocolError) { _ = try await call("network.clear", ["serial": .string(serial)]) } catch { self.error = Self.describe(error); return }
        rows.removeAll { $0.serial == serial }
        selected = nil; detail = nil
    }

    public func select(flow id: String?) async {
        selected = id; detail = nil
        await loadDetail()
    }

    private func loadDetail() async {
        guard let id = selected, let serial else { return }
        do throws(ProtocolError) {
            let d = try await fetch(FlowDetail.self, "network.get", ["serial": .string(serial), "id": .string(id)])
            if selected == id { detail = d }
        } catch { self.error = Self.describe(error) }
    }

    /// The selected flow's request as cURL, on the pasteboard.
    public func copyCurl() async {
        guard let id = selected, let serial else { return }
        struct C: Decodable { let curl: String }
        do throws(ProtocolError) {
            Self.copy(try await fetch(C.self, "network.curl", ["serial": .string(serial), "id": .string(id)]).curl)
        } catch { self.error = Self.describe(error) }
    }

    public func copyURL() { if let u = detail?.flow.url { Self.copy(u) } }

    static func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }

    // MARK: formatting

    public static func tone(_ s: FlowSummary) -> FlowTone {
        switch s.state {
        case .failed: return .failed
        case .tunneled: return .tunneled
        case .pending: return .pending
        case .done:
            switch s.status ?? 0 {
            case 500...: return .serverError
            case 400..<500: return .clientError
            case 300..<400: return .redirect
            default: return .success
            }
        }
    }

    /// The status column: code, "falha", "túnel" or "…".
    public static func statusText(_ s: FlowSummary) -> String {
        switch s.state {
        case .failed: "falha"
        case .tunneled: "túnel"
        case .pending: "…"
        case .done: s.status.map(String.init) ?? "—"
        }
    }

    public static func size(_ bytes: Int?) -> String {
        guard let b = bytes else { return "—" }
        if b < 1024 { return "\(b) B" }
        let kb = Double(b) / 1024
        return kb < 1024 ? String(format: "%.1f KB", kb) : String(format: "%.1f MB", kb / 1024)
    }

    public static func duration(_ ms: Int?) -> String {
        guard let ms else { return "—" }
        return ms < 1000 ? "\(ms) ms" : String(format: "%.2f s", Double(ms) / 1000)
    }

    /// Decoded text when the daemon had it; otherwise UTF-8 of an unencoded body, else a hex dump.
    public static func body(_ b: Body?, text: String?) -> BodyView {
        if let text { return .text(text) }
        guard let b, !b.data.isEmpty else { return .empty }
        if b.contentEncoding == nil || b.contentEncoding == "identity", let s = String(data: b.data, encoding: .utf8) { return .text(s) }
        return .hex(hex(b.data))
    }

    /// 16 bytes per line: offset, hex, ASCII.
    // ponytail: the whole captured body (the addon caps it); page it if big bodies make the view slow
    public static func hex(_ d: Data) -> String {
        let bytes = [UInt8](d)
        return stride(from: 0, to: bytes.count, by: 16).map { o in
            let line = bytes[o..<min(o + 16, bytes.count)]
            let h = line.map { String(format: "%02x", $0) }.joined(separator: " ")
            let a = String(line.map { (0x20..<0x7f).contains($0) ? Character(UnicodeScalar($0)) : "." })
            return String(format: "%08x  ", o) + h.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + a
        }.joined(separator: "\n")
    }

    /// The daemon's English errors, readable; mitmproxy's install hint is kept as is.
    static func describe(_ e: ProtocolError) -> String {
        let m = e.message
        if m.contains("brew install") { return m }
        if m == "No emulator online" { return "Nenhum emulador ligado." }
        if m.hasPrefix("No network panel reachable") { return "Nenhum painel Rede alcançável." }
        if m.contains("is not being captured") { return "Esse emulador não está sendo interceptado." }
        return m
    }

    private func fetch<T: Decodable>(_ t: T.Type, _ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> T {
        let v = try await call(command, args)
        guard let r = Self.decode(t, v) else { throw ProtocolError(code: .internal, message: "Resposta inválida de \(command).") }
        return r
    }

    /// Dates in epoch seconds (the daemon's `NetworkService.json`).
    static func decode<T: Decodable>(_ t: T.Type, _ v: JSONValue) -> T? {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(t, from: JSONEncoder().encode(v))
    }
}

/// The Network plug-in's view: captures an Android emulator's HTTP(S) through the daemon (`network.*`).
@MainActor public final class NetworkPanel: PluginPanelView {
    let model: NetworkPanelModel
    public let view: NSView
    public init(panel: Panel, host: PanelHostContext) {
        let serial: String? = if case .string(let v)? = panel.state["serial"] { v } else { nil }
        model = NetworkPanelModel(call: host.call, serial: serial)
        view = NSHostingView(rootView: NetworkView(model: model))
        Task { [model] in await model.refresh() }
    }
    public func handle(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        throw ProtocolError(code: .unavailable, message: "network commands run in the daemon")
    }
    public func close() {}
    public func receive(event: String, payload: JSONValue) { model.apply(event: event, payload: payload) }
}
