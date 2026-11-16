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
    /// Computed once, off the main actor when decoded: a view body must not touch up to 10 MiB per render.
    public let reqPreview: BodyPreview, resPreview: BodyPreview
    enum K: String, CodingKey { case reqBodyText, resBodyText }
    public init(from d: Decoder) throws {
        flow = try Flow(from: d)
        let c = try d.container(keyedBy: K.self)
        reqText = try c.decodeIfPresent(String.self, forKey: .reqBodyText)
        resText = try c.decodeIfPresent(String.self, forKey: .resBodyText)
        reqPreview = NetworkPanelModel.body(flow.reqBody, text: reqText)
        resPreview = NetworkPanelModel.body(flow.resBody, text: resText)
    }
    public init(flow: Flow, reqText: String? = nil, resText: String? = nil) {
        self.flow = flow; self.reqText = reqText; self.resText = resText
        reqPreview = NetworkPanelModel.body(flow.reqBody, text: reqText)
        resPreview = NetworkPanelModel.body(flow.resBody, text: resText)
    }
}

/// A `network.rule-list` row (no body: `bodySize`).
public struct RuleRow: Decodable, Identifiable, Equatable, Sendable {
    public struct Match: Decodable, Equatable, Sendable { public var method: String?, host: String?, path: String?; public var query: [String: String]? }
    public let id: String
    public let name: String?
    public let enabled: Bool
    public let match: Match
    /// "local" or "drop".
    public let action: String
    public let status: Int?
    public let bodySize: Int?
    public let delayMs: Int
    /// Matches every request.
    public let empty: Bool

    /// "GET api.example.com/pdp/* → 200 · 2.1 KB", "… → queda", plus " · atraso 8 s".
    public var summary: String {
        let q = (match.query ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        let target = empty ? "toda requisição"
            : [match.method, (match.host ?? "*") + (match.path ?? "") + (q.isEmpty ? "" : "?" + q)].compactMap { $0 }.joined(separator: " ")
        let what = action == "drop" ? "queda" : "\(status ?? 200) · \(NetworkPanelModel.size(bodySize ?? 0))"
        return "\(target) → \(what)" + (delayMs > 0 ? " · atraso \(NetworkPanelModel.duration(delayMs))" : "")
    }
}

/// "Mapear esta resposta": prefilled from a captured flow, sent as `network.rule-add --from <id>` with the edits.
public struct MapForm: Equatable, Sendable {
    public var from: String?
    public var name = "", method = "", host = "", path = "", query = ""
    public var drop = false
    public var status = 200, delayMs = 0
    /// One "Name: value" per line.
    public var headers = ""
    /// nil: keep the captured body (binary, or not shown); the daemon copies it decoded.
    public var body: String?
    /// "escolher um arquivo": the daemon reads it (≤ 5 MiB) instead of `body`.
    public var bodyFile: String?
    /// Ligar agora.
    public var enabled = true

    public init() {}

