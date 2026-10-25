import AppKit
import CollieCore
import CollieProtocol
import CollieTheme
import SwiftUI
import WebKit

/// The Prévia's comments (plan 2W): pins drawn by a script in a world of their own, inside a closed shadow root on
/// `<html>` (the page can't see, move or click them, nor reach the message handler); threads and the composer in a
/// native drawer. Only the app creates, follows up and resolves (`comment.*` as admin through the panel host); the
/// script only reports where the user clicked and which pin was opened.
@MainActor final class PreviewComments: ObservableObject {
    static let world = WKContentWorld.world(name: "collie-comments")
    static let noAddressee = "Nenhum terminal ligado a esta prévia: ligue um para entregar"

    struct Message: Identifiable, Equatable { let id: String; let byName: String; let body: String; let at: Date?; let user: Bool }
    struct Thread: Identifiable, Equatable {
        let id: String; let short: String; let n: Int; let anchorText: String; let selector: String?; let x: Double; let y: Double
        let resolved: Bool; let notice: String?; let messages: [Message]
    }
    /// Where the user clicked in comment mode: the comment the composer will send.
    struct Draft: Equatable { let selector: String?; let x: Double; let y: Double; let text: String? }

    @Published private(set) var threads: [Thread] = []
    @Published private(set) var mode = false
    @Published var draft: Draft?
    @Published var drawer = false { didSet { onLayout() } }
    @Published var showAll = false
    @Published var selected: String?
    /// Threads whose element is gone: the pin stays at the stored point.
    @Published private(set) var approximate: Set<String> = []
    @Published var error: String?
    @Published private(set) var busy = false
    var openCount: Int { threads.filter { !$0.resolved }.count }

    /// `comment.*`'s page arguments (`artifact`, or `root` + `path`); nil: the panel shows no page to comment.
    let page: [String: JSONValue]?
    private let host: PanelHostContext
    private let title: () -> String
    weak var web: WKWebView?
    var onLayout: () -> Void = {}
    var onCount: (Int) -> Void = { _ in }

    init(host: PanelHostContext, page: [String: JSONValue]?, title: @escaping () -> String) {
        self.host = host; self.page = page; self.title = title
    }

    /// A Prévia panel's page arguments: its artifact, or its file relative to the project root.
    static func page(of panel: Panel) -> [String: JSONValue]? {
        func s(_ k: String) -> String? { if case .string(let v)? = panel.state[k], !v.isEmpty { v } else { nil } }
        if let a = s("artifact") { return ["artifact": .string(a)] }
        guard let r = s("root"), let f = s("file") else { return nil }
        let root = URL(fileURLWithPath: r)
        guard let url = try? PreviewFile.resolve(f, projectRoot: root) else { return nil }
        let real = DiagramFile.real(root).path
        return ["root": .string(real), "path": .string(String(url.path.dropFirst(real.count + 1)))]
    }

    func refresh() async {
        guard let page else { return }
        do throws(ProtocolError) {
            guard case .array(let rows) = try await host.call("comment.list", page) else { return }
            threads = rows.enumerated().compactMap { Self.thread($0.element, n: rows.count - $0.offset) }
            error = nil
        } catch { self.error = error.message }
        onCount(openCount)
        await drawPins()
    }

    /// The pins (every thread; resolved ones dimmed) and the mode, on the page now shown. Called after every load.
    func drawPins() async {
        guard let web else { return }
        let list: [[String: Any]] = threads.map {
            ["id": $0.id, "n": $0.n, "selector": $0.selector ?? NSNull(), "x": $0.x, "y": $0.y, "resolved": $0.resolved]
        }
        let r = try? await web.callAsyncJavaScript("if (!window.collieComments) return []; collieComments.mode(on); return collieComments.show(list)",
                                                   arguments: ["on": mode, "list": list], in: nil, contentWorld: Self.world)
        approximate = Set((r as? [String]) ?? [])
    }

    /// Comment mode: the next click on the page is the comment's point (swallowed, not the page's).
    func setMode(_ on: Bool) {
        mode = on
        if on { draft = nil; drawer = true }
        web?.evaluateJavaScript("window.collieComments && collieComments.mode(\(on))", in: nil, in: Self.world) { _ in }
    }

