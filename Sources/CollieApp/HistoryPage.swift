import Foundation
import Observation
import CollieCore
import CollieClient
import CollieProtocol

/// A closed work's detail as one self-contained HTML page for the Prévia: inline CSS (light/dark by the system), no
/// script, no external resource (a CSP says so too: a missed escape one day still runs nothing). Every text that came from the work goes through `esc` once and only lands in element
/// content, never in an attribute, `href`, `src` or `style`.
enum HistoryPage {
    static func esc(_ s: String) -> String {
        var o = ""; o.reserveCapacity(s.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": o += "&amp;"; case "<": o += "&lt;"; case ">": o += "&gt;"; case "\"": o += "&quot;"; case "'": o += "&#39;"
            default: o.unicodeScalars.append(ch)
            }
        }
        return o
    }

    /// M8.3: the notices the page and the Laços modal show (one text for both).
    static var reconstructedNotice: String { tr("Resumo reconstruído de um trabalho fechado antes do arquivo imutável: o diário é curto.", "Summary rebuilt from a work closed before the immutable archive: the journal is short.") }
    static var truncatedNotice: String { tr("A linha do tempo foi cortada nos 500 eventos mais recentes.", "The timeline was cut to the 500 most recent events.") }

    /// M8.3: the work's data as (label, value), raw text (whoever renders escapes): the page's `<dl>` and the modal's detail.
    static func facts(for a: WorkArchive, timeZone: TimeZone = .current) -> [(label: String, value: String)] {
        var dur = "—"
        if let o = a.openedAt, let c = a.closedAt { let s = max(0, Int(c.timeIntervalSince(o))); dur = s >= 3600 ? "\(s / 3600)h\(String(format: "%02d", s % 3600 / 60))" : "\(s / 60)min \(s % 60)s" }
        let stop = a.stopReason.map { WorkLoopState.Stop(WorkLoopState.Stop.Code(rawValue: $0) ?? .unknown).label + " (\($0))" } ?? "—"
        return [(tr("Cercado", "Paddock"), a.paddock), ("Branch", a.branch), (tr("Abertura", "Opened"), format("dd/MM/yyyy HH:mm:ss", a.openedAt, timeZone)),
                (tr("Fechamento", "Closed"), format("dd/MM/yyyy HH:mm:ss", a.closedAt, timeZone)), (tr("Duração", "Duration"), dur), (tr("Motivo de parada", "Stop reason"), stop)]
    }

    static func format(_ pattern: String, _ d: Date?, _ timeZone: TimeZone) -> String {
        guard let d else { return "—" }
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.timeZone = timeZone; f.dateFormat = pattern
        return f.string(from: d)
    }

    static func html(for a: WorkArchive, timeZone: TimeZone = .current) -> String {
        func clock(_ d: Date?) -> String { format("HH:mm:ss", d, timeZone) }
        var h = """
        <!doctype html><html lang="\(tr("pt-BR", "en"))"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <title>\(esc(a.title))</title><style>
        :root{color-scheme:light dark;--bg:#faf9f7;--fg:#1f1d1a;--mute:#6b665f;--line:#ddd8d0;--warn:#fff3d6}
        @media (prefers-color-scheme:dark){:root{--bg:#1c1b19;--fg:#ece8e1;--mute:#9a948b;--line:#3a3733;--warn:#4a3d1c}}
        body{background:var(--bg);color:var(--fg);font:14px/1.5 -apple-system,system-ui,sans-serif;margin:24px auto;max-width:960px;padding:0 16px}
        h1{font-size:22px;margin:0 0 8px}h2{font-size:15px;margin:28px 0 8px;color:var(--mute);text-transform:uppercase;letter-spacing:.05em}
        dl{display:grid;grid-template-columns:max-content 1fr;gap:4px 16px;margin:0}dt{color:var(--mute)}dd{margin:0;overflow-wrap:anywhere}
        table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top;overflow-wrap:anywhere}
        th{color:var(--mute);font-weight:600}code{font-family:ui-monospace,Menlo,monospace}.warn{background:var(--warn);padding:8px 12px;border-radius:6px;margin:12px 0}
        </style></head><body>
        <h1>\(esc(a.title))</h1>
        """
        if a.reconstructed { h += "<p class=\"warn\">\(reconstructedNotice)</p>" }
        if a.truncated { h += "<p class=\"warn\">\(truncatedNotice)</p>" }
        h += "<dl>" + facts(for: a, timeZone: timeZone).map { f in
            "<dt>\(f.label)</dt><dd>" + (f.label == "Branch" ? "<code>\(esc(f.value))</code>" : esc(f.value)) + "</dd>"
        }.joined() + "</dl>"
        h += tr("<h2>Tarefas</h2><table><tr><th>Tarefa</th><th>Estado</th><th>Tentativas</th><th>Commits</th><th>Razão / nota</th></tr>", "<h2>Tasks</h2><table><tr><th>Task</th><th>State</th><th>Attempts</th><th>Commits</th><th>Reason / note</th></tr>")
        for t in a.tasks {
            let commits = t.commits.map { "<code>\(esc(String($0.prefix(8))))</code>" }.joined(separator: " ")
            let why = [t.failure, t.evidenceNote].compactMap { $0 }.map(esc).joined(separator: "<br>")
            h += "<tr><td>\(esc(t.id)) \(esc(t.title))</td><td>\(esc(t.state))</td><td>\(t.tries)</td><td>\(commits)</td><td>\(why)</td></tr>"
        }
        h += tr("</table><h2>Linha do tempo</h2><table><tr><th>Hora</th><th>Tarefa</th><th>Tipo</th><th>Detalhe</th></tr>", "</table><h2>Timeline</h2><table><tr><th>Time</th><th>Task</th><th>Kind</th><th>Detail</th></tr>")
        for e in a.timeline { h += "<tr><td>\(esc(clock(e.at)))</td><td>\(esc(e.task ?? ""))</td><td>\(esc(e.kind))</td><td>\(esc(e.detail))</td></tr>" }
        h += "</table>"
        if !a.loopSummary.isEmpty { h += "<h2>\(tr("Resumo do laço", "Loop summary"))</h2><p>\(esc(a.loopSummary))</p>" }
        if !a.notes.isEmpty { h += "<h2>\(tr("Notas", "Notes"))</h2><ul>" + a.notes.map { "<li>\(esc($0))</li>" }.joined() + "</ul>" }
        return h + "</body></html>"
    }

    /// The artifact source of a work's detail, `history-<uuid>` (lowercased), stable per work: opening it again is that
    /// artifact's next version, never a new one. nil for an id that is not a UUID.
    static func source(id: String) -> String? { UUID(uuidString: id).map { "history-" + $0.uuidString.lowercased() } }
}

