import Foundation
import CollieCore
import CollieProtocol

/// `artifact new`'s starter pages: self-contained HTML/CSS/vanilla JS (no URL but `collie-lib://`), themed by the tokens of
/// the active design system (`[data-theme]` Light/Dark). The kinds' CSS uses only the seed's variable names, so any
/// system with those names themes them. With the offline libraries (`libs`), the page also loads them: Chart.js for the
/// dashboard's chart, React + htm for the prototype's list, Lucide icons on every kind; each library missing at run time
/// leaves the vanilla page plus a muted note "Bibliotecas offline indisponíveis".
enum ArtifactTemplates {
    enum Kind: String, CaseIterable, Sendable {
        case deck, dashboard, doc, prototype
        /// The default title (pt-BR).
        var label: String {
            switch self { case .deck: "Apresentação"; case .dashboard: "Painel"; case .doc: "Documento"; case .prototype: "Protótipo" }
        }
    }

    /// `[a-z0-9-]{1,48}`: lowercased, any other character → `-` (runs collapsed), trimmed of `-`; nil when nothing is left.
    static func slug(_ name: String) -> String? {
        var out = ""
        for c in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(c) || ("0"..."9").contains(c) { out.unicodeScalars.append(c) } else if !out.hasSuffix("-") { out.append("-") }
        }
        let s = String(out.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty ? nil : s
    }

    /// The seed system's tokens (`DesignSystemService.colors/numbers`) in `variable.list`'s shape.
    static let seed: JSONValue = {
        func s(_ x: String) -> JSONValue { .string(x) }
        func rgb(_ hex: String) -> JSONValue {
            let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
            return .object(["r": .number(Double(v >> 16 & 0xFF) / 255), "g": .number(Double(v >> 8 & 0xFF) / 255),
                            "b": .number(Double(v & 0xFF) / 255), "a": .number(1)])
        }
        var vars: [JSONValue] = DesignSystemService.colors.map { n, light, dark in
            .object(["id": s(n), "name": s(n), "collection": s("tokens"), "values": .object([
                "light": .object(["type": s("color"), "value": rgb(light)]), "dark": .object(["type": s("color"), "value": rgb(dark)])])])
        }
        vars += DesignSystemService.numbers.map { n, x in
            .object(["id": s(n), "name": s(n), "collection": s("tokens"), "values": .object([
                "light": .object(["type": s("number"), "value": .number(x)]), "dark": .object(["type": s("number"), "value": .number(x)])])])
        }
        return .object(["collections": .array([.object(["id": s("tokens"), "name": s("Tokens"), "modes": .array([
            .object(["id": s("light"), "name": s("Light")]), .object(["id": s("dark"), "name": s("Dark")])])])]),
                        "variables": .array(vars)])
    }()