    /// A message of the pin script (its world only, main frame): `{click: {selector, x, y, text}}` in comment mode, or
    /// `{open: id}`. Clamped and capped: the page is untrusted (the script counts only trusted clicks, `isTrusted`).
    func received(_ body: Any) {
        guard let o = body as? [String: Any] else { return }
        if let id = o["open"] as? String {
            guard threads.contains(where: { $0.id == id }) else { return }
            selected = id; drawer = true
            return
        }
        guard mode, let c = o["click"] as? [String: Any], let x = (c["x"] as? NSNumber)?.doubleValue, let y = (c["y"] as? NSNumber)?.doubleValue,
              x.isFinite, y.isFinite else { return }
        mode = false
        let sel = (c["selector"] as? String).map { String($0.prefix(1000)) }
        let text = (c["text"] as? String).map { String($0.prefix(80)) }
        draft = Draft(selector: sel?.isEmpty == false ? sel : nil, x: min(max(x, 0), 1), y: min(max(y, 0), 1), text: text?.isEmpty == false ? text : nil)
        drawer = true
    }

    /// **Enviar** in the composer: `comment.add` with the draft's point, the page and this Prévia (its terminal receives it).
    func send(_ body: String) async {
        guard let d = draft, var args = page else { return }
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty else { return }
        args.merge(["title": .string(title()), "body": .string(b), "x": .number(d.x), "y": .number(d.y),
                    "panel": .string(host.panel.name)]) { $1 }
        if let s = d.selector { args["selector"] = .string(s) }
        if let t = d.text { args["text"] = .string(t) }
        if await run("comment.add", args) { draft = nil }
    }
    @discardableResult func followUp(_ id: String, _ body: String) async -> Bool {
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty else { return false }
        return await run("comment.message", ["id": .string(id), "body": .string(b)])
    }
    func setResolved(_ id: String, _ r: Bool) async { await run(r ? "comment.resolve" : "comment.unresolve", ["id": .string(id)]) }

    @discardableResult private func run(_ c: String, _ a: [String: JSONValue]) async -> Bool {
        busy = true
        defer { busy = false }
        do throws(ProtocolError) { _ = try await host.call(c, a) } catch { self.error = error.message; return false }
        error = nil
        await refresh()
        return true
    }

    static func thread(_ v: JSONValue, n: Int) -> Thread? {
        func s(_ v: JSONValue?) -> String? { if case .string(let x)? = v { x } else { nil } }
        func d(_ v: JSONValue?) -> Double { if case .number(let x)? = v { x } else { 0 } }
        guard case .object(let o) = v, let id = s(o["id"]) else { return nil }
        let a: [String: JSONValue] = if case .object(let a)? = o["anchor"] { a } else { [:] }
        let msgs: [Message] = if case .array(let m)? = o["messages"] {
            m.compactMap { v in
                guard case .object(let m) = v, let id = s(m["id"]) else { return nil }
                return Message(id: id, byName: s(m["byName"]) ?? "", body: s(m["body"]) ?? "",
                               at: s(m["at"]).flatMap { try? Date($0, strategy: .iso8601) }, user: m["byTerminal"] == nil || m["byTerminal"] == .null)
            }
        } else { [] }
        let notice: String? = o["undeliverable"] == .bool(true) ? "Não entregue: o terminal \(s(o["toName"]) ?? "") não existe mais"
            : s(o["to"]) == nil ? noAddressee : nil
        return Thread(id: id, short: s(o["short"]) ?? String(id.prefix(8)), n: n, anchorText: s(a["text"]) ?? s(a["selector"]) ?? "ponto da página",
                      selector: s(a["selector"]), x: d(a["x"]), y: d(a["y"]), resolved: o["resolved"] == .bool(true), notice: notice, messages: msgs)
    }