    /// The flow's method, host, path (no query) and query; its status, useful headers and decoded body.
    public init(_ d: FlowDetail) {
        let f = d.flow, u = URLComponents(string: f.url)
        // the addon globs mitmproxy's raw path (glob characters escaped here) and compares decoded query values
        from = f.id; method = f.method; host = u?.host ?? ""
        path = (u?.percentEncodedPath ?? "").map { "[*?".contains($0) ? "[\($0)]" : String($0) }.joined()
        query = (u?.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        status = f.status ?? 200
        headers = f.resHeaders.filter { !["content-encoding", "content-length", "transfer-encoding", "date"].contains($0.name.lowercased()) }
            .map { "\($0.name): \($0.value)" }.joined(separator: "\n")
        if case .text(let t) = d.resPreview.view, !d.resPreview.isPartial { body = t }
    }

    /// Shown above "Salvar regra" when nothing narrows the match.
    public var warning: String? {
        [method, host, path, query].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            ? "Sem método, host, caminho nem query: a regra responde a toda requisição do emulador." : nil
    }

    func args(serial: String?) -> [String: JSONValue] {
        func t(_ s: String) -> String? { let v = s.trimmingCharacters(in: .whitespaces); return v.isEmpty ? nil : v }
        func lines(_ s: String, _ sep: Character) -> [JSONValue] {
            s.split(separator: sep).compactMap { t(String($0)) }.map { .string($0) }
        }
        var a: [String: JSONValue] = [:]
        if let from { a["from"] = .string(from); if let serial { a["serial"] = .string(serial) } }
        for (k, v) in [("name", name), ("method", method), ("host", host), ("path", path)] { if let v = t(v) { a[k] = .string(v) } }
        let q = lines(query, "&"); if !q.isEmpty { a["query"] = .array(q) }
        if delayMs > 0 { a["delay"] = .number(Double(delayMs)) }
        if !enabled { a["disabled"] = .bool(true) }
        if drop { a["drop"] = .bool(true); return a }
        a["status"] = .number(Double(status))
        let h = lines(headers, "\n"); if !h.isEmpty { a["header"] = .array(h) }
        if let bodyFile { a["body-file"] = .string(bodyFile) } else if let body { a["body"] = .string(body) }
        return a
    }
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

/// The start of a body, small enough for one `Text`; `shown` and `total` in bytes (of the text, or of the raw body in hex).
public struct BodyPreview: Equatable, Sendable {
    public let view: BodyView, shown: Int, total: Int
    public var isPartial: Bool { shown < total }
}

/// State and daemon calls of the Network panel: `device.list`, `network.*` and the `network.flow` events.
@MainActor public final class NetworkPanelModel: ObservableObject {
    /// Online emulators (`device.list`, android `emulator-*` in state `device`).
    @Published public private(set) var emulators: [String] = []
    @Published public var serial: String?
    @Published public private(set) var attached = false
    @Published public private(set) var port: Int?
    /// Packages that must restart to read the CA (attach's `restartSuggested`).
    @Published public private(set) var restartSuggested: [String] = []
    /// A detach failed on the device; the daemon retries it (`network.status`).
    @Published public private(set) var pendingDetach = false
    /// Addon lines the proxy lost (`network.status`).
    @Published public private(set) var dropped = 0
    @Published public private(set) var error: String?
    /// The last poll's failure; the next good one clears it.
    @Published public private(set) var pollError: String?
    @Published public private(set) var busy = false
    /// Oldest first, every serial.
    @Published public private(set) var rows: [FlowRow] = []
    @Published public var filter = ""
    @Published public private(set) var selected: String?
    @Published public private(set) var detail: FlowDetail?
    /// `network.rule-list`, in order.
    @Published public private(set) var rules: [RuleRow] = []

    // ponytail: same cap as the daemon's store; older rows go first
    static let maxRows = 2000
    nonisolated static let textPreviewLimit = 256 * 1024, hexPreviewLimit = 64 * 1024
    private let call: PanelHostContext.Call
    private let pollInterval: Duration
    /// Bumped by commands that change the capture: a status or list asked for before one is stale.
    private var captureGen = 0
    private var stopped = false
    /// Bumped per `loadDetail`: only the latest response applies.
    private var detailGen = 0

    public init(call: @escaping PanelHostContext.Call, serial: String? = nil, pollInterval: Duration = .seconds(5)) {
        self.call = call; self.serial = serial; self.pollInterval = pollInterval
    }

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
        // ponytail: a rule made elsewhere (CLI, agent) shows up by name; a removed one's flows refetch per event
        if let m = summary.mappedBy, !rules.contains(where: { $0.id == m }) { Task { await loadRules() } }
    }

    // MARK: commands

    /// While the view is on screen (its `.task`): `attached` follows a detach from the CLI, a daemon restart…
    public func pollLoop() async {
        while !Task.isCancelled, !stopped {
            await poll()
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// The panel closed.
    public func stop() { stopped = true }

    /// One pass: status always; the emulators only while idle (the picker is locked during a capture, and `device.list`
    /// runs adb and simctl).
    public func poll() async { if !busy { await refresh(devices: !attached) } }

    /// Emulators, then the selected one's capture state.
    public func refresh(devices: Bool = true) async {
        struct Dev: Decodable { let serial: String; let state: String; let platform: String? }
        var failure: String?
        if devices {
            do throws(ProtocolError) {
                emulators = try await fetch([Dev].self, "device.list", [:])
                    .filter { $0.platform != "ios" && $0.state == "device" && $0.serial.hasPrefix("emulator-") }.map(\.serial)
                if !attached, serial.map({ !emulators.contains($0) }) ?? true, serial != emulators.first {
                    serial = emulators.first; selected = nil; detail = nil
                }
            } catch { failure = Self.describe(error) }
        }
        let status = await loadStatus()
        pollError = status ?? failure
    }

    public func select(serial s: String) async {
        serial = s; selected = nil; detail = nil; restartSuggested = []; error = nil
        captureGen += 1
        pollError = await loadStatus()
    }

    /// nil, or why the status could not be read.
    func loadStatus() async -> String? {
        guard let serial else { attached = false; port = nil; pendingDetach = false; dropped = 0; return nil }
        struct Status: Decodable { let attached: Bool; let port: Int?; let pendingDetach: Bool?; let dropped: Int? }
        let gen = captureGen
        let s: Status
        do throws(ProtocolError) { s = try await fetch(Status.self, "network.status", ["serial": .string(serial)]) }
        catch { return Self.describe(error) }
        guard gen == captureGen, serial == self.serial else { return nil }
        let was = attached
        attached = s.attached; port = s.port; pendingDetach = s.pendingDetach ?? false; dropped = s.dropped ?? 0
        if s.attached {
            if !was { await loadList() }
        } else {
            restartSuggested = []
            if was { dropRows(serial) }
        }
        return nil
    }

    /// Seeds the rows with what the daemon already captured (events only bring what comes next).
    private func loadList() async {
        let gen = captureGen
        guard let serial, let list = try? await fetch([FlowSummary].self, "network.list", ["serial": .string(serial), "limit": .number(Double(Self.maxRows))]),
              gen == captureGen, serial == self.serial else { return }
        rows = Self.merged(rows, list, serial: serial)
    }

    /// `fetched` over the serial's rows: an event that arrived during the fetch stays (a row the list doesn't have yet, or
    /// one the list still has as pending).
    nonisolated static func merged(_ rows: [FlowRow], _ fetched: [FlowSummary], serial: String) -> [FlowRow] {
        let mine = Dictionary(rows.filter { $0.serial == serial }.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let listed = Set(fetched.map(\.id))
        let merged = fetched.map { f -> FlowRow in
            if let r = mine[f.id], f.state == .pending, r.summary.state != .pending { return r }
            return FlowRow(serial: serial, summary: f)
        }
        return rows.filter { $0.serial != serial } + merged + rows.filter { $0.serial == serial && !listed.contains($0.id) }
    }

    /// The daemon dropped the serial's flows with its session.
    private func dropRows(_ s: String) {
        rows.removeAll { $0.serial == s }
        if s == serial { selected = nil; detail = nil }
    }

    /// Interceptar / Parar. A failure may have changed the capture (a detach stays pending): the status says.
    public func toggle() async {
        guard let serial, !busy else { return }
        busy = true; error = nil
        captureGen += 1
        struct Attach: Decodable { let port: Int?; let restartSuggested: [String]? }
        var failed = false
        do throws(ProtocolError) {
            if attached {
                _ = try await call("network.detach", ["serial": .string(serial)])
                attached = false; port = nil; restartSuggested = []; pendingDetach = false; dropped = 0
                dropRows(serial)
            } else {
                let a = try await fetch(Attach.self, "network.attach", ["serial": .string(serial)])
                attached = true; port = a.port; restartSuggested = a.restartSuggested ?? []; pendingDetach = false
                await loadList()
            }
        } catch { self.error = Self.describe(error); failed = true }
        busy = false
        if failed { pollError = await loadStatus() }
    }

    public func clear() async {
        guard let serial else { return }
        dropRows(serial)   // before the call: a flow captured meanwhile is newer than the clear
        do throws(ProtocolError) { _ = try await call("network.clear", ["serial": .string(serial)]) } catch {
            self.error = Self.describe(error)
            await loadList()
        }
    }

    public func select(flow id: String?) async {
        selected = id; detail = nil; error = nil
        await loadDetail()
    }

    private func loadDetail() async {
        detailGen += 1
        let gen = detailGen
        guard let id = selected, let serial else { return }
        do throws(ProtocolError) {
            let v = try await call("network.get", ["serial": .string(serial), "id": .string(id)])
            // off main: base64 of up to 20 MB of bodies, and the previews
            guard let d = await Task.detached(operation: { Self.decode(FlowDetail.self, v) }).value else {
                throw ProtocolError(code: .internal, message: "Resposta inválida de network.get.")
            }
            if gen == detailGen, selected == id { detail = d }
        } catch {   // evicted, or the session ended: not "Carregando…" forever
            guard gen == detailGen, selected == id else { return }
            self.error = Self.describe(error)
            selected = nil; detail = nil
        }
    }

    // MARK: map rules

    public func loadRules() async {
        do throws(ProtocolError) { rules = try await fetch([RuleRow].self, "network.rule-list", [:]) }
        catch { self.error = Self.describe(error) }
    }

    /// Ligar / desligar. The app's own rules need no card.
    public func setRule(_ id: String, enabled: Bool) async { await ruleCall(enabled ? "network.rule-enable" : "network.rule-disable", ["id": .string(id)]) }
    public func removeRule(_ id: String) async { await ruleCall("network.rule-remove", ["id": .string(id)]) }
    public func clearRules() async { await ruleCall("network.rule-clear", [:]) }

    /// "Salvar regra" of "Mapear esta resposta": `rule-add --from` the flow, with the form's edits.
    public func saveMap(_ form: MapForm) async { await ruleCall("network.rule-add", form.args(serial: serial)) }

    private func ruleCall(_ command: String, _ args: [String: JSONValue]) async {
        error = nil
        do throws(ProtocolError) { _ = try await call(command, args) } catch { self.error = Self.describe(error) }
        await loadRules()
    }

    /// "mapeado · <rule name>" for a flow a rule answered (its id when the rule is gone or unnamed); nil otherwise.
    public func mappedBadge(_ s: FlowSummary) -> String? {
        guard let id = s.mappedBy else { return nil }
        return "mapeado · " + (rules.first { $0.id == id }?.name ?? id)
    }

    /// The detail's line under a mapped flow (nil: the server answered).
    public func mappedNotice(_ id: String?) -> String? {
        guard let id else { return nil }
        return "Resposta fabricada pela regra \(rules.first { $0.id == id }?.name ?? id). O servidor não foi chamado."
    }

    /// The bar's "N regras ligadas" (nil: none on).
    public var onLabel: String? {
        let n = rules.filter(\.enabled).count
        return n == 0 ? nil : n == 1 ? "1 regra ligada" : "\(n) regras ligadas"
    }

    /// Rules come back off at every daemon start: say so until the user turns on what they need.
    public var offNotice: String? {
        let n = rules.filter { !$0.enabled }.count
        guard n > 0 else { return nil }
        return n == 1 ? "1 regra salva está desligada. Ligue só o que precisa." : "\(n) regras salvas estão desligadas. Ligue só o que precisa."
    }

    /// The selected flow's request as cURL, on the pasteboard.
    public func copyCurl() async {
        guard let id = selected, let serial else { return }
        error = nil
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

    public nonisolated static func size(_ bytes: Int?) -> String {
        guard let b = bytes else { return "—" }
        if b < 1024 { return "\(b) B" }
        let kb = Double(b) / 1024
        return kb < 1024 ? String(format: "%.1f KB", kb) : String(format: "%.1f MB", kb / 1024)
    }

    public nonisolated static func duration(_ ms: Int?) -> String {
        guard let ms else { return "—" }
        return ms < 1000 ? "\(ms) ms" : String(format: "%.2f s", Double(ms) / 1000)
    }

    /// Decoded text when the daemon had it; otherwise UTF-8 of an unencoded body.
    private nonisolated static func text(_ b: Body?, _ text: String?) -> String? {
        if let text { return text }
        guard let b, b.contentEncoding == nil || b.contentEncoding == "identity" else { return nil }
        return String(data: b.data, encoding: .utf8)
    }

    /// The text up to `textPreviewLimit` (cut on a character), else a hex dump up to `hexPreviewLimit`.
    public nonisolated static func body(_ b: Body?, text t: String?) -> BodyPreview {
        if let s = text(b, t), !s.isEmpty {
            let total = s.utf8.count
            guard total > textPreviewLimit else { return BodyPreview(view: .text(s), shown: total, total: total) }
            var end = s.utf8.index(s.startIndex, offsetBy: textPreviewLimit)
            while end.samePosition(in: s.unicodeScalars) == nil { end = s.utf8.index(before: end) }
            let cut = String(s[..<end])
            return BodyPreview(view: .text(cut), shown: cut.utf8.count, total: total)
        }
        guard let b, !b.data.isEmpty else { return BodyPreview(view: .empty, shown: 0, total: 0) }
        let shown = min(b.data.count, hexPreviewLimit)
        return BodyPreview(view: .hex(hex(b.data.prefix(shown))), shown: shown, total: b.data.count)
    }

    /// What "Copiar body" copies: the whole text, base64 if binary; nil when there is no body.
    public nonisolated static func fullBody(_ b: Body?, text t: String?) -> String? {
        if let s = text(b, t), !s.isEmpty { return s }
        guard let b, !b.data.isEmpty else { return nil }
        return b.data.base64EncodedString()
    }

    /// 16 bytes per line: offset, hex, ASCII.
    public nonisolated static func hex(_ d: Data) -> String {
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
    nonisolated static func decode<T: Decodable>(_ t: T.Type, _ v: JSONValue) -> T? {
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
    }
    public func handle(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        throw ProtocolError(code: .unavailable, message: "network commands run in the daemon")
    }
    public func close() { model.stop() }
    public func receive(event: String, payload: JSONValue) { model.apply(event: event, payload: payload) }
}