/// The HISTÓRICO click: asks `work.history --id`, adds the page as an artifact (`artifact.add`, the work's stable
/// source) and opens it in a Prévia by `artifact:`, once per work while that panel is open. Nothing is written by the app.
@MainActor @Observable final class HistoryOpener {
    @ObservationIgnored var fetch: (String) async throws -> WorkArchive
    /// `artifact.add` of `(html, source, title)`; returns the artifact id.
    @ObservationIgnored var add: (String, String, String) async throws -> String
    /// Opens a Prévia on the artifact and returns its panel id.
    @ObservationIgnored var open: (String) async throws -> UUID
    /// Is the panel still there? (a closed one is opened again.)
    @ObservationIgnored var isOpen: (UUID) -> Bool
    @ObservationIgnored var focus: (UUID) -> Void
    /// A short notice for the section (fixed text, never the protocol's message nor a path); nil once a detail opens.
    private(set) var message: String?
    nonisolated static var failure: String { tr("Não foi possível abrir o histórico", "Couldn't open the history") }
    @ObservationIgnored private var panels: [String: UUID] = [:]

    init(fetch: @escaping (String) async throws -> WorkArchive, add: @escaping (String, String, String) async throws -> String,
         open: @escaping (String) async throws -> UUID, isOpen: @escaping (UUID) -> Bool, focus: @escaping (UUID) -> Void) {
        self.fetch = fetch; self.add = add; self.open = open; self.isOpen = isOpen; self.focus = focus
    }

    func show(_ id: String) async {
        message = nil   // a notice is about the last try only
        guard let source = HistoryPage.source(id: id) else { message = tr("Histórico: id inválido", "History: invalid id"); return }
        if let p = panels[source], isOpen(p) { return focus(p) }
        do {
            let a = try await fetch(id)
            let art = try await add(HistoryPage.html(for: a), source, a.title)
            panels[source] = try await open(art); message = nil
        } catch { message = Self.failure }
    }
}

extension HistoryOpener {
    /// `work.history --id`: a closed work's `WorkArchive` (the Prévia page and the Laços modal's detail, M8.3).
    static func archive(_ id: String, client: DaemonClient) async throws -> WorkArchive {
        let v = try await client.adminCall("work.history", ["id": .string(id)])
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(WorkArchive.self, from: JSONEncoder().encode(v))
    }

    /// The app's wiring: `work.history --id` and `artifact.add` (inline page) over the admin socket, a Prévia through `panel.open`.
    static func live(client: DaemonClient, focus: @escaping (UUID) -> Void) -> HistoryOpener {
        HistoryOpener(fetch: { try await archive($0, client: client) }, add: { html, source, title in
            guard case .object(let o) = try await client.adminCall("artifact.add", ["html": .string(html), "source": .string(source), "title": .string(title)]),
                  case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "malformed artifact.add reply") }
            return id
        }, open: { try await client.openPanel(plugin: "preview", name: nil, placement: .canvas, url: nil, storage: .isolated, artifact: $0) },
           isOpen: { id in client.panels.contains { $0.id == id } }, focus: focus)
    }
}