    /// `:root { … }` (each variable's first mode: the seed's, then `variables`' overriding and adding), then the
    /// `[data-theme]` rules of `ExportStyles.themes`. Values pass `ExportStyles.safeValue` (no `</style>`, no url).
    static func tokensCSS(variables: JSONValue?) -> String {
        let lists = [seed] + (variables.map { [$0] } ?? [])
        var order: [String] = [], root: [String: String] = [:]
        for case .object(let o) in lists {
            guard case .array(let cs)? = o["collections"], case .array(let vs)? = o["variables"] else { continue }
            var modes: [String: [(id: String, name: String)]] = [:]
            for case .object(let c) in cs {
                guard let id = c["id"]?.str, case .array(let ms)? = c["modes"] else { continue }
                modes[id] = ms.compactMap { m in
                    guard case .object(let m) = m, let i = m["id"]?.str, let n = m["name"]?.str else { return nil }
                    return (i, n)
                }
            }
            var byId: [String: [String: JSONValue]] = [:]
            for case .object(let v) in vs { if let id = v["id"]?.str { byId[id] = v } }
            for case .object(let v) in vs {
                var web: String?
                if case .object(let cs)? = v["codeSyntax"] { web = cs["WEB"]?.str }
                let css = ExportStyles.cssVarName(v["name"]?.str ?? "", web: web)
                guard let first = v["collection"]?.str.flatMap({ modes[$0]?.first }),
                      let value = ExportStyles.resolve(v, mode: first.name, byId: byId, modes: modes, px: true).flatMap(ExportStyles.safeValue) else { continue }
                if root[css] == nil { order.append(css) }
                root[css] = value
            }
        }
        let attrs = order.map { Attr(name: $0, value: root[$0]!) }
        return ":root {\n" + attrs.map { "  \($0.name): \($0.value);\n" }.joined() + "}\n" + ExportStyles.themes(root: attrs, variables: lists)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    /// `libs`: the manifest's entries (`[]`: the library-free page, byte for byte).
    static func render(_ kind: Kind, title: String, tokensCSS: String, libs: [WebLibEntry] = []) -> String {
        let t = escape(title)
        var (css, body, js): (String, String, String) = switch kind {
        case .deck: (deckCSS, deckBody(t), deckJS)
        case .dashboard: (dashboardCSS, dashboardBody(t), dashboardJS)
        case .doc: (docCSS, docBody(t), docJS)
        case .prototype: (prototypeCSS, prototypeBody(t), prototypeJS)
        }
        let srcs = libs.isEmpty ? [] : uses(kind).compactMap { WebLibs.url($0, in: libs) }
        if !srcs.isEmpty {
            css += "\n" + libsCSS
            body += "\n" + srcs.map { "<script src=\"\($0)\"></script>" }.joined(separator: "\n")
            js += "\n" + libsJS(kind)
        }
        return """
            <!doctype html>
            <html lang="pt-BR">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(t)</title>
            <style>
            \(tokensCSS)
            \(baseCSS)
            \(css)
            </style>
            </head>
            <body>
            \(body)
            <script>
            \(js)
            </script>
            </body>
            </html>

            """
    }

    // MARK: libraries

    /// The manifest names each kind loads, in load order.
    static func uses(_ kind: Kind) -> [String] {
        switch kind {
        case .deck, .doc: ["lucide"]
        case .dashboard: ["chart.js", "lucide"]
        case .prototype: ["react", "react-dom", "htm", "lucide"]
        }
    }

    static let libsCSS = """
        .lucide { width: 1.1em; height: 1.1em; vertical-align: -0.15em; }
        .libs-note { margin: var(--space-m); font-size: 12px; }
        """

    /// Runs after the kind's own script (same scope: `data`, `items`, `render`, `list`). Each library guarded; the chart
    /// repaints when `data-theme` changes (the Prévia's Claro/Escuro). No `//` in the page (everyKindIsOffline).
    static func libsJS(_ kind: Kind) -> String {
        let icons = switch kind {
        case .deck: #"[['.slide .accent', 'sparkles']]"#
        case .doc: #"[['.toc strong', 'list']]"#
        case .dashboard: #"[['.kpi .delta', 'trending-up']]"#
        case .prototype: #"[['[aria-label="Menu"]', 'menu', true], ['[aria-label="Buscar"]', 'search', true]]"#
        }
        let common = """
            function libsMissing() {
              if (document.querySelector('.libs-note')) return;
              const p = document.createElement('p'); p.className = 'muted libs-note'; p.textContent = 'Bibliotecas offline indisponíveis';
              document.body.appendChild(p);
            }
            if (window.lucide) {
              for (const [sel, name, swap] of \(icons)) document.querySelectorAll(sel).forEach(el => {
                const i = document.createElement('i'); i.setAttribute('data-lucide', name);
                if (swap) el.replaceChildren(i); else el.prepend(i, ' ');
              });
              lucide.createIcons({ icons: lucide.icons });
            } else libsMissing();
            """
        switch kind {
        case .deck, .doc: return common
        case .dashboard: return common + "\n" + """
            if (window.Chart) {
              const svg = document.getElementById('chart'), canvas = document.createElement('canvas');
              canvas.setAttribute('role', 'img'); canvas.setAttribute('aria-label', svg.getAttribute('aria-label'));
              svg.replaceWith(canvas);
              const token = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
              const chart = new Chart(canvas, {
                data: { labels: data.map(d => d.mes), datasets: [
                  { type: 'bar', label: 'Vendas (R$ mil)', data: data.map(d => d.valor), borderRadius: 6 },
                  { type: 'line', label: 'Tendência', data: data.map(d => d.valor), tension: 0.3 },
                ] },
                options: { responsive: true, animation: false, plugins: { legend: { labels: {} } },
                           scales: { x: { ticks: {}, grid: { display: false } }, y: { ticks: {}, grid: {} } } },
              });
              function paint() {
                const accent = token('--accent'), muted = token('--muted');
                chart.data.datasets[0].backgroundColor = accent;
                chart.data.datasets[1].borderColor = muted; chart.data.datasets[1].backgroundColor = muted;
                const o = chart.options;
                o.plugins.legend.labels.color = o.scales.x.ticks.color = o.scales.y.ticks.color = muted;
                o.scales.y.grid.color = 'color-mix(in srgb, ' + muted + ' 25%, transparent)';
                chart.update();
              }
              paint();
              new MutationObserver(paint).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
            } else libsMissing();
            """
        case .prototype: return common + "\n" + """
            if (window.React && window.ReactDOM && window.htm) {
              const html = htm.bind(React.createElement);
              const Item = ({ it }) => html`<div class="item"><strong>${it.nome}</strong><span>${it.nota}</span></div>`;
              const App = ({ items }) => html`${items.map((it, i) => html`<${Item} key=${i} it=${it}/>`)}`;
              list.replaceChildren();
              const root = ReactDOM.createRoot(list);
              render = () => ReactDOM.flushSync(() => root.render(html`<${App} items=${[...items]}/>`));
              render();
            } else libsMissing();
            """
        }
    }

    // MARK: kinds

    static let baseCSS = """
        *, *::before, *::after { box-sizing: border-box; }
        html, body { margin: 0; }
        body { background: var(--bg); color: var(--text); font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; font-size: var(--type-body); line-height: 1.5; }
        h1 { font-size: var(--type-h1); line-height: 1.1; margin: 0 0 var(--space-m); }
        h2 { font-size: var(--type-h2); line-height: 1.2; margin: 0 0 var(--space-m); }
        h3 { font-size: var(--type-h3); margin: 0 0 var(--space-s); }
        p { margin: 0 0 var(--space-m); }
        .muted { color: var(--muted); }
        .card { background: var(--surface); border-radius: var(--radius-card); padding: var(--space-l); }
        button { font: inherit; color: inherit; cursor: pointer; }
        """

    static let deckCSS = """
        body { overflow: hidden; height: 100vh; }
        .deck { position: fixed; inset: 0; }
        .slide { position: absolute; left: 50%; top: 50%; width: 1280px; height: 720px; padding: var(--space-xl);
          background: var(--surface); border-radius: var(--radius-card); transform-origin: center; display: none;
          flex-direction: column; justify-content: center; gap: var(--space-m); }
        .slide.on { display: flex; }
        .slide h1 { font-size: calc(var(--type-h1) * 1.5); }
        .slide .lead { font-size: var(--type-h3); color: var(--muted); max-width: 40ch; }
        .slide ul, .slide ol { font-size: var(--type-h3); margin: 0; padding-left: var(--space-l); display: grid; gap: var(--space-s); }
        .cols { display: grid; grid-template-columns: repeat(3, 1fr); gap: var(--space-l); }
        .cols .card { background: var(--bg); }
        .accent { color: var(--accent); }
        .counter { position: fixed; right: var(--space-m); bottom: var(--space-m); color: var(--muted); font-variant-numeric: tabular-nums; }
        """
    static func deckBody(_ t: String) -> String {
        """
        <main class="deck">
          <section class="slide on"><p class="accent">Collie · rascunho</p><h1>\(t)</h1><p class="lead">Uma frase que diz por que isto importa para quem está assistindo.</p></section>
          <section class="slide"><h2>O problema</h2><ul><li>O que acontece hoje, em uma linha</li><li>Quem sente e quanto custa</li><li>Por que agora</li></ul></section>
          <section class="slide"><h2>A proposta</h2><div class="cols">
            <div class="card"><h3>Simples</h3><p class="muted">O que muda para o usuário.</p></div>
            <div class="card"><h3>Rápido</h3><p class="muted">Quanto tempo leva.</p></div>
            <div class="card"><h3>Medível</h3><p class="muted">Como saberemos que deu certo.</p></div>
          </div></section>
          <section class="slide"><h2>Próximos passos</h2><ol><li>Validar com três clientes</li><li>Protótipo em duas semanas</li><li>Decidir na próxima reunião</li></ol></section>
        </main>
        <div class="counter" id="counter" aria-live="polite">1 / 4</div>
        """
    }
    static let deckJS = """
        const slides = [...document.querySelectorAll('.slide')], counter = document.getElementById('counter');
        let current = 0;
        function fit() {
          const s = Math.min(innerWidth / 1280, innerHeight / 720) * 0.94;
          slides.forEach(el => { el.style.transform = 'translate(-50%, -50%) scale(' + s + ')'; });
        }
        function show(n) {
          current = Math.max(0, Math.min(slides.length - 1, n));
          slides.forEach((el, i) => el.classList.toggle('on', i === current));
          counter.textContent = (current + 1) + ' / ' + slides.length;
        }
        addEventListener('keydown', e => {
          if (['ArrowRight', 'PageDown', ' '].includes(e.key)) { e.preventDefault(); show(current + 1); }
          if (['ArrowLeft', 'PageUp'].includes(e.key)) { e.preventDefault(); show(current - 1); }
        });
        addEventListener('resize', fit);
        fit(); show(0);
        """

    static let dashboardCSS = """
        .wrap { max-width: 1120px; margin: 0 auto; padding: var(--space-l); display: grid; gap: var(--space-l); }
        .kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: var(--space-m); }
        .kpi { background: var(--surface); border-radius: var(--radius-card); padding: var(--space-m); display: grid; gap: var(--space-s); }
        .kpi strong { font-size: var(--type-h2); font-variant-numeric: tabular-nums; }
        .kpi .delta { color: var(--accent); }
        svg { width: 100%; height: auto; display: block; color: var(--accent); }
        svg text { fill: var(--muted); font-size: 12px; }
        table { width: 100%; border-collapse: collapse; font-variant-numeric: tabular-nums; }
        th, td { text-align: left; padding: var(--space-s); border-bottom: 1px solid color-mix(in srgb, var(--muted) 25%, transparent); }
        th { color: var(--muted); font-weight: 500; }
        td.num, th.num { text-align: right; }
        """
    static func dashboardBody(_ t: String) -> String {
        """
        <main class="wrap">
          <header><h1>\(t)</h1><p class="muted">Dados de exemplo · atualize o array <code>data</code> no fim da página</p></header>
          <section class="kpis">
            <div class="kpi"><span class="muted">Receita</span><strong>R$ 128 mil</strong><span class="delta">+12% no mês</span></div>
            <div class="kpi"><span class="muted">Pedidos</span><strong>1.284</strong><span class="delta">+8% no mês</span></div>
            <div class="kpi"><span class="muted">Ticket médio</span><strong>R$ 99,70</strong><span class="delta">+3% no mês</span></div>
            <div class="kpi"><span class="muted">Clientes novos</span><strong>312</strong><span class="delta">+21% no mês</span></div>
          </section>
          <section class="card"><h2>Vendas por mês</h2><svg id="chart" viewBox="0 0 640 260" role="img" aria-label="Vendas por mês, em milhares de reais"></svg></section>
          <section class="card"><h2>Por mês</h2><table><thead><tr><th>Mês</th><th class="num">Vendas (R$ mil)</th></tr></thead><tbody id="rows"></tbody></table></section>
        </main>
        """
    }
    static let dashboardJS = """
        const data = [
          { mes: 'Jan', valor: 82 }, { mes: 'Fev', valor: 91 }, { mes: 'Mar', valor: 97 },
          { mes: 'Abr', valor: 104 }, { mes: 'Mai', valor: 118 }, { mes: 'Jun', valor: 128 },
        ];
        const W = 640, H = 260, pad = 28, max = Math.max(...data.map(d => d.valor)) || 1;
        const bw = (W - pad * 2) / data.length;
        document.getElementById('chart').innerHTML = data.map((d, i) => {
          const h = (H - pad * 2) * d.valor / max, x = pad + i * bw + bw * 0.15, y = H - pad - h;
          return '<rect x="' + x + '" y="' + y + '" width="' + bw * 0.7 + '" height="' + h + '" rx="6" fill="currentColor"><title>' + d.mes + ': ' + d.valor + '</title></rect>'
            + '<text x="' + (x + bw * 0.35) + '" y="' + (H - 8) + '" text-anchor="middle">' + d.mes + '</text>';
        }).join('');
        const rows = document.getElementById('rows');
        for (const d of data) {
          const tr = document.createElement('tr');
          tr.innerHTML = '<td></td><td class="num"></td>';
          tr.children[0].textContent = d.mes; tr.children[1].textContent = d.valor.toLocaleString('pt-BR');
          rows.appendChild(tr);
        }
        """

    static let docCSS = """
        .hero { max-width: 1040px; margin: 0 auto; padding: var(--space-xl) var(--space-l) var(--space-l); }
        .layout { max-width: 1040px; margin: 0 auto; padding: 0 var(--space-l) var(--space-xl); display: grid; grid-template-columns: 220px 1fr; gap: var(--space-xl); }
        .toc { position: sticky; top: var(--space-l); align-self: start; }
        .toc ol { list-style: none; margin: var(--space-s) 0 0; padding: 0; display: grid; gap: var(--space-s); }
        .toc a { color: var(--muted); text-decoration: none; }
        .toc a:hover { color: var(--accent); }
        article { max-width: 68ch; }
        article h2 { margin-top: var(--space-xl); scroll-margin-top: var(--space-l); }
        blockquote { margin: 0 0 var(--space-m); padding: var(--space-m); border-left: 4px solid var(--accent); background: var(--surface); border-radius: var(--radius-card); }
        @media (max-width: 760px) { .layout { grid-template-columns: 1fr; } .toc { position: static; } }
        """
    static func docBody(_ t: String) -> String {
        """
        <header class="hero"><h1>\(t)</h1><p class="muted">Rascunho · escrito no Collie</p></header>
        <div class="layout">
          <nav class="toc" aria-label="Sumário"><strong>Sumário</strong><ol id="toc"></ol></nav>
          <article id="doc">
            <h2>Contexto</h2><p>Em duas ou três frases: onde estamos e o que motivou este documento.</p>
            <h2>Objetivo</h2><p>O que queremos alcançar e como vamos medir.</p>
            <blockquote>Uma frase que resume a decisão pedida a quem lê.</blockquote>
            <h2>Proposta</h2><p>A solução, do geral ao detalhe.</p><h3>Alternativas</h3><p>O que foi considerado e por que ficou de fora.</p>
            <h2>Riscos</h2><p>O que pode dar errado e o plano para cada caso.</p>
            <h2>Próximos passos</h2><p>Quem faz o quê, e até quando.</p>
          </article>
        </div>
        """
    }
    static let docJS = """
        const toc = document.getElementById('toc');
        document.querySelectorAll('#doc h2').forEach((h, i) => {
          h.id = h.id || 'secao-' + (i + 1);
          const li = document.createElement('li'), a = document.createElement('a');
          a.textContent = h.textContent; a.setAttribute('href', '#' + h.id);
          li.appendChild(a); toc.appendChild(li);
        });
        """

    static let prototypeCSS = """
        body { display: grid; place-items: center; min-height: 100vh; padding: var(--space-m); }
        .phone { position: relative; width: 100%; max-width: 390px; height: min(844px, calc(100vh - 32px)); background: var(--bg);
          border-radius: calc(var(--radius-card) * 3); overflow: hidden; display: flex; flex-direction: column;
          box-shadow: 0 0 0 1px color-mix(in srgb, var(--muted) 30%, transparent), 0 24px 48px color-mix(in srgb, var(--text) 18%, transparent); }
        .bar { display: flex; align-items: center; gap: var(--space-s); padding: var(--space-m); background: var(--surface); }
        .bar h1 { font-size: var(--type-h3); margin: 0; flex: 1; text-align: center; }
        .icon { background: none; border: 0; width: 40px; height: 40px; border-radius: var(--radius-card); font-size: var(--type-h3); }
        .list { flex: 1; overflow: auto; padding: var(--space-m); display: grid; gap: var(--space-s); align-content: start; }
        .item { background: var(--surface); border-radius: var(--radius-card); padding: var(--space-m); display: grid; gap: 2px; }
        .item span { color: var(--muted); }
        .fab { position: absolute; right: var(--space-m); bottom: 88px; background: var(--accent); color: var(--bg); border: 0;
          border-radius: 999px; padding: var(--space-s) var(--space-m); font-weight: 600; }
        .tabs { display: grid; grid-template-columns: repeat(3, 1fr); background: var(--surface); padding: var(--space-s); }
        .tab { background: none; border: 0; padding: var(--space-s); border-radius: var(--radius-card); color: var(--muted); }
        .tab.on { color: var(--accent); font-weight: 600; }
        .scrim { position: absolute; inset: 0; background: color-mix(in srgb, var(--text) 35%, transparent); }
        .sheet { position: absolute; left: 0; right: 0; bottom: 0; background: var(--surface); padding: var(--space-l);
          border-radius: var(--radius-card) var(--radius-card) 0 0; display: grid; gap: var(--space-m); transform: translateY(110%); transition: transform .25s; }
        .sheet.open { transform: none; }
        .sheet input { width: 100%; font: inherit; padding: var(--space-s); margin-top: var(--space-s); border-radius: var(--radius-card);
          border: 1px solid color-mix(in srgb, var(--muted) 40%, transparent); background: var(--bg); color: var(--text); }
        .row { display: flex; gap: var(--space-s); justify-content: flex-end; }
        .primary { background: var(--accent); color: var(--bg); border: 0; border-radius: var(--radius-card); padding: var(--space-s) var(--space-m); }
        .ghost { background: none; border: 0; padding: var(--space-s) var(--space-m); color: var(--muted); }
        """
    static func prototypeBody(_ t: String) -> String {
        """
        <div class="phone">
          <header class="bar"><button class="icon" aria-label="Menu">☰</button><h1>\(t)</h1><button class="icon" aria-label="Buscar">⌕</button></header>
          <main class="list" id="list"></main>
          <button class="fab" id="open">+ Novo</button>
          <nav class="tabs"><button class="tab on">Início</button><button class="tab">Buscar</button><button class="tab">Perfil</button></nav>
          <div class="scrim" id="scrim" hidden></div>
          <section class="sheet" id="sheet" aria-hidden="true" aria-label="Novo item">
            <h2>Novo item</h2>
            <label>Nome<input id="nome" placeholder="Ex.: Comprar café"></label>
            <div class="row"><button class="ghost" id="cancel">Cancelar</button><button class="primary" id="save">Salvar</button></div>
          </section>
        </div>
        """
    }
    static let prototypeJS = """
        const items = [
          { nome: 'Revisar o protótipo', nota: 'Hoje, 14h' }, { nome: 'Enviar para o time', nota: 'Amanhã' },
          { nome: 'Coletar feedback', nota: 'Sexta' },
        ];
        const list = document.getElementById('list'), sheet = document.getElementById('sheet'), scrim = document.getElementById('scrim');
        function render() {
          list.replaceChildren(...items.map(it => {
            const el = document.createElement('div'), b = document.createElement('strong'), s = document.createElement('span');
            el.className = 'item'; b.textContent = it.nome; s.textContent = it.nota; el.append(b, s); return el;
          }));
        }
        function sheetOpen(on) {
          sheet.classList.toggle('open', on); sheet.setAttribute('aria-hidden', String(!on)); scrim.hidden = !on;
          if (on) document.getElementById('nome').focus();
        }
        document.getElementById('open').onclick = () => sheetOpen(true);
        document.getElementById('cancel').onclick = scrim.onclick = () => sheetOpen(false);
        document.getElementById('save').onclick = () => {
          const n = document.getElementById('nome');
          if (n.value.trim()) { items.unshift({ nome: n.value.trim(), nota: 'Agora' }); n.value = ''; render(); }
          sheetOpen(false);
        };
        document.querySelectorAll('.tab').forEach(t => t.onclick = () => {
          document.querySelectorAll('.tab').forEach(x => x.classList.toggle('on', x === t));
        });
        render();
        """
}