    /// Weak: the user content controller keeps its handlers alive.
    final class Bridge: NSObject, WKScriptMessageHandler {
        weak var owner: PreviewComments?
        init(_ o: PreviewComments) { owner = o }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            guard m.frameInfo.isMainFrame, m.world == PreviewComments.world else { return }
            owner?.received(m.body)
        }
    }

    /// At document start in `world`: a capturing click listener (in comment mode it takes the click before the page's
    /// listeners) and `collieComments.mode/show` (+ `positions`, `clickPin` for tests). Pins re-anchor to their selector
    /// on every `show`, resize and load; a selector that no longer matches leaves the pin at the stored fractions.
    static let script = """
        (() => {
          if (window.collieComments) return;
          const post = m => { try { webkit.messageHandlers.collieComments.postMessage(m) } catch (_) {} };
          let on = false, host = null, root = null, list = [], placed = [];
          const unit = v => Math.min(Math.max(v, 0), 1);
          const size = () => [Math.max(document.documentElement.scrollWidth, 1), Math.max(document.documentElement.scrollHeight, 1)];
          const selectorOf = el => {
            const parts = [];
            for (let e = el, i = 0; e && e.nodeType === 1 && i < 12; e = e.parentElement, i++) {
              if (e.id) { parts.unshift('#' + CSS.escape(e.id)); break }
              if (e === document.documentElement) { parts.unshift('html'); break }
              let n = 1;
              for (let s = e.previousElementSibling; s; s = s.previousElementSibling) if (s.localName === e.localName) n++;
              parts.unshift(e.localName + ':nth-of-type(' + n + ')');
            }
            return parts.join(' > ');
          };
          window.addEventListener('click', e => {
            if (!on || !e.isTrusted || e.target === host) return;   // a click the page dispatches never counts
            e.preventDefault(); e.stopImmediatePropagation();
            on = false;
            const el = e.target instanceof Element ? e.target : (e.target && e.target.parentElement);
            const [w, h] = size();
            post({ click: { selector: el ? selectorOf(el) : '', x: unit((e.clientX + scrollX) / w), y: unit((e.clientY + scrollY) / h),
                            text: el ? (el.innerText || el.textContent || '').trim().replace(/\\s+/g, ' ').slice(0, 80) : '' } });
          }, true);
          const draw = () => {
            placed = [];
            // no pins, no host: the page's DOM stays as it was written
            if (!document.documentElement || !list.length) { if (host) host.remove(); return [] }
            if (host) { host.style.setProperty('width', '0', 'important'); host.style.setProperty('height', '0', 'important') }
            const [w, h] = size();   // the page's own size: the host is 0×0 while measured
            if (!host || !host.isConnected) {
              host = document.createElement('collie-pins');
              root = host.attachShadow({ mode: 'closed' });
              for (const [k, v] of [['position', 'absolute'], ['top', '0'], ['left', '0'], ['width', '0'], ['height', '0'],
                                    ['z-index', '2147483647'], ['display', 'block'], ['margin', '0'], ['padding', '0']]) host.style.setProperty(k, v, 'important');
              document.documentElement.appendChild(host);
            }
            // as big as the page and clipping: a pin at the edge never grows the scroll size; clicks go through it
            for (const [k, v] of [['width', w + 'px'], ['height', h + 'px'], ['overflow', 'hidden'], ['pointer-events', 'none']]) host.style.setProperty(k, v, 'important');
            const style = document.createElement('style');
            style.textContent = '.pin{position:absolute;transform:translate(-50%,-50%);min-width:22px;height:22px;border-radius:11px;'
              + 'background:#e8590c;color:#fff;font:600 12px -apple-system,sans-serif;display:flex;align-items:center;justify-content:center;'
              + 'box-shadow:0 1px 4px rgba(0,0,0,.35);cursor:pointer;pointer-events:auto;padding:0 4px;box-sizing:border-box}.pin.done{opacity:.4}';
            root.replaceChildren(style);
            for (const c of list) {
              let el = null;
              try { el = c.selector ? document.querySelector(c.selector) : null } catch (_) {}
              if (el === host) el = null;
              let left = unit(+c.x || 0) * w, top = unit(+c.y || 0) * h;
              if (el) { const r = el.getBoundingClientRect(); left = r.left + scrollX; top = r.top + scrollY }
              const p = document.createElement('div');
              p.className = c.resolved ? 'pin done' : 'pin';
              p.setAttribute('data-collie-pin', String(c.id));
              p.textContent = String(c.n);
              p.style.left = left + 'px'; p.style.top = top + 'px';
              p.addEventListener('click', e => { e.preventDefault(); e.stopPropagation(); post({ open: String(c.id) }) });
              root.appendChild(p);
              placed.push({ id: String(c.id), left, top, approx: !el });
            }
            return placed.filter(p => p.approx).map(p => p.id);
          };
          window.addEventListener('resize', draw);
          window.addEventListener('load', draw);
          window.collieComments = {
            mode: v => { on = !!v },
            show: l => { list = Array.isArray(l) ? l : []; return draw() },
            positions: () => placed,
            clickPin: id => { const p = root && Array.from(root.querySelectorAll('[data-collie-pin]')).find(e => e.getAttribute('data-collie-pin') === id); if (p) p.click() },
          };
        })();
        """
}

/// The drawer at the panel's right edge: filter, **Fixar comentário**, the composer, and the threads.
struct PreviewCommentsDrawer: View {
    @ObservedObject var m: PreviewComments
    @State private var text = ""
    @State private var replies: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Comentários").font(.collieUI(13, .semibold))
                Spacer()
                Button { m.drawer = false; m.setMode(false) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Fechar")
            }
            Picker("Filtro", selection: $m.showAll) { Text("Abertos").tag(false); Text("Todos").tag(true) }
                .pickerStyle(.segmented).labelsHidden()
            Button(m.mode ? "Clique na página… (cancelar)" : "Fixar comentário") { m.setMode(!m.mode) }
                .buttonStyle(CollieButtonStyle(m.mode ? .primary : .secondary))
            if let e = m.error { Text(e).font(.collieUI(12)).foregroundStyle(Color.collieDanger).lineLimit(3) }
            if let d = m.draft {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Novo comentário em \(d.text ?? "um ponto da página")").font(.collieUI(12)).foregroundStyle(Color.collieMuted).lineLimit(2)
                    TextEditor(text: $text).font(.collieUI(12)).frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.collieBorder))
                    HStack {
                        Button("Enviar") { let t = text; Task { await m.send(t); if m.draft == nil { text = "" } } }
                            .disabled(m.busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).buttonStyle(CollieButtonStyle(.primary))
                        Button("Cancelar") { m.draft = nil; text = "" }.buttonStyle(CollieButtonStyle(.secondary))
                    }
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        let shown = m.threads.filter { m.showAll || !$0.resolved }
                        if shown.isEmpty { Text("Nenhum comentário").font(.collieUI(12)).foregroundStyle(Color.collieMuted) }
                        ForEach(shown) { t in thread(t).id(t.id) }
                    }
                }
                .onChange(of: m.selected) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .top) } } }
            }
        }
        .padding(12)
        .frame(width: 300)
        .background(Color.collieSidebar)
    }

    @ViewBuilder private func thread(_ t: PreviewComments.Thread) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(t.n)").font(.collieMono(11, .medium)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.collieAccent.opacity(t.resolved ? 0.3 : 1))).foregroundStyle(.white)
                Text(t.anchorText).font(.collieUI(12, .medium)).lineLimit(1)
                if m.approximate.contains(t.id) {
                    Text("posição aproximada").font(.collieMono(10, .medium)).foregroundStyle(Color.collieAttention)
                }
            }
            if let n = t.notice { Text(n).font(.collieUI(11)).foregroundStyle(Color.collieAttention) }
            ForEach(t.messages) { msg in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(msg.byName).font(.collieUI(11, .semibold))
                        if let at = msg.at { Text(at, style: .time).font(.collieUI(10)).foregroundStyle(Color.collieMuted) }
                    }
                    Text(msg.body).font(.collieUI(12)).textSelection(.enabled)
                }
            }
            HStack {
                TextField("Responder…", text: Binding(get: { replies[t.id] ?? "" }, set: { replies[t.id] = $0 })).textFieldStyle(.roundedBorder)
                Button("Enviar") {
                    let r = replies[t.id] ?? ""
                    Task { if await m.followUp(t.id, r) { replies[t.id] = nil } }
                }.disabled(m.busy).buttonStyle(CollieButtonStyle(.secondary))
            }
            Button(t.resolved ? "Reabrir" : "Resolver") { Task { await m.setResolved(t.id, !t.resolved) } }
                .disabled(m.busy).buttonStyle(CollieButtonStyle(.secondary))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(m.selected == t.id ? Color.collieAccent.opacity(0.12) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.collieBorder))
        .opacity(t.resolved ? 0.6 : 1)
    }
}
